// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";

/**
 * Counterweight — a constant-product pair, and nothing else
 *
 * Two tokens in a box. Their product stays constant across every trade, so
 * the price is whatever the ratio of the balances says it is. That single
 * rule is the entire pricing engine, and it has been the entire pricing
 * engine for most of onchain trading since 2018.
 *
 * ─────────────────────────────────────────────────────────────────────
 * THE BUG THIS SHIPS PROTECTED AGAINST
 *
 * The first person to add liquidity to a naive pair can destroy it. They
 * deposit one unit, receive one LP share, then send a large amount of the
 * token straight to the pair address. Now one share is worth thousands.
 * The next depositor's share is computed by division, rounds to zero, and
 * their deposit is simply absorbed by the attacker.
 *
 * It is the same failure as a vault whose share price runs away when
 * supply approaches zero while assets remain — division by something that
 * should never have been allowed to get that small.
 *
 * The fix, unchanged from Uniswap V2: burn a minimum quantity of LP shares
 * at genesis, to an address nobody controls. Total supply can never return
 * to zero while the pair holds anything, so the divisor has a permanent
 * floor and the attack has nothing to work with.
 * ─────────────────────────────────────────────────────────────────────
 *
 * WHAT THIS DOES NOT HAVE
 *
 * No router, no multi-hop, no price oracle, no flash swaps, no protocol
 * fee, and no owner. It prices one pair and holds its own liquidity. If
 * you want to route through two pools you call two pools.
 *
 * DECIMALS DO NOT MATTER TO IT, BUT THEY WILL MATTER TO YOU
 *
 * The maths is done in raw units, so a pair of an 18-decimal token against
 * a 6-decimal one works perfectly and reports a price that looks absurd.
 * A UI has to scale it. The contract deliberately does not, because a
 * contract guessing at decimals is a contract that will guess wrong.
 */
contract Counterweight {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error IdenticalTokens();
    error ZeroAmount();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientLiquidity();
    error InsufficientOutput();
    error InsufficientInput();
    error InvariantBroken(uint256 kBefore, uint256 kAfter);
    error Slippage(uint256 got, uint256 wanted);
    error Expired();
    error Reentrant();
    error InsufficientBalance(uint256 have, uint256 want);
    error InsufficientAllowance(uint256 have, uint256 want);

    // -------------------------------------------------------------- metadata

    string public constant name = "Counterweight LP";
    string public constant symbol = "CW-LP";
    uint8  public constant decimals = 18;

    // -------------------------------------------------------------- constants

    /// @dev Burned to address(0) on the first deposit and never recoverable
    ///      by anyone. This is what stops the first-depositor attack.
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;

    /// @dev 30 basis points to liquidity providers, taken from the input.
    ///      Not configurable — a pool whose fee can move is a pool whose
    ///      operator can front-run their own users.
    uint256 public constant FEE_BPS = 30;
    uint256 public constant BPS = 10_000;

    // ----------------------------------------------------------------- state

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32  private _blockTimestampLast;

    mapping(address => uint256) private _bal;
    mapping(address => mapping(address => uint256)) private _allow;
    uint256 private _supply;

    uint256 private _lock = 1;

    // ---------------------------------------------------------------- events

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Mint(address indexed to, uint256 amount0, uint256 amount1, uint256 shares);
    event Burn(address indexed from, address indexed to, uint256 amount0, uint256 amount1, uint256 shares);
    event Swap(address indexed who, address indexed to, uint256 in0, uint256 in1, uint256 out0, uint256 out1);
    event Sync(uint112 reserve0, uint112 reserve1);

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2; _; _lock = 1;
    }

    modifier before(uint256 deadline) {
        if (deadline != 0 && block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(IERC20 tokenA, IERC20 tokenB) {
        if (address(tokenA) == address(0) || address(tokenB) == address(0)) revert ZeroAddress();
        if (address(tokenA) == address(tokenB)) revert IdenticalTokens();
        // Sorted, so a pair of the same two tokens always orders the same
        // way no matter which order they were passed in.
        (token0, token1) = address(tokenA) < address(tokenB)
            ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // ------------------------------------------------------------- liquidity

    function getReserves() public view returns (uint112 r0, uint112 r1, uint32 at) {
        return (_reserve0, _reserve1, _blockTimestampLast);
    }

    function _update(uint256 bal0, uint256 bal1) private {
        require(bal0 <= type(uint112).max && bal1 <= type(uint112).max, "overflow");
        _reserve0 = uint112(bal0);
        _reserve1 = uint112(bal1);
        _blockTimestampLast = uint32(block.timestamp);
        emit Sync(_reserve0, _reserve1);
    }

    /**
     * @notice Add liquidity and receive LP shares.
     * @dev Both sides are pulled in the ratio the pool is already at. Any
     *      excess on one side is silently kept by the pool rather than
     *      returned, which is why a UI must quote the correct pair — see
     *      quoteAdd() for the amounts that avoid it.
     */
    function addLiquidity(
        uint256 amount0,
        uint256 amount1,
        uint256 minShares,
        address to,
        uint256 deadline
    ) external nonReentrant before(deadline) returns (uint256 shares) {
        if (to == address(0)) revert ZeroAddress();
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();

        (uint112 r0, uint112 r1, ) = getReserves();

        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        uint256 in0 = bal0 - r0;
        uint256 in1 = bal1 - r1;

        if (_supply == 0) {
            // First deposit sets the price. The minimum is burned to nobody,
            // permanently, so total supply can never fall back to zero while
            // the pool holds anything.
            uint256 initial = _sqrt(in0 * in1);
            if (initial <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();
            shares = initial - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            // The smaller of the two ratios, so nobody can mint shares by
            // adding lopsided liquidity.
            uint256 a = (in0 * _supply) / r0;
            uint256 b = (in1 * _supply) / r1;
            shares = a < b ? a : b;
        }

        if (shares == 0) revert InsufficientLiquidityMinted();
        if (shares < minShares) revert Slippage(shares, minShares);

        _mint(to, shares);
        _update(bal0, bal1);
        emit Mint(to, in0, in1, shares);
    }

    /// @notice Burn LP shares and take back your share of both sides.
    function removeLiquidity(
        uint256 shares,
        uint256 min0,
        uint256 min1,
        address to,
        uint256 deadline
    ) external nonReentrant before(deadline) returns (uint256 amount0, uint256 amount1) {
        if (to == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroAmount();
        uint256 b = _bal[msg.sender];
        if (b < shares) revert InsufficientBalance(b, shares);

        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));

        // Pro-rata on real balances, not stored reserves, so any tokens
        // donated to the pair belong to the LPs rather than to whoever
        // happens to trade next.
        amount0 = (shares * bal0) / _supply;
        amount1 = (shares * bal1) / _supply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
        if (amount0 < min0 || amount1 < min1) revert Slippage(amount0, min0);

        _burn(msg.sender, shares);
        token0.safeTransfer(to, amount0);
        token1.safeTransfer(to, amount1);

        _update(token0.balanceOf(address(this)), token1.balanceOf(address(this)));
        emit Burn(msg.sender, to, amount0, amount1, shares);
    }

    // ------------------------------------------------------------------ swap

    /**
     * @notice Trade one side for the other.
     * @param zeroForOne True to sell token0 and receive token1.
     * @param minOut The least you'll accept. Set it — a zero here means
     *        any price at all is acceptable, which is an invitation.
     */
    function swap(
        bool zeroForOne,
        uint256 amountIn,
        uint256 minOut,
        address to,
        uint256 deadline
    ) external nonReentrant before(deadline) returns (uint256 amountOut) {
        if (to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();

        uint256 received;
        // Scoped so the locals here don't survive into the checks below —
        // without this the function overflows the EVM's stack.
        {
            (uint112 r0, uint112 r1, ) = getReserves();
            if (r0 == 0 || r1 == 0) revert InsufficientLiquidity();
            uint256 rIn  = zeroForOne ? uint256(r0) : uint256(r1);
            uint256 rOut = zeroForOne ? uint256(r1) : uint256(r0);
            IERC20 tokenIn = zeroForOne ? token0 : token1;

            tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
            // Measured, not assumed — a fee-on-transfer token delivers less
            // than it was sent, and pricing the sent amount would let one
            // drain the pool.
            received = tokenIn.balanceOf(address(this)) - rIn;
            if (received == 0) revert InsufficientInput();

            amountOut = _out(received, rIn, rOut);
            if (amountOut == 0) revert InsufficientOutput();
            if (amountOut >= rOut) revert InsufficientLiquidity();
        }
        if (amountOut < minOut) revert Slippage(amountOut, minOut);

        (zeroForOne ? token1 : token0).safeTransfer(to, amountOut);
        _settleSwap(zeroForOne, received, amountOut, to);
    }

    /// @dev Split out purely to keep swap() inside the stack limit. Checks
    ///      the invariant against real balances rather than trusting the
    ///      formula — if any assumption above was wrong, this catches it.
    function _settleSwap(bool zeroForOne, uint256 received, uint256 amountOut, address to) private {
        uint256 kBefore = uint256(_reserve0) * uint256(_reserve1);
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        uint256 kAfter = bal0 * bal1;
        if (kAfter < kBefore) revert InvariantBroken(kBefore, kAfter);

        _update(bal0, bal1);
        emit Swap(msg.sender, to,
            zeroForOne ? received : 0, zeroForOne ? 0 : received,
            zeroForOne ? 0 : amountOut, zeroForOne ? amountOut : 0);
    }

    function _out(uint256 amountIn, uint256 rIn, uint256 rOut) private pure returns (uint256) {
        uint256 inAfterFee = amountIn * (BPS - FEE_BPS);
        return (inAfterFee * rOut) / (rIn * BPS + inAfterFee);
    }

    // ----------------------------------------------------------------- quotes

    /// @notice What a swap would return right now, fee included.
    function quoteSwap(bool zeroForOne, uint256 amountIn)
        external view returns (uint256 amountOut, uint256 fee, uint256 priceImpactBps)
    {
        (uint112 r0, uint112 r1, ) = getReserves();
        if (r0 == 0 || r1 == 0 || amountIn == 0) return (0, 0, 0);
        (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        amountOut = _out(amountIn, rIn, rOut);
        fee = (amountIn * FEE_BPS) / BPS;

        // How far the executed price sits from the pool's price before the
        // trade. The number people should look at and usually don't.
        uint256 idealOut = (amountIn * rOut) / rIn;
        priceImpactBps = idealOut == 0 ? 0 : ((idealOut - amountOut) * BPS) / idealOut;
    }

    /// @notice How much of the other side to pair with a given amount.
    function quoteAdd(uint256 amount0) external view returns (uint256 amount1) {
        (uint112 r0, uint112 r1, ) = getReserves();
        if (r0 == 0) return 0;   // first deposit sets the price; you choose
        return (amount0 * uint256(r1)) / uint256(r0);
    }

    struct Pool {
        address token0; address token1;
        uint256 reserve0; uint256 reserve1;
        uint256 totalShares; uint256 feeBps;
        uint256 lockedShares;
    }

    function pool() external view returns (Pool memory p) {
        p.token0 = address(token0); p.token1 = address(token1);
        p.reserve0 = _reserve0; p.reserve1 = _reserve1;
        p.totalShares = _supply; p.feeBps = FEE_BPS;
        p.lockedShares = _bal[address(0)];
    }

    /// @notice What a share is worth in both tokens right now.
    function shareValue(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        if (_supply == 0) return (0, 0);
        amount0 = (shares * uint256(_reserve0)) / _supply;
        amount1 = (shares * uint256(_reserve1)) / _supply;
    }

    /// @notice Push reserves back in line with real balances. Anyone may
    ///         call it; it only ever recognises tokens already sent here.
    function sync() external nonReentrant {
        _update(token0.balanceOf(address(this)), token1.balanceOf(address(this)));
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
    function _move(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 b = _bal[from];
        if (b < amount) revert InsufficientBalance(b, amount);
        unchecked { _bal[from] = b - amount; }
        _bal[to] += amount;
        emit Transfer(from, to, amount);
    }
    function _mint(address to, uint256 amount) private {
        _bal[to] += amount; _supply += amount;
        emit Transfer(address(0), to, amount);
    }
    function _burn(address from, uint256 amount) private {
        _bal[from] -= amount; _supply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) { z = y; uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; } }
        else if (y != 0) { z = 1; }
    }

    /// @dev No owner, no admin, no pause, no fee switch, no upgrade. The
    ///      pool prices what it holds and cannot be told to do otherwise.
}
