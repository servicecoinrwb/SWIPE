// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";

/**
 * Interchange — a processor's fee book, owned by the people who filled it
 *
 * Supply starts at zero. Not a small premine, not a treasury allocation,
 * not a founder tranche that unlocks in eighteen months. Zero. Every unit
 * of SWIPE that will ever exist is minted by a payment actually being
 * processed, and there is no function in this contract that lets anyone
 * mint one any other way.
 *
 * ─────────────────────────────────────────────────────────────────────
 * THE LOOP
 *
 *   A merchant processes 100 USDC
 *     → they receive 97.50 immediately
 *     → they are minted 100 SWIPE for the volume they brought
 *     → 2.50 goes to the staking pool
 *
 *   Stakers of SWIPE earn two things from that 2.50
 *     → the USDC itself, pro-rata
 *     → esSWIPE emissions, pro-rata, at a fixed ratio to the fee
 *
 *   esSWIPE cannot be sold or sent. It becomes SWIPE only by vesting over
 *   a year, and only while an equal amount of stake stays locked behind it.
 *
 * So the token is bootstrapped entirely by usage, and the only way to
 * accumulate it is to either bring volume or hold what you earned. Nobody
 * can buy their way to the front of that, because there is no front and
 * nothing to buy at genesis.
 * ─────────────────────────────────────────────────────────────────────
 *
 * WHY EMISSIONS TRACK FEES RATHER THAN TIME
 *
 * Most staking tokens emit on a clock — so much per block, forever,
 * whether or not the thing is being used. That pays people to hold during
 * silence, and the supply grows fastest exactly when it is least deserved.
 *
 * Here emissions are a multiple of fees collected. A month with no
 * payments emits nothing. There is no schedule to front-run, no cliff, and
 * no way for supply to grow without someone having actually paid for
 * something.
 *
 * THE ONE PRIVILEGED ACTION
 *
 * Whoever deploys this must name the payment rail allowed to mint, once,
 * and can then never change it. That is the entire extent of anyone's
 * authority over this contract. There is no owner afterwards, no pause, no
 * upgrade, no treasury, and no way to alter the rates.
 */
contract InterchangeV3 {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error NotDeployer();
    error TerminalAlreadySet();
    error NotTerminal();
    error InsufficientBalance(uint256 have, uint256 want);
    error InsufficientAllowance(uint256 have, uint256 want);
    error InsufficientStake(uint256 have, uint256 want);
    error StakeReserved(uint256 free, uint256 want);
    error InsufficientEscrow(uint256 have, uint256 want);
    error NothingToClaim();

    // -------------------------------------------------------------- metadata

    string public constant name = "Interchange";
    string public constant symbol = "SWIPE";
    uint8  public constant decimals = 18;

    // -------------------------------------------------------------- constants

    uint64 public constant VEST_PERIOD = 365 days;
    uint256 private constant PRECISION = 1e18;

    /// @dev One SWIPE per unit of volume. USDC has six decimals and this
    ///      has eighteen, so the factor bridges them: process a hundred
    ///      dollars, mint a hundred SWIPE.
    uint256 public constant MINT_PER_VOLUME = 1e12;

    /// @dev esSWIPE emitted to stakers per unit of fee. Same bridge, so a
    ///      2.50 USDC fee emits 2.50 esSWIPE across everyone staked.
    uint256 public constant EMIT_PER_FEE = 1e12;

    // ----------------------------------------------------------------- state

    IERC20  public immutable feeToken;
    address public immutable deployer;
    address public terminal;

    // --- ERC-20 ---
    mapping(address => uint256) private _bal;
    mapping(address => mapping(address => uint256)) private _allow;
    uint256 private _supply;

    // --- staking ---
    mapping(address => uint256) public stakedOf;
    uint256 public totalStaked;

    /// @dev Two accumulators, same shape. Each only ever increases, and a
    ///      staker's claim is the gap between it now and when they last
    ///      touched their stake — which is why staking after a fee arrives
    ///      earns nothing from it.
    uint256 public accFeePerShare;
    uint256 public accEscPerShare;
    mapping(address => uint256) private _feeDebt;
    mapping(address => uint256) private _escDebt;
    mapping(address => uint256) public claimableFees;
    mapping(address => uint256) public claimableEsc;

    /// @dev Fees and emissions that arrived with nothing staked. No
    ///      denominator to divide by, so they wait rather than vanish.
    uint256 public bankedFees;
    uint256 public bankedEsc;

    uint256 public feesReceived;
    uint256 public feesPaid;
    uint256 public volumeProcessed;
    uint256 public mintedToMerchants;
    uint256 public emittedToStakers;

    // --- escrow ---
    mapping(address => uint256) public escrowOf;
    uint256 public escrowSupply;

    struct Vest { uint256 amount; uint256 rate; uint64 updatedAt; }
    mapping(address => Vest) private _vest;
    uint256 public totalVesting;

    // ---------------------------------------------------------------- events

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TerminalSet(address indexed terminal);
    event PaymentRecorded(address indexed merchant, uint256 volume, uint256 minted, uint256 fee, uint256 emitted);
    event Staked(address indexed who, uint256 amount, uint256 total);
    event Unstaked(address indexed who, uint256 amount, uint256 total);
    event FeesClaimed(address indexed who, uint256 amount);
    event EscrowClaimed(address indexed who, uint256 amount);
    event VestStarted(address indexed who, uint256 amount, uint256 reserved);
    event Vested(address indexed who, uint256 amount, uint256 remaining);
    event VestCancelled(address indexed who, uint256 returned);

    constructor(IERC20 feeToken_) {
        if (address(feeToken_) == address(0)) revert ZeroAddress();
        feeToken = feeToken_;
        deployer = msg.sender;
    }

    /// @notice Name the rail. Once, and then never again by anyone.
    function setTerminal(address terminal_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (terminal != address(0)) revert TerminalAlreadySet();
        if (terminal_ == address(0)) revert ZeroAddress();
        terminal = terminal_;
        emit TerminalSet(terminal_);
    }

    // ------------------------------------------------------------- the mint

    /**
     * @notice The only way supply is ever created.
     * @dev Called by the rail once per payment, with the fee already
     *      transferred in. Mints SWIPE to the merchant for their volume and
     *      emits esSWIPE to stakers alongside the USDC fee.
     *
     *      Deliberately tolerant: a zero volume or a zero fee is skipped
     *      rather than reverted, because this sits inside a payment and a
     *      reward mechanism must never be able to cost someone a sale.
     */
    function recordPayment(address merchant, uint256 volume, uint256 fee) external {
        if (msg.sender != terminal) revert NotTerminal();

        // 1. the merchant is minted SWIPE for what they brought
        if (merchant != address(0) && volume > 0) {
            uint256 mint = volume * MINT_PER_VOLUME;
            _bal[merchant] += mint;
            _supply += mint;
            volumeProcessed += volume;
            mintedToMerchants += mint;
            emit Transfer(address(0), merchant, mint);

            // 2. the fee is shared, and emissions ride along with it
            uint256 emitAmt = fee * EMIT_PER_FEE;
            if (fee > 0) {
                feesReceived += fee;
                if (totalStaked == 0) {
                    bankedFees += fee;
                    bankedEsc += emitAmt;
                } else {
                    accFeePerShare += (fee * PRECISION) / totalStaked;
                    accEscPerShare += (emitAmt * PRECISION) / totalStaked;
                }
                escrowSupply += emitAmt;
                emittedToStakers += emitAmt;
            }
            emit PaymentRecorded(merchant, volume, mint, fee, emitAmt);
        }
    }

    // --------------------------------------------------------------- staking

    function _harvest(address who) internal {
        uint256 s = stakedOf[who];
        if (s > 0) {
            uint256 f = (s * accFeePerShare) / PRECISION;
            uint256 e = (s * accEscPerShare) / PRECISION;
            if (f > _feeDebt[who]) claimableFees[who] += f - _feeDebt[who];
            if (e > _escDebt[who]) claimableEsc[who] += e - _escDebt[who];
        }
        _feeDebt[who] = (stakedOf[who] * accFeePerShare) / PRECISION;
        _escDebt[who] = (stakedOf[who] * accEscPerShare) / PRECISION;
    }

    function _releaseBanked() internal {
        if (totalStaked == 0) return;
        if (bankedFees > 0) { uint256 b = bankedFees; bankedFees = 0;
            accFeePerShare += (b * PRECISION) / totalStaked; }
        if (bankedEsc > 0) { uint256 b = bankedEsc; bankedEsc = 0;
            accEscPerShare += (b * PRECISION) / totalStaked; }
    }

    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 b = _bal[msg.sender];
        if (b < amount) revert InsufficientBalance(b, amount);

        _harvest(msg.sender);
        unchecked { _bal[msg.sender] = b - amount; }
        stakedOf[msg.sender] += amount;
        totalStaked += amount;
        _feeDebt[msg.sender] = (stakedOf[msg.sender] * accFeePerShare) / PRECISION;
        _escDebt[msg.sender] = (stakedOf[msg.sender] * accEscPerShare) / PRECISION;
        _releaseBanked();

        emit Staked(msg.sender, amount, stakedOf[msg.sender]);
    }

    function unstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _settleVest(msg.sender);

        uint256 s = stakedOf[msg.sender];
        if (s < amount) revert InsufficientStake(s, amount);
        uint256 reserved = _vest[msg.sender].amount;
        uint256 free = s - reserved;
        if (amount > free) revert StakeReserved(free, amount);

        _harvest(msg.sender);
        unchecked { stakedOf[msg.sender] = s - amount; }
        totalStaked -= amount;
        _bal[msg.sender] += amount;
        _feeDebt[msg.sender] = (stakedOf[msg.sender] * accFeePerShare) / PRECISION;
        _escDebt[msg.sender] = (stakedOf[msg.sender] * accEscPerShare) / PRECISION;

        emit Unstaked(msg.sender, amount, stakedOf[msg.sender]);
    }

    // ------------------------------------------------------------------ claim

    /**
     * @notice Take the USDC share of fees you've accrued.
     * @dev Capped at what this contract holds. Per-share accounting floors
     *      on deposit but each staker's multiplication can round the other
     *      way, so the last claimant of a pool can be owed a unit or two
     *      more than exists. Without this cap their transaction reverts and
     *      a rounding artefact becomes a permanently stuck balance.
     */
    function claimFees() external returns (uint256 paid) {
        _harvest(msg.sender);
        uint256 owed = claimableFees[msg.sender];
        if (owed == 0) revert NothingToClaim();
        uint256 held = feeToken.balanceOf(address(this));
        paid = owed > held ? held : owed;
        if (paid == 0) revert NothingToClaim();
        claimableFees[msg.sender] = owed - paid;
        feesPaid += paid;
        emit FeesClaimed(msg.sender, paid);
        feeToken.safeTransfer(msg.sender, paid);
    }

    /// @notice Take the esSWIPE you've earned by staking.
    function claimEscrow() external returns (uint256 got) {
        _harvest(msg.sender);
        got = claimableEsc[msg.sender];
        if (got == 0) revert NothingToClaim();
        claimableEsc[msg.sender] = 0;
        escrowOf[msg.sender] += got;
        emit EscrowClaimed(msg.sender, got);
    }

    function pendingFees(address who) public view returns (uint256) {
        uint256 acc = accFeePerShare;
        if (bankedFees > 0 && totalStaked > 0) acc += (bankedFees * PRECISION) / totalStaked;
        uint256 earned = (stakedOf[who] * acc) / PRECISION;
        return claimableFees[who] + (earned > _feeDebt[who] ? earned - _feeDebt[who] : 0);
    }

    function pendingEscrow(address who) public view returns (uint256) {
        uint256 acc = accEscPerShare;
        if (bankedEsc > 0 && totalStaked > 0) acc += (bankedEsc * PRECISION) / totalStaked;
        uint256 earned = (stakedOf[who] * acc) / PRECISION;
        return claimableEsc[who] + (earned > _escDebt[who] ? earned - _escDebt[who] : 0);
    }

    // --------------------------------------------------------------- vesting

    function _settleVest(address who) internal {
        Vest storage v = _vest[who];
        if (v.amount == 0) { v.updatedAt = uint64(block.timestamp); return; }
        uint256 elapsed = block.timestamp - v.updatedAt;
        if (elapsed == 0) return;

        uint256 due = (v.rate * elapsed) / PRECISION;
        if (due > v.amount) due = v.amount;
        if (due == 0) { v.updatedAt = uint64(block.timestamp); return; }

        v.amount -= due;
        totalVesting -= due;
        escrowSupply -= due;
        _bal[who] += due;
        _supply += due;

        emit Transfer(address(0), who, due);
        emit Vested(who, due, v.amount);
        if (v.amount == 0) v.rate = 0;
        v.updatedAt = uint64(block.timestamp);
    }

    /**
     * @notice Begin converting escrow into real SWIPE.
     * @dev Requires an equal amount of staked SWIPE, which is reserved and
     *      cannot be unstaked until this finishes. A lock, not a penalty —
     *      cancel any time and the unvested part goes back to escrow with
     *      the stake freed. Each deposit vests over its own year, so
     *      topping up never delays what was already converting.
     */
    function vest(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 e = escrowOf[msg.sender];
        if (e < amount) revert InsufficientEscrow(e, amount);

        _settleVest(msg.sender);
        Vest storage v = _vest[msg.sender];
        uint256 needed = v.amount + amount;
        if (stakedOf[msg.sender] < needed) revert InsufficientStake(stakedOf[msg.sender], needed);

        unchecked { escrowOf[msg.sender] = e - amount; }
        v.amount += amount;
        v.rate += (amount * PRECISION) / VEST_PERIOD;
        v.updatedAt = uint64(block.timestamp);
        totalVesting += amount;

        emit VestStarted(msg.sender, amount, v.amount);
    }

    function settleVesting(address who) external { _settleVest(who); }

    function cancelVest() external returns (uint256 returned) {
        _settleVest(msg.sender);
        Vest storage v = _vest[msg.sender];
        returned = v.amount;
        if (returned == 0) revert NothingToClaim();
        v.amount = 0; v.rate = 0; v.updatedAt = uint64(block.timestamp);
        totalVesting -= returned;
        escrowOf[msg.sender] += returned;
        emit VestCancelled(msg.sender, returned);
    }

    // ---------------------------------------------------------------- ERC-20

    function totalSupply() external view returns (uint256) { return _supply; }
    function balanceOf(address who) external view returns (uint256) { return _bal[who]; }
    function allowance(address o, address s) external view returns (uint256) { return _allow[o][s]; }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = _allow[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < amount) revert InsufficientAllowance(a, amount);
            _allow[from][msg.sender] = a - amount;
        }
        _move(from, to, amount); return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        _allow[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    function _move(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 b = _bal[from];
        if (b < amount) revert InsufficientBalance(b, amount);
        unchecked { _bal[from] = b - amount; }
        _bal[to] += amount;
        emit Transfer(from, to, amount);
    }

    /// @dev esSWIPE has no transfer path. Not a modifier that could be
    ///      bypassed — simply no function that moves it. Vesting is the
    ///      only exit.

    // ----------------------------------------------------------------- views

    struct Position {
        uint256 balance; uint256 staked; uint256 reserved; uint256 freeToUnstake;
        uint256 escrow; uint256 vesting; uint256 vestPerDay;
        uint256 pendingFees; uint256 pendingEscrow; uint256 shareOfPoolPpm;
    }

    function positionOf(address who) external view returns (Position memory p) {
        Vest storage v = _vest[who];
        uint256 elapsed = v.updatedAt == 0 ? 0 : block.timestamp - v.updatedAt;
        uint256 due = (v.rate * elapsed) / PRECISION;
        if (due > v.amount) due = v.amount;

        p.balance = _bal[who] + due;
        p.staked = stakedOf[who];
        p.reserved = v.amount - due;
        p.freeToUnstake = p.staked > p.reserved ? p.staked - p.reserved : 0;
        p.escrow = escrowOf[who];
        p.vesting = v.amount - due;
        p.vestPerDay = (v.rate * 86_400) / PRECISION;
        p.pendingFees = pendingFees(who);
        p.pendingEscrow = pendingEscrow(who);
        p.shareOfPoolPpm = totalStaked == 0 ? 0 : (stakedOf[who] * 1_000_000) / totalStaked;
    }

    struct Book {
        uint256 supply; uint256 escrowSupply; uint256 totalStaked; uint256 totalVesting;
        uint256 feesReceived; uint256 feesPaid; uint256 volumeProcessed;
        uint256 mintedToMerchants; uint256 emittedToStakers;
        uint256 stakedPct; address terminal;
    }

    function book() external view returns (Book memory b) {
        b.supply = _supply;
        b.escrowSupply = escrowSupply;
        b.totalStaked = totalStaked;
        b.totalVesting = totalVesting;
        b.feesReceived = feesReceived;
        b.feesPaid = feesPaid;
        b.volumeProcessed = volumeProcessed;
        b.mintedToMerchants = mintedToMerchants;
        b.emittedToStakers = emittedToStakers;
        b.stakedPct = _supply == 0 ? 0 : (totalStaked * 10_000) / _supply;
        b.terminal = terminal;
    }

    /// @dev After setTerminal there is no owner, no admin, no pause, no
    ///      upgrade, no treasury, and no way to mint outside a payment.
    ///      Every SWIPE in existence was created by somebody paying for
    ///      something.
}
