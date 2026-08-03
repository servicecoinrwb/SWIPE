// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";

interface IFeeSink {
    function recordPayment(address merchant, uint256 volume, uint256 fee) external;
}

/**
 * Terminal — a payment rail whose fee goes to the people using it
 *
 * A card processor charges around 2.9% plus thirty cents, keeps it, and
 * settles to the merchant in two or three days. The 2.9% is the price of
 * running the network. The two or three days is the price of nothing at
 * all — it is float, and it belongs to the processor.
 *
 * This charges a fee too. The difference is where the fee goes and when
 * the merchant gets paid.
 *
 *   Settlement    In the same transaction. Not a batch, not a payout run,
 *                 not T+2. The merchant's share never touches this
 *                 contract's balance sheet because it never stops moving.
 *
 *   The fee       Forwarded to a staking pool in the same call, where it
 *                 is claimable by whoever staked. Nobody here accrues it,
 *                 holds it, or decides later what to do with it.
 *
 * ─────────────────────────────────────────────────────────────────────
 * WHY THE FEE IS NOT THE PITCH
 *
 * At 2.5% this is barely cheaper than the incumbent, and anyone claiming
 * otherwise is counting the thirty cents and hoping you don't. On a
 * four-dollar coffee the flat fee dominates and the saving is real; on a
 * four-thousand-dollar invoice it is a rounding error.
 *
 * The actual difference is that the fee is not revenue for a company. It
 * is distributed to whoever holds the network open. That is a claim this
 * contract can keep, which is more than can be said for most of them.
 *
 * A WARNING ABOUT LARGE TICKETS
 *
 * A flat percentage stops making sense as amounts grow. On a thirty-eight
 * thousand dollar equipment job this charges nine hundred and fifty
 * dollars to move a wire, which is indefensible however it compares to a
 * card network. Real processors cap or negotiate at that size; this
 * contract cannot, because the rate is immutable by design.
 *
 * If large payments matter, deploy a second Terminal at a lower rate and
 * point merchants at whichever fits. That is uglier than a tiered fee and
 * far easier to reason about than an operator who can change the price.
 * ─────────────────────────────────────────────────────────────────────
 *
 * WHAT IT DOES NOT DO
 *
 * No chargebacks, no disputes, no refunds it can enforce, no fraud
 * screening, no identity checks, no compliance of any kind. A card network
 * is mostly those things and only incidentally a way to move money. This
 * is only the moving-money part, which is the easy part, and pretending
 * otherwise would be dishonest about what has actually been built.
 *
 * WHERE THE TOKEN COMES FROM
 *
 * Every payment tells the pool three things: who the merchant was, how
 * much moved, and how much fee it carried. The pool mints the merchant
 * one SWIPE per unit of volume and emits escrowed units to its stakers
 * alongside the fee.
 *
 * Supply therefore starts at zero and grows only when somebody pays for
 * something. Nobody was allocated any, including whoever deployed this,
 * because there is no function that would allow it.
 */
contract TerminalV3 {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh(uint16 bps, uint16 max);
    error NotRegistered();
    error AlreadyRegistered();
    error NotMerchant();
    error MerchantClosed();
    error BelowMinimum(uint256 sent, uint256 minimum);
    error SinkRejected();
    error Reentrant();

    // -------------------------------------------------------------- constants

    uint16 public constant BPS = 10_000;

    /// @dev A hard ceiling, not a setting. A rail whose operator can raise
    ///      the fee to anything is a rail nobody should build on.
    uint16 public constant MAX_FEE_BPS = 300;      // 3.00%

    /// @dev Below this the fee rounds to zero and the sink gets nothing, so
    ///      a payment that small is refused rather than silently free.
    uint256 public constant MIN_PAYMENT = 1e4;     // 0.01 USDC

    // ----------------------------------------------------------------- state

    IERC20  public immutable token;      // USDC
    IFeeSink public immutable sink;      // where fees go, forever
    uint16  public immutable feeBps;

    struct Merchant {
        address payout;
        bool    exists;
        bool    closed;
        uint128 received;    // net of fee, lifetime
        uint128 feesPaid;    // lifetime
        uint32  payments;
        uint64  since;
        string  name;
    }

    mapping(address => Merchant) private _m;
    address[] private _merchants;

    uint256 public volume;       // gross, lifetime
    uint256 public feesRouted;   // lifetime
    uint256 public payments;

    uint256 private _lock = 1;

    // ---------------------------------------------------------------- events

    event MerchantOpened(address indexed merchant, address payout, string name);
    event PayoutChanged(address indexed merchant, address from, address to);
    event MerchantClosedEvent(address indexed merchant);
    event Paid(
        address indexed merchant,
        address indexed payer,
        uint256 gross,
        uint256 net,
        uint256 fee,
        string ref
    );

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2; _; _lock = 1;
    }

    /**
     * @param sink_ The staking pool that receives fees. Immutable, because
     *        a fee destination the operator can repoint is just a fee the
     *        operator collects with extra steps.
     */
    constructor(IERC20 token_, IFeeSink sink_, uint16 feeBps_) {
        if (address(token_) == address(0) || address(sink_) == address(0)) revert ZeroAddress();
        if (feeBps_ == 0) revert ZeroAmount();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_, MAX_FEE_BPS);
        token = token_;
        sink = sink_;
        feeBps = feeBps_;
        // Nothing to approve — fees are sent straight to the pool rather
        // than pulled from here, so this contract never holds a balance
        // even momentarily.
    }

    // ------------------------------------------------------------- merchants

    /// @notice Open an account. Anyone can — there is no gatekeeper here,
    ///         which is a feature and a limitation in equal measure.
    function open(string calldata name, address payout) external {
        if (_m[msg.sender].exists) revert AlreadyRegistered();
        address p = payout == address(0) ? msg.sender : payout;
        _m[msg.sender] = Merchant({
            payout: p, exists: true, closed: false,
            received: 0, feesPaid: 0, payments: 0,
            since: uint64(block.timestamp), name: name
        });
        _merchants.push(msg.sender);
        emit MerchantOpened(msg.sender, p, name);
    }

    /// @notice Send takings somewhere else from now on. Past payments are
    ///         already settled and unaffected.
    function setPayout(address payout) external {
        Merchant storage m = _m[msg.sender];
        if (!m.exists) revert NotRegistered();
        if (payout == address(0)) revert ZeroAddress();
        emit PayoutChanged(msg.sender, m.payout, payout);
        m.payout = payout;
    }

    /// @notice Stop accepting. The record stays readable.
    function close() external {
        Merchant storage m = _m[msg.sender];
        if (!m.exists) revert NotRegistered();
        m.closed = true;
        emit MerchantClosedEvent(msg.sender);
    }

    // ----------------------------------------------------------------- pay

    /**
     * @notice Pay a merchant. Settles in this transaction.
     * @param ref An invoice number, an order id, anything. Emitted,
     *        never stored, and public forever — put an identifier here, not
     *        a customer's name.
     * @dev The fee is taken from the gross, so a merchant quoting 100
     *      receives 97.50 and the payer is charged exactly 100. Charging the
     *      payer on top would make the displayed price a lie.
     */
    function pay(address merchant, uint256 amount, string calldata ref)
        external
        nonReentrant
    {
        Merchant storage m = _m[merchant];
        if (!m.exists) revert NotRegistered();
        if (m.closed) revert MerchantClosed();
        if (amount < MIN_PAYMENT) revert BelowMinimum(amount, MIN_PAYMENT);

        uint256 fee = (amount * feeBps) / BPS;
        uint256 net = amount - fee;

        // effects
        m.received += uint128(net);
        m.feesPaid += uint128(fee);
        m.payments += 1;
        volume += amount;
        feesRouted += fee;
        payments += 1;

        emit Paid(merchant, msg.sender, amount, net, fee, ref);

        // interactions — the payer's money splits and leaves in one motion
        token.safeTransferFrom(msg.sender, m.payout, net);
        if (fee > 0) token.safeTransferFrom(msg.sender, address(sink), fee);

        // Tell the pool what happened. It mints the merchant's SWIPE and
        // shares the fee out in the same call. If this ever reverted the
        // payment would revert with it — better a failed payment than a
        // fee sitting in a pool that doesn't know it arrived.
        sink.recordPayment(merchant, amount, fee);
    }

    // ----------------------------------------------------------------- views

    /// @notice What a payment of this size costs, before anyone signs.
    function quote(uint256 amount)
        external
        view
        returns (uint256 gross, uint256 net, uint256 fee, uint256 stripeWouldCost)
    {
        gross = amount;
        fee = (amount * feeBps) / BPS;
        net = amount - fee;
        // 2.9% + 30¢, at six decimals — for comparison, not a claim about
        // any particular processor's current pricing.
        stripeWouldCost = (amount * 290) / BPS + 300_000 / 10;
    }

    struct MerchantView {
        bool exists;
        bool closed;
        address payout;
        string name;
        uint256 received;
        uint256 feesPaid;
        uint32  payments;
        uint64  since;
    }

    function merchantOf(address who) external view returns (MerchantView memory v) {
        Merchant storage m = _m[who];
        if (!m.exists) return v;
        v.exists = true; v.closed = m.closed; v.payout = m.payout; v.name = m.name;
        v.received = m.received; v.feesPaid = m.feesPaid;
        v.payments = m.payments; v.since = m.since;
    }

    struct Book {
        uint256 volume;
        uint256 feesRouted;
        uint256 payments;
        uint256 merchants;
        uint16  feeBps;
        address sink;
    }

    function book() external view returns (Book memory b) {
        b.volume = volume;
        b.feesRouted = feesRouted;
        b.payments = payments;
        b.merchants = _merchants.length;
        b.feeBps = feeBps;
        b.sink = address(sink);
    }

    function merchantCount() external view returns (uint256) { return _merchants.length; }
    function merchantAt(uint256 i) external view returns (address) { return _merchants[i]; }

    /// @dev No owner, no admin, no pause, no fee change, no way to redirect
    ///      the sink, and no balance held between transactions. This
    ///      contract cannot be made to pay anyone but the merchant and the
    ///      stakers, because there is no function that would.
}
