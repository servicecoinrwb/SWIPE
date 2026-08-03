// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";

interface IFeeSink {
    function recordPayment(address merchant, uint256 volume, uint256 fee) external;
    function clawback(address merchant, uint256 amount) external returns (uint256);
}

/**
 * Terminal — a payment rail whose fee goes to the people using it
 *
 * A card processor charges around 2.9% plus thirty cents, keeps it, and
 * settles to the merchant in two or three days. The 2.9% is the price of
 * running the network. The two or three days is the price of nothing at
 * all — it is float, and it belongs to the processor.
 *
 * This charges a fee too. The difference is where the fee goes, when the
 * merchant gets paid, and what happens as the amounts grow.
 *
 * ─────────────────────────────────────────────────────────────────────
 * THE FEE IS MARGINAL, LIKE A TAX BRACKET
 *
 *   the first  500 USDC   2.50%
 *   up to    5,000        1.00%
 *   above    5,000        0.25%
 *
 * A flat percentage is indefensible at scale — 2.5% of a thirty-eight
 * thousand dollar equipment job is nine hundred and fifty dollars to move
 * a wire, and no amount of comparison to a card network makes that
 * reasonable.
 *
 * Charging each tier only on the portion that falls inside it means the
 * effective rate falls smoothly and never jumps. The alternative, a flat
 * rate per bracket, produces the absurdity of a 500 dollar payment costing
 * less in absolute terms than a 499 dollar one.
 *
 * All three rates are constants. A rail whose operator can reprice it is
 * a rail whose operator can reprice it after you have integrated.
 * ─────────────────────────────────────────────────────────────────────
 *
 * REFUNDS
 *
 * A merchant can send a payment back, whole or in part, for as long as
 * they like. The customer's address is recorded so the money goes where it
 * came from rather than wherever the merchant types.
 *
 * The fee is not returned. It was distributed to stakers the moment it
 * arrived and several of them have probably claimed it — clawing that back
 * would mean reversing other people's balances. So a refunded sale costs
 * the merchant the fee, exactly as a refunded card sale usually does.
 *
 * The SWIPE minted for that sale is burned. You do not keep the reward for
 * a sale you undid.
 *
 * WHAT IT STILL DOES NOT DO
 *
 * No chargebacks, no disputes, no fraud screening, no identity checks, no
 * compliance. A refund here is the merchant choosing to give money back,
 * not a customer forcing them to. A card network is mostly those things
 * and only incidentally a way to move money; this is the moving-money
 * part, which is the easy part.
 */
contract TerminalV4 {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error NotRegistered();
    error AlreadyRegistered();
    error MerchantClosed();
    error BelowMinimum(uint256 sent, uint256 minimum);
    error NoSuchPayment();
    error NotThisMerchant();
    error OverRefund(uint256 asked, uint256 left);
    error Reentrant();

    // -------------------------------------------------------------- constants

    uint256 public constant BPS = 10_000;

    /// @dev Marginal brackets. Each rate applies only to the slice of a
    ///      payment that falls inside it, so the effective rate declines
    ///      smoothly and a larger payment never costs less in absolute terms.
    uint256 public constant TIER1_UPTO = 500e6;      // 500 USDC
    uint256 public constant TIER2_UPTO = 5_000e6;    // 5,000 USDC
    uint256 public constant TIER1_BPS = 250;         // 2.50%
    uint256 public constant TIER2_BPS = 100;         // 1.00%
    uint256 public constant TIER3_BPS = 25;          // 0.25%

    uint256 public constant MIN_PAYMENT = 1e4;       // 0.01 USDC

    /// @dev Below this a payment settles normally but mints nothing. Without
    ///      it, thousands of one-cent payments would be a cheap way to farm
    ///      supply — the gas and fees would cost something, but not enough.
    uint256 public constant MIN_MINT_PAYMENT = 1e6;  // 1.00 USDC

    // ----------------------------------------------------------------- types

    struct Merchant {
        address payout;
        bool    exists;
        bool    closed;
        uint128 received;
        uint128 feesPaid;
        uint128 refunded;
        uint32  payments;
        uint64  since;
        string  name;
    }

    struct Payment {
        address merchant;
        address payer;
        uint128 gross;
        uint128 fee;
        uint128 refunded;
        uint128 minted;
        uint64  at;
    }

    // ----------------------------------------------------------------- state

    IERC20   public immutable token;
    IFeeSink public immutable sink;

    mapping(address => Merchant) private _m;
    address[] private _merchants;

    Payment[] private _payments;

    uint256 public volume;
    uint256 public feesRouted;
    uint256 public refunded;

    uint256 private _lock = 1;

    // ---------------------------------------------------------------- events

    event MerchantOpened(address indexed merchant, address payout, string name);
    event PayoutChanged(address indexed merchant, address from, address to);
    event MerchantClosedEvent(address indexed merchant);
    event Paid(
        uint256 indexed id,
        address indexed merchant,
        address indexed payer,
        uint256 gross,
        uint256 net,
        uint256 fee,
        string ref
    );
    event Refunded(uint256 indexed id, address indexed merchant, address indexed payer, uint256 amount, uint256 clawed);

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2; _; _lock = 1;
    }

    constructor(IERC20 token_, IFeeSink sink_) {
        if (address(token_) == address(0) || address(sink_) == address(0)) revert ZeroAddress();
        token = token_;
        sink = sink_;
    }

    // ------------------------------------------------------------- the tiers

    /// @notice What a payment of this size costs, and the effective rate.
    function feeOn(uint256 amount) public pure returns (uint256 fee) {
        uint256 remaining = amount;

        uint256 slice = remaining > TIER1_UPTO ? TIER1_UPTO : remaining;
        fee += (slice * TIER1_BPS) / BPS;
        remaining -= slice;
        if (remaining == 0) return fee;

        uint256 band2 = TIER2_UPTO - TIER1_UPTO;
        slice = remaining > band2 ? band2 : remaining;
        fee += (slice * TIER2_BPS) / BPS;
        remaining -= slice;
        if (remaining == 0) return fee;

        fee += (remaining * TIER3_BPS) / BPS;
    }

    /// @notice Everything a payer should see before signing.
    function quote(uint256 amount)
        external
        pure
        returns (uint256 gross, uint256 net, uint256 fee, uint256 effectiveBps, uint256 stripeWouldCost, uint256 mints)
    {
        gross = amount;
        fee = feeOn(amount);
        net = amount - fee;
        effectiveBps = amount == 0 ? 0 : (fee * BPS) / amount;
        // 2.9% + 30¢, for comparison — not a claim about anyone's pricing.
        stripeWouldCost = (amount * 290) / BPS + 30_000;
        mints = amount >= MIN_MINT_PAYMENT ? amount : 0;
    }

    // ------------------------------------------------------------- merchants

    function open(string calldata name, address payout) external {
        if (_m[msg.sender].exists) revert AlreadyRegistered();
        address p = payout == address(0) ? msg.sender : payout;
        _m[msg.sender] = Merchant({
            payout: p, exists: true, closed: false,
            received: 0, feesPaid: 0, refunded: 0, payments: 0,
            since: uint64(block.timestamp), name: name
        });
        _merchants.push(msg.sender);
        emit MerchantOpened(msg.sender, p, name);
    }

    function setPayout(address payout) external {
        Merchant storage m = _m[msg.sender];
        if (!m.exists) revert NotRegistered();
        if (payout == address(0)) revert ZeroAddress();
        emit PayoutChanged(msg.sender, m.payout, payout);
        m.payout = payout;
    }

    function close() external {
        Merchant storage m = _m[msg.sender];
        if (!m.exists) revert NotRegistered();
        m.closed = true;
        emit MerchantClosedEvent(msg.sender);
    }

    // ------------------------------------------------------------------- pay

    /**
     * @notice Pay a merchant. Settles in this transaction.
     * @param ref An invoice number or order id. Emitted, never stored, and
     *        public forever — put an identifier here, not a person's name.
     */
    function pay(address merchant, uint256 amount, string calldata ref)
        external
        nonReentrant
        returns (uint256 id)
    {
        Merchant storage m = _m[merchant];
        if (!m.exists) revert NotRegistered();
        if (m.closed) revert MerchantClosed();
        if (amount < MIN_PAYMENT) revert BelowMinimum(amount, MIN_PAYMENT);

        uint256 fee = feeOn(amount);
        uint256 net = amount - fee;
        // Dust payments settle but mint nothing, so supply can't be farmed
        // a cent at a time.
        uint256 mintVolume = amount >= MIN_MINT_PAYMENT ? amount : 0;

        id = _payments.length;
        _payments.push(Payment({
            merchant: merchant, payer: msg.sender,
            gross: uint128(amount), fee: uint128(fee),
            refunded: 0, minted: uint128(mintVolume),
            at: uint64(block.timestamp)
        }));

        m.received += uint128(net);
        m.feesPaid += uint128(fee);
        m.payments += 1;
        volume += amount;
        feesRouted += fee;

        emit Paid(id, merchant, msg.sender, amount, net, fee, ref);

        token.safeTransferFrom(msg.sender, m.payout, net);
        if (fee > 0) token.safeTransferFrom(msg.sender, address(sink), fee);
        sink.recordPayment(merchant, mintVolume, fee);
    }

    // ---------------------------------------------------------------- refund

    /**
     * @notice Send a payment back to whoever made it.
     * @param amount Up to whatever is left unrefunded on that payment.
     * @dev The money goes to the recorded payer, not to an address the
     *      merchant supplies — a refund that can be pointed anywhere is a
     *      withdrawal with a friendly name.
     *
     *      The fee is not returned. It went to stakers when the payment
     *      landed and some will have claimed it; reversing that would mean
     *      reaching into other people's balances.
     */
    function refund(uint256 id, uint256 amount) external nonReentrant {
        if (id >= _payments.length) revert NoSuchPayment();
        Payment storage p = _payments[id];
        if (p.merchant != msg.sender) revert NotThisMerchant();
        if (amount == 0) revert ZeroAmount();

        uint256 left = uint256(p.gross) - uint256(p.refunded);
        if (amount > left) revert OverRefund(amount, left);

        p.refunded += uint128(amount);
        _m[msg.sender].refunded += uint128(amount);
        refunded += amount;

        // Burn the SWIPE minted for the refunded portion. Takes what it can
        // and records any shortfall — this must never block the refund.
        uint256 clawed;
        if (p.minted > 0) {
            uint256 share = (uint256(p.minted) * amount) / uint256(p.gross);
            if (share > 0) clawed = sink.clawback(msg.sender, share * 1e12);
        }

        emit Refunded(id, msg.sender, p.payer, amount, clawed);
        token.safeTransferFrom(msg.sender, p.payer, amount);
    }

    // ----------------------------------------------------------------- views

    struct MerchantView {
        bool exists; bool closed; address payout; string name;
        uint256 received; uint256 feesPaid; uint256 refunded;
        uint32 payments; uint64 since;
    }

    function merchantOf(address who) external view returns (MerchantView memory v) {
        Merchant storage m = _m[who];
        if (!m.exists) return v;
        v.exists = true; v.closed = m.closed; v.payout = m.payout; v.name = m.name;
        v.received = m.received; v.feesPaid = m.feesPaid; v.refunded = m.refunded;
        v.payments = m.payments; v.since = m.since;
    }

    struct PaymentView {
        bool exists;
        address merchant; address payer;
        uint256 gross; uint256 fee; uint256 refunded; uint256 minted;
        uint256 refundable;
        uint64 at;
    }

    function paymentOf(uint256 id) external view returns (PaymentView memory v) {
        if (id >= _payments.length) return v;
        Payment storage p = _payments[id];
        v.exists = true;
        v.merchant = p.merchant; v.payer = p.payer;
        v.gross = p.gross; v.fee = p.fee; v.refunded = p.refunded; v.minted = p.minted;
        v.refundable = uint256(p.gross) - uint256(p.refunded);
        v.at = p.at;
    }

    function paymentCount() external view returns (uint256) { return _payments.length; }

    /// @notice A merchant's payments, newest first, for a receipts list.
    function paymentsOf(address merchant, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _payments.length;
        uint256 found;
        uint256[] memory tmp = new uint256[](limit);
        for (uint256 i = n; i > 0 && found < limit; i--) {
            if (_payments[i - 1].merchant == merchant) { tmp[found] = i - 1; found++; }
        }
        ids = new uint256[](found);
        for (uint256 i = 0; i < found; i++) ids[i] = tmp[i];
    }

    struct Book {
        uint256 volume; uint256 feesRouted; uint256 refunded;
        uint256 payments; uint256 merchants; address sink;
    }

    function book() external view returns (Book memory b) {
        b.volume = volume;
        b.feesRouted = feesRouted;
        b.refunded = refunded;
        b.payments = _payments.length;
        b.merchants = _merchants.length;
        b.sink = address(sink);
    }

    function merchantCount() external view returns (uint256) { return _merchants.length; }
    function merchantAt(uint256 i) external view returns (address) { return _merchants[i]; }

    /// @dev No owner, no admin, no pause, no fee change, no way to redirect
    ///      the sink, and no balance held between transactions.
}
