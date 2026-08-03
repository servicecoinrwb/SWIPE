// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";

/**
 * Interchange — a processor's fee book, shared out
 *
 * A card processor's business is simple: money moves through it, a slice
 * stays behind, and whoever owns the processor takes that slice. This is
 * that, with the ownership made liquid and the slice paid in the same
 * stablecoin the fees arrived in.
 *
 * Stake SWIPE and you receive a pro-rata share of every fee deposited
 * after you staked. Nothing is minted to pay you — the yield is USDC that
 * genuinely came in, or it is nothing at all. A staking contract that mints
 * its own rewards is paying you with your own dilution, and calling that
 * revenue is the oldest trick in the business.
 *
 * ─────────────────────────────────────────────────────────────────────
 * THE ESCROW, WHICH IS THE INTERESTING PART
 *
 * Most of what GMX got right is in a mechanic nobody copies properly.
 * Rewards can be paid in ESCROWED tokens — esSWIPE here — which cannot be
 * sold, sent, or traded. They convert to real SWIPE only by vesting,
 * linearly over a year.
 *
 * And to vest, you must RESERVE an equal amount of staked SWIPE. Reserved
 * stake cannot be withdrawn until the vesting it backs has finished.
 *
 * That's the whole loyalty mechanism, and it works because it isn't a
 * penalty. Nobody is slashed for leaving; leaving is simply not available
 * while you are mid-vest. A lock is easier to defend and harder to
 * complain about than a forfeiture, and it produces the same behaviour.
 * ─────────────────────────────────────────────────────────────────────
 *
 * WHAT THIS DOES NOT DO
 *
 * It does not process anything. It has no idea whether a payment happened;
 * it only knows that somebody deposited USDC and called it fees. Whether
 * those fees are real is a question about the depositor, not about this
 * contract, and no amount of Solidity can answer it.
 */
contract Interchange {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error NotIssuer();
    error IssuanceClosed();
    error AboveCap(uint256 attempted, uint256 cap);
    error InsufficientBalance(uint256 have, uint256 want);
    error InsufficientAllowance(uint256 have, uint256 want);
    error InsufficientStake(uint256 have, uint256 want);
    error StakeReserved(uint256 free, uint256 want);
    error InsufficientEscrow(uint256 have, uint256 want);
    error NothingToClaim();
    error NothingStaked();
    error EscrowNotTransferable();

    // -------------------------------------------------------------- metadata

    string public constant name = "Interchange";
    string public constant symbol = "SWIPE";
    uint8  public constant decimals = 18;

    // -------------------------------------------------------------- constants

    /// @dev Escrowed rewards take a year to become real, exactly as GMX does.
    uint64 public constant VEST_PERIOD = 365 days;

    uint256 private constant PRECISION = 1e18;

    // ----------------------------------------------------------------- state

    IERC20  public immutable feeToken;      // USDC
    address public immutable issuer;
    uint256 public immutable supplyCap;

    // --- ERC-20 ---
    mapping(address => uint256) private _bal;
    mapping(address => mapping(address => uint256)) private _allow;
    uint256 private _supply;
    bool public issuanceClosed;

    // --- staking ---
    mapping(address => uint256) public stakedOf;
    uint256 public totalStaked;

    /// @dev Fees per staked token, scaled. The whole distribution rests on
    ///      this one number: it only ever increases, and each staker's claim
    ///      is the difference between it now and when they last touched.
    uint256 public accFeePerShare;
    mapping(address => uint256) private _feeDebt;
    mapping(address => uint256) public claimable;

    /// @dev Fees that arrived while nothing was staked. They would otherwise
    ///      be stranded — no denominator to divide by — so they wait here
    ///      and join the next distribution.
    uint256 public banked;
    uint256 public feesReceived;
    uint256 public feesPaid;

    // --- escrow and vesting ---
    mapping(address => uint256) public escrowOf;     // esSWIPE, untradeable
    uint256 public escrowSupply;

    struct Vest {
        uint256 amount;     // esSWIPE still vesting
        uint256 rate;       // per second, scaled by PRECISION
        uint64  updatedAt;
    }
    mapping(address => Vest) private _vest;
    uint256 public totalVesting;

    // ---------------------------------------------------------------- events

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Issued(address indexed to, uint256 amount, bool escrowed);
    event IssuanceEnded(uint256 supply);
    event Staked(address indexed who, uint256 amount, uint256 total);
    event Unstaked(address indexed who, uint256 amount, uint256 total);
    event FeesDeposited(address indexed from, uint256 amount, uint256 perShare, bool banked);
    event FeesClaimed(address indexed who, uint256 amount);
    event VestStarted(address indexed who, uint256 amount, uint256 reserved);
    event Vested(address indexed who, uint256 amount, uint256 remaining);
    event VestCancelled(address indexed who, uint256 returned);

    constructor(IERC20 feeToken_, uint256 supplyCap_) {
        if (address(feeToken_) == address(0)) revert ZeroAddress();
        feeToken = feeToken_;
        issuer = msg.sender;
        supplyCap = supplyCap_;
    }

    // -------------------------------------------------------------- issuance

    /**
     * @notice Put SWIPE or esSWIPE into existence.
     * @param escrowed If true the recipient gets escrowed units, which can
     *        only become real by vesting.
     */
    function issue(address to, uint256 amount, bool escrowed) external {
        if (msg.sender != issuer) revert NotIssuer();
        if (issuanceClosed) revert IssuanceClosed();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // Escrowed units count against the cap too — they are claims on real
        // supply, and pretending otherwise is how caps get quietly broken.
        uint256 after_ = _supply + escrowSupply + amount;
        if (supplyCap != 0 && after_ > supplyCap) revert AboveCap(after_, supplyCap);

        if (escrowed) {
            escrowOf[to] += amount;
            escrowSupply += amount;
        } else {
            _bal[to] += amount;
            _supply += amount;
            emit Transfer(address(0), to, amount);
        }
        emit Issued(to, amount, escrowed);
    }

    function closeIssuance() external {
        if (msg.sender != issuer) revert NotIssuer();
        issuanceClosed = true;
        emit IssuanceEnded(_supply + escrowSupply);
    }

    // --------------------------------------------------------------- staking

    /// @dev Settle a staker's accrued fees before their stake changes, or
    ///      the accumulator would credit their new balance for old fees.
    function _harvestFees(address who) internal {
        uint256 s = stakedOf[who];
        if (s > 0) {
            uint256 acc = (s * accFeePerShare) / PRECISION;
            uint256 debt = _feeDebt[who];
            if (acc > debt) claimable[who] += acc - debt;
        }
        _feeDebt[who] = (stakedOf[who] * accFeePerShare) / PRECISION;
    }

    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 b = _bal[msg.sender];
        if (b < amount) revert InsufficientBalance(b, amount);

        _harvestFees(msg.sender);

        unchecked { _bal[msg.sender] = b - amount; }
        stakedOf[msg.sender] += amount;
        totalStaked += amount;
        _feeDebt[msg.sender] = (stakedOf[msg.sender] * accFeePerShare) / PRECISION;

        // Fees that arrived with nothing staked now have a denominator.
        _releaseBanked();

        emit Staked(msg.sender, amount, stakedOf[msg.sender]);
    }

    /**
     * @notice Withdraw stake back to a spendable balance.
     * @dev Stake reserved against a live vesting position cannot leave. That
     *      is the whole lock — no slashing, no forfeit, just unavailability
     *      until the vesting it backs has run.
     */
    function unstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _settleVest(msg.sender);

        uint256 s = stakedOf[msg.sender];
        if (s < amount) revert InsufficientStake(s, amount);

        uint256 reserved = _vest[msg.sender].amount;
        uint256 free = s - reserved;
        if (amount > free) revert StakeReserved(free, amount);

        _harvestFees(msg.sender);

        unchecked { stakedOf[msg.sender] = s - amount; }
        totalStaked -= amount;
        _bal[msg.sender] += amount;
        _feeDebt[msg.sender] = (stakedOf[msg.sender] * accFeePerShare) / PRECISION;

        emit Unstaked(msg.sender, amount, stakedOf[msg.sender]);
    }

    // ------------------------------------------------------------------ fees

    /**
     * @notice Pay fees in for the stakers to share.
     * @dev Anyone may call this. There is no privileged depositor, because
     *      the contract cannot tell an honest fee from a donation anyway and
     *      pretending to check would be theatre.
     */
    function depositFees(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        feesReceived += amount;

        if (totalStaked == 0) {
            banked += amount;
            emit FeesDeposited(msg.sender, amount, 0, true);
        } else {
            uint256 perShare = (amount * PRECISION) / totalStaked;
            accFeePerShare += perShare;
            emit FeesDeposited(msg.sender, amount, perShare, false);
        }
        feeToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function _releaseBanked() internal {
        if (banked > 0 && totalStaked > 0) {
            uint256 b = banked;
            banked = 0;
            accFeePerShare += (b * PRECISION) / totalStaked;
            emit FeesDeposited(address(this), b, (b * PRECISION) / totalStaked, false);
        }
    }

    /**
     * @notice Take your share of the fees, in USDC.
     * @dev Capped at what this contract actually holds. Per-share
     *      accounting floors on deposit but each staker's own multiplication
     *      can round the other way, so the final claimant of a pool can be
     *      owed a unit or two more than exists. Without this cap their
     *      transaction would simply revert and the last person out could
     *      never claim — a one-wei rounding artefact turning into a
     *      permanently stuck balance. The shortfall is at most a few units
     *      of 1e-6 and is dropped rather than carried.
     */
    function claimFees() external returns (uint256 paid) {
        _harvestFees(msg.sender);
        uint256 owed = claimable[msg.sender];
        if (owed == 0) revert NothingToClaim();

        uint256 held = feeToken.balanceOf(address(this));
        paid = owed > held ? held : owed;
        if (paid == 0) revert NothingToClaim();

        claimable[msg.sender] = owed - paid;   // keeps any unpaid remainder
        feesPaid += paid;
        emit FeesClaimed(msg.sender, paid);
        feeToken.safeTransfer(msg.sender, paid);
    }

    function pendingFees(address who) public view returns (uint256) {
        uint256 s = stakedOf[who];
        uint256 acc = accFeePerShare;
        // Reflect banked fees that a stake would immediately release.
        if (banked > 0 && totalStaked > 0) acc += (banked * PRECISION) / totalStaked;
        uint256 earned = (s * acc) / PRECISION;
        uint256 debt = _feeDebt[who];
        return claimable[who] + (earned > debt ? earned - debt : 0);
    }

    // --------------------------------------------------------------- vesting

    /// @dev Move time forward on a vesting position before it changes.
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

        // The escrowed unit becomes a real one.
        _bal[who] += due;
        _supply += due;
        emit Transfer(address(0), who, due);
        emit Vested(who, due, v.amount);

        if (v.amount == 0) v.rate = 0;
        v.updatedAt = uint64(block.timestamp);
    }

    /**
     * @notice Begin converting escrowed units into real ones.
     * @dev Requires an equal amount of staked SWIPE, which becomes reserved
     *      and cannot be unstaked until this vesting finishes. Each deposit
     *      vests over its own year — the rates simply add, so topping up
     *      never delays what you were already vesting.
     */
    function vest(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 e = escrowOf[msg.sender];
        if (e < amount) revert InsufficientEscrow(e, amount);

        _settleVest(msg.sender);

        Vest storage v = _vest[msg.sender];
        uint256 needed = v.amount + amount;
        uint256 s = stakedOf[msg.sender];
        if (s < needed) revert InsufficientStake(s, needed);

        unchecked { escrowOf[msg.sender] = e - amount; }
        v.amount += amount;
        v.rate += (amount * PRECISION) / VEST_PERIOD;
        v.updatedAt = uint64(block.timestamp);
        totalVesting += amount;

        emit VestStarted(msg.sender, amount, v.amount);
    }

    /// @notice Push a vesting position forward without changing it. Anyone
    ///         may call it for anyone — it only ever moves value toward the
    ///         holder, so there is nothing to abuse.
    function settleVesting(address who) external {
        _settleVest(who);
    }

    /**
     * @notice Stop vesting and take the remainder back as escrow.
     * @dev What has already vested stays vested. Nothing is destroyed —
     *      cancelling returns the unvested portion to escrow and frees the
     *      reserved stake, which is why this is a lock rather than a trap.
     */
    function cancelVest() external returns (uint256 returned) {
        _settleVest(msg.sender);
        Vest storage v = _vest[msg.sender];
        returned = v.amount;
        if (returned == 0) revert NothingToClaim();

        v.amount = 0;
        v.rate = 0;
        v.updatedAt = uint64(block.timestamp);
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

    /// @dev Escrowed units have no transfer path at all — not a modifier
    ///      that could be bypassed, simply no function that moves them.
    ///      The only exit from escrow is vesting.

    // ----------------------------------------------------------------- views

    struct Position {
        uint256 balance;        // spendable SWIPE
        uint256 staked;
        uint256 reserved;       // staked but locked behind vesting
        uint256 freeToUnstake;
        uint256 escrow;         // esSWIPE held, not yet vesting
        uint256 vesting;        // esSWIPE mid-conversion
        uint256 vestPerDay;     // real SWIPE arriving daily
        uint256 pendingFees;    // USDC claimable
        uint256 shareOfPoolPpm;
    }

    function positionOf(address who) external view returns (Position memory p) {
        Vest storage v = _vest[who];
        // Report what a settle would produce, so the page never shows a
        // holder less than they actually have.
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
        p.shareOfPoolPpm = totalStaked == 0 ? 0 : (stakedOf[who] * 1_000_000) / totalStaked;
    }

    struct Book {
        uint256 supply;
        uint256 escrowSupply;
        uint256 totalStaked;
        uint256 totalVesting;
        uint256 feesReceived;
        uint256 feesPaid;
        uint256 banked;
        uint256 stakedPct;      // basis points of supply staked
        bool    closed;
    }

    function book() external view returns (Book memory b) {
        b.supply = _supply;
        b.escrowSupply = escrowSupply;
        b.totalStaked = totalStaked;
        b.totalVesting = totalVesting;
        b.feesReceived = feesReceived;
        b.feesPaid = feesPaid;
        b.banked = banked;
        b.stakedPct = _supply == 0 ? 0 : (totalStaked * 10_000) / _supply;
        b.closed = issuanceClosed;
    }

    /// @dev No owner beyond issuance. Nobody can seize a stake, cancel
    ///      someone's vesting, change the vest period, or withdraw the fee
    ///      pool. The issuer's only power is to create units, and that ends
    ///      permanently the moment they close it.
}
