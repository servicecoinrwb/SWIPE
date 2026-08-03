// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";

interface ITerminal {
    function pay(address merchant, uint256 amount, string calldata ref) external returns (uint256);

    /// @dev Declared as a struct, not as nine flat returns. Those look
    ///      interchangeable and are not: a struct containing a dynamic
    ///      member is encoded as a dynamic tuple, which carries an extra
    ///      offset word that flat returns do not. Getting this wrong makes
    ///      every read revert with no reason data attached.
    struct MerchantView {
        bool exists; bool closed; address payout; string name;
        uint256 received; uint256 feesPaid; uint256 refunded;
        uint32 payments; uint64 since;
    }
    function merchantOf(address who) external view returns (MerchantView memory);
}

/**
 * Draft — money that can only go one place
 *
 * A banker's draft is a payment instrument for an exact amount, funded
 * before it is issued, and worthless to anyone but its named payee. This
 * is that, for a payment rail.
 *
 * Someone with capital — a lender, a landlord, a parent, a company
 * approving an expense — locks an amount and issues a draft to a holder.
 * The holder can spend it, but only at the merchant it names, only up to
 * its face value, and only before it expires. Whatever is left when it
 * expires goes back to whoever funded it.
 *
 * ─────────────────────────────────────────────────────────────────────
 * WHY THIS IS BETTER THAN LENDING SOMEBODY MONEY
 *
 * A homeowner needs a nine thousand dollar equipment changeout and can't
 * pay cash. A financier approves them and wires nine thousand dollars.
 * What happens next is entirely up to the homeowner, and lenders in that
 * business spend real money making sure it goes where it was supposed to.
 *
 * A draft removes the question. The funds are locked at issue and can only
 * ever reach the named contractor's payout address. Not the holder's
 * wallet, not another merchant, not anywhere. The lender has not given
 * anyone money — they have paid an invoice on their behalf, in advance,
 * with the timing left to the holder.
 * ─────────────────────────────────────────────────────────────────────
 *
 * WHAT THIS CONTRACT DOES NOT DO
 *
 * It has no opinion about credit. It does not check anyone's ability to
 * repay, does not record a debt, and will not chase one. The lending
 * relationship lives entirely off this chain — the issuer decides who
 * deserves a draft and collects on whatever terms they agreed. All this
 * does is make sure the money lands where both sides said it would.
 *
 * That is a deliberately small job, and it is the only part of consumer
 * lending a contract can honestly claim to do well.
 */
contract Draft {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error BadWindow();
    error NoSuchDraft();
    error NotHolder();
    error NotIssuer();
    error NotThatMerchant(address named, address tried);
    error MerchantNotOnRail();
    error MerchantNotAccepting();
    error DraftExpired(uint64 at);
    error DraftVoided();
    error DraftSpent();
    error StillLive(uint64 until);
    error OverRemaining(uint256 asked, uint256 left);
    error NothingToReclaim();
    error Reentrant();

    // ----------------------------------------------------------------- types

    enum State { Live, Spent, Expired, Voided }

    struct Note {
        address issuer;
        address holder;
        address merchant;     // the only place it can be spent
        uint128 face;         // what it was issued for
        uint128 spent;
        uint64  issuedAt;
        uint64  expiresAt;
        bool    exists;
        bool    voided;
        bool    reclaimed;
        string  memo;
    }

    // -------------------------------------------------------------- constants

    uint64 public constant MIN_WINDOW = 1 hours;
    uint64 public constant MAX_WINDOW = 365 days;
    uint256 public constant MIN_FACE = 1e6;   // 1.00 USDC

    // ----------------------------------------------------------------- state

    IERC20   public immutable token;
    ITerminal public immutable terminal;

    Note[] private _notes;
    mapping(address => uint256[]) private _held;
    mapping(address => uint256[]) private _issued;

    uint256 public locked;        // face value still escrowed here
    uint256 public totalIssued;
    uint256 public totalSpent;
    uint256 public totalReclaimed;

    uint256 private _lock = 1;

    // ---------------------------------------------------------------- events

    event Issued(uint256 indexed id, address indexed issuer, address indexed holder, address merchant, uint256 face, uint64 expiresAt, string memo);
    event Spent(uint256 indexed id, address indexed holder, address indexed merchant, uint256 amount, uint256 remaining, uint256 paymentId);
    event Voided(uint256 indexed id, address indexed by, uint256 returned);
    event Reclaimed(uint256 indexed id, address indexed issuer, uint256 amount);

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2; _; _lock = 1;
    }

    constructor(IERC20 token_, ITerminal terminal_) {
        if (address(token_) == address(0) || address(terminal_) == address(0)) revert ZeroAddress();
        token = token_;
        terminal = terminal_;
        // Approved once for everything. This contract can only ever spend
        // through pay(), toward a merchant a draft already names, so a
        // standing allowance costs nothing and saves an approval per draft.
        token_.forceApprove(address(terminal_), type(uint256).max);
    }

    // ----------------------------------------------------------------- issue

    /**
     * @notice Fund and issue a draft.
     * @param holder Who may spend it. Only they can.
     * @param merchant Where it may be spent. Only there.
     * @param face The exact amount. Pulled from you now, not later.
     * @param window How long the holder has, in seconds.
     * @param memo What it's for. Public forever — put a job number here,
     *        not a person's circumstances.
     */
    function issue(
        address holder,
        address merchant,
        uint256 face,
        uint64 window,
        string calldata memo
    ) external nonReentrant returns (uint256 id) {
        if (holder == address(0) || merchant == address(0)) revert ZeroAddress();
        if (face < MIN_FACE) revert ZeroAmount();
        if (window < MIN_WINDOW || window > MAX_WINDOW) revert BadWindow();

        // A draft naming a merchant who can't receive is a draft that can
        // never be spent, so it is refused at issue rather than discovered
        // later by whoever was relying on it.
        ITerminal.MerchantView memory mv = terminal.merchantOf(merchant);
        if (!mv.exists) revert MerchantNotOnRail();
        if (mv.closed) revert MerchantNotAccepting();

        id = _notes.length;
        _notes.push(Note({
            issuer: msg.sender, holder: holder, merchant: merchant,
            face: uint128(face), spent: 0,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + window,
            exists: true, voided: false, reclaimed: false,
            memo: memo
        }));
        _held[holder].push(id);
        _issued[msg.sender].push(id);

        locked += face;
        totalIssued += face;

        emit Issued(id, msg.sender, holder, merchant, face, uint64(block.timestamp) + window, memo);
        token.safeTransferFrom(msg.sender, address(this), face);
    }

    // ----------------------------------------------------------------- spend

    /**
     * @notice Spend a draft at the merchant it names.
     * @param amount Any part of what's left, so a job coming in under
     *        estimate doesn't force the holder to overpay.
     * @dev The payment goes through the rail exactly as a normal one does:
     *      the merchant is paid net, the fee reaches the stakers, and the
     *      merchant is minted SWIPE for the volume. A draft is a funding
     *      source, not a side door around the rail.
     */
    function spend(uint256 id, address merchant, uint256 amount, string calldata ref)
        external
        nonReentrant
        returns (uint256 paymentId)
    {
        Note storage n = _at(id);
        if (msg.sender != n.holder) revert NotHolder();
        if (n.voided) revert DraftVoided();
        if (block.timestamp > n.expiresAt) revert DraftExpired(n.expiresAt);
        if (merchant != n.merchant) revert NotThatMerchant(n.merchant, merchant);

        uint256 left = uint256(n.face) - uint256(n.spent);
        if (left == 0) revert DraftSpent();
        if (amount == 0) revert ZeroAmount();
        if (amount > left) revert OverRemaining(amount, left);

        n.spent += uint128(amount);
        locked -= amount;
        totalSpent += amount;

        paymentId = terminal.pay(merchant, amount, ref);
        emit Spent(id, msg.sender, merchant, amount, uint256(n.face) - uint256(n.spent), paymentId);
    }

    // ------------------------------------------------------------ unwinding

    /**
     * @notice Cancel a draft and take the unspent part back.
     * @dev Either party may. The issuer because they funded it and changed
     *      their mind; the holder because a draft they will not use should
     *      not sit locking somebody else's capital until it expires.
     *      Neither can touch what has already been spent.
     */
    function void(uint256 id) external nonReentrant returns (uint256 returned) {
        Note storage n = _at(id);
        if (msg.sender != n.issuer && msg.sender != n.holder) revert NotIssuer();
        if (n.voided) revert DraftVoided();
        // Must check reclaimed as well as voided. Without this, a draft that
        // already expired and paid its remainder back could be voided
        // afterwards and pay the same remainder a second time — out of some
        // other draft's escrow. Two flags, both have to be clear.
        if (n.reclaimed) revert NothingToReclaim();

        returned = uint256(n.face) - uint256(n.spent);
        n.voided = true;
        if (returned > 0) {
            n.reclaimed = true;
            locked -= returned;
            totalReclaimed += returned;
            emit Voided(id, msg.sender, returned);
            token.safeTransfer(n.issuer, returned);
        } else {
            emit Voided(id, msg.sender, 0);
        }
    }

    /**
     * @notice Take back what an expired draft never spent.
     * @dev Callable by anyone once expired — it can only ever send funds to
     *      the original issuer, so who triggers it is irrelevant, and an
     *      issuer who has forgotten shouldn't lose money to their own
     *      forgetfulness.
     */
    function reclaim(uint256 id) external nonReentrant returns (uint256 returned) {
        Note storage n = _at(id);
        if (n.reclaimed || n.voided) revert NothingToReclaim();
        if (block.timestamp <= n.expiresAt) revert StillLive(n.expiresAt);

        returned = uint256(n.face) - uint256(n.spent);
        if (returned == 0) revert NothingToReclaim();

        n.reclaimed = true;
        locked -= returned;
        totalReclaimed += returned;

        emit Reclaimed(id, n.issuer, returned);
        token.safeTransfer(n.issuer, returned);
    }

    // ----------------------------------------------------------------- views

    function _at(uint256 id) private view returns (Note storage n) {
        if (id >= _notes.length) revert NoSuchDraft();
        n = _notes[id];
        if (!n.exists) revert NoSuchDraft();
    }

    struct DraftView {
        bool exists;
        address issuer; address holder; address merchant;
        uint256 face; uint256 spent; uint256 remaining;
        uint64 issuedAt; uint64 expiresAt; uint64 secondsLeft;
        uint8 state;
        bool reclaimed;
        string memo;
    }

    function draftOf(uint256 id) external view returns (DraftView memory v) {
        if (id >= _notes.length) return v;
        Note storage n = _notes[id];
        if (!n.exists) return v;
        v.exists = true;
        v.issuer = n.issuer; v.holder = n.holder; v.merchant = n.merchant;
        v.face = n.face; v.spent = n.spent;
        v.remaining = uint256(n.face) - uint256(n.spent);
        v.issuedAt = n.issuedAt; v.expiresAt = n.expiresAt;
        v.secondsLeft = block.timestamp >= n.expiresAt ? 0 : n.expiresAt - uint64(block.timestamp);
        v.reclaimed = n.reclaimed;
        v.memo = n.memo;
        v.state = uint8(
            n.voided ? State.Voided
            : v.remaining == 0 ? State.Spent
            : block.timestamp > n.expiresAt ? State.Expired
            : State.Live
        );
    }

    function draftsHeldBy(address who) external view returns (uint256[] memory) { return _held[who]; }
    function draftsIssuedBy(address who) external view returns (uint256[] memory) { return _issued[who]; }
    function draftCount() external view returns (uint256) { return _notes.length; }

    struct Book {
        uint256 locked; uint256 totalIssued; uint256 totalSpent;
        uint256 totalReclaimed; uint256 count; address terminal;
    }

    function book() external view returns (Book memory b) {
        b.locked = locked;
        b.totalIssued = totalIssued;
        b.totalSpent = totalSpent;
        b.totalReclaimed = totalReclaimed;
        b.count = _notes.length;
        b.terminal = address(terminal);
    }

    /// @dev No owner, no admin, no pause. Every dollar this contract holds
    ///      belongs to a specific draft and can reach exactly two places:
    ///      the merchant that draft names, or the issuer who funded it.
}
