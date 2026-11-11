import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

contract EscrowVault is EIP712, ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;
    enum State {
        None,
        Funded,
        Delivered,
        Disputed,
        Ruled,
        Appealed,
        Resolved
    }
    enum Reason {
        Released,
        ReviewElapsed,
        Undelivered,
        Ruling,
        AppealRuling,
        Timeout
    }

    struct Agreement {
        address client; // slot 0
        uint48 deadline;
        State state;
        address provider; // slot 1
        uint48 stateAt;
        uint128 amount; // slot 2
        uint8 ruledRound;
        uint8 pct1;
        uint8 pct2;
        bytes32 termsHash; // slot 3
    }

    uint48 public constant REVIEW_WINDOW = 7 days;
    uint48 public constant DEADLINE_GRACE = 3 days;
    uint48 public constant APPEAL_WINDOW = 48 hours;
    uint48 public constant VERDICT_TIMEOUT = 14 days;
    uint16 public constant MAX_FEE_BPS = 500;
    bytes32 public constant ACCEPT_TYPEHASH = keccak256(
        "Accept(address client,address provider,uint128 amount,uint48 deadline,bytes32 termsHash,uint256 nonce)"
    );

    IERC20 public immutable token;
    address public immutable treasury;
    address public immutable executor;
    address public immutable appealCourt;
    uint16 public immutable feeBps;

    uint256 public nextId = 1;
    uint256 public totalEscrowed;
    uint256 public totalClaimable;
    uint128 public maxEscrow;
    uint128 public maxTotal;

    mapping(uint256 => Agreement) public _a;
    mapping(address => uint256) public claimable;
    mapping(address => mapping(uint256 => bool)) public usedNonce;

    error BadState(State actual);
    error NotClient();
    error NotProvider();
    error NotParty();
    error NotExecutor();
    error NotAppealCourt();
    error TooEarly();
    error TooLate();
    error BadParams();
    error CapExceeded();
    error BadSignature();
    error BadPct();
    error BadRound();
    error NothingToClaim();

    event AgreementCreated(
        uint256 indexed id,
        address indexed client,
        address indexed provider,
        uint128 amount,
        uint48 deadline,
        bytes32 termsHash
    );
    event Delivered(uint256 indexed id);
    event DisputeOpened(uint256 indexed id);
    event EvidenceCommitted(uint256 indexed id, address indexed party, bytes32 hash);
    event RulingRecorded(uint256 indexed id, uint8 round, uint8 clientPct, bytes32 reasoningHash);
    event AppealFiled(uint256 indexed id);
    event Settled(uint256 indexed id, uint256 toClient, uint256 toProvider, Reason reason);
    event PayoutDeferred(address indexed to, uint256 amount);

    constructor(
        IERC20 _token,
        address _treasury,
        address _executor,
        address _appealCourt,
        uint16 _feeBps,
        uint128 _maxEscrow,
        uint128 _maxTotal,
        address _owner
    ) EIP712("EscrowVault", "1") Ownable(_owner) {
        if (_feeBps > MAX_FEE_BPS) revert BadParams();
        token = _token;
        treasury = _treasury;
        executor = _executor;
        appealCourt = _appealCourt;
        feeBps = _feeBps;
        maxEscrow = _maxEscrow;
        maxTotal = _maxTotal;
        _transferOwnership(_owner);
    }

    function createAgreement(
        address provider,
        uint128 amount,
        uint48 deadline,
        bytes32 termsHash,
        uint256 nonce,
        bytes calldata providerSig
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        if (provider == address(0) || amount == 0 || deadline <= block.timestamp || termsHash == bytes32(0)) revert BadParams();
        if (amount > maxEscrow || totalEscrowed + amount > maxTotal) revert CapExceeded();
        _verifyAcceptance(provider, amount, deadline, termsHash, nonce, providerSig);
        id = nextId++;
        _a[id] = Agreement({
            client: msg.sender,
            provider: provider,
            amount: amount,
            deadline: deadline,
            state: State.Funded,
            stateAt: uint48(block.timestamp),
            ruledRound: 0,
            pct1: 0,
            pct2: 0,
            termsHash: termsHash
        });
        totalEscrowed += amount;
        emit AgreementCreated(id, msg.sender, provider, amount, deadline, termsHash);
        _collect(amount);
    }

    function _verifyAcceptance(
        address provider,
        uint128 amount,
        uint48 deadline,
        bytes32 termsHash,
        uint256 nonce,
        bytes calldata sig
    ) internal {
        if (usedNonce[provider][nonce]) revert BadParams();
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(ACCEPT_TYPEHASH, msg.sender, provider, amount, deadline, termsHash, nonce))
        );
        if (!SignatureChecker.isValidSignatureNow(provider, digest, sig)) revert BadSignature();
        usedNonce[provider][nonce] = true;
    }

    function _collect(uint128 amount) internal {
        uint256 fee = (uint256(amount) * feeBps) / 10_000;
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (fee != 0) token.safeTransferFrom(msg.sender, treasury, fee);
    }

    function markDelivered(uint256 id) external whenNotPaused nonReentrant {
        Agreement storage a = _a[id];
        if (msg.sender != a.client) revert NotClient();
        if (a.state != State.Funded) revert BadState(a.state);
        a.state = State.Delivered;
        a.stateAt = uint48(block.timestamp);
        emit Delivered(id);
    }

    function release(uint256 id) external nonReentrant {
        Agreement storage a = _a[id];
        if (msg.sender != a.client) revert NotClient();
        if (a.state != State.Funded && a.state != State.Delivered) revert BadState(a.state);
        _settle(id, a.amount, 0, Reason.Released);
    }

    function claimAfterReview(uint256 id) external nonReentrant {
        Agreement storage a = _a[id];
        if (a.state != State.Delivered) revert BadState(a.state);
        if (block.timestamp <= a.stateAt + REVIEW_WINDOW) revert TooEarly();
        _settle(id, a.amount, 0, Reason.ReviewElapsed);
    }

    function refundUndelivered(uint256 id) external nonReentrant {
        Agreement storage a = _a[id];
        if (a.state != State.Funded) revert BadState(a.state);
        if (block.timestamp <= a.deadline + DEADLINE_GRACE) revert TooEarly();
        _settle(id, a.amount, 100, Reason.Undelivered); // 100% to client
    }

    function openDispute(uint256 id) external {
        Agreement storage a = _a[id];
        if (msg.sender != a.client) revert NotClient();
        if (a.state == State.Funded) {
            if (block.timestamp <= a.deadline) revert TooEarly();
        } else if (a.state == State.Delivered) {
            if (block.timestamp > a.stateAt + REVIEW_WINDOW) revert TooLate();
        } else {
            revert BadState(a.state);
        }
        a.state = State.Disputed;
        a.stateAt = uint48(block.timestamp);
        emit DisputeOpened(id);
    }

    function commitEvidence(uint256 id, bytes32 hash) external {
        Agreement storage a = _a[id];
        if (msg.sender != a.client && msg.sender != a.provider) revert NotParty();
        if (a.state != State.Disputed) revert BadState(a.state);
        emit EvidenceCommitted(id, msg.sender, hash);
    }

    function recordRuling(uint256 id, uint8 round, uint8 clientPct, bytes32 reasoningHash) external nonReentrant {
        if (msg.sender != executor) revert NotExecutor();
        if (clientPct > 100) revert BadPct();
        Agreement storage a = _a[id];
        if (round == 1 && a.state == State.Disputed) {
            a.ruledRound = 1;
            a.pct1 = clientPct;
            a.state = State.Ruled;
            a.stateAt = uint48(block.timestamp);
            emit RulingRecorded(id, 1, clientPct, reasoningHash);
        } else if (round == 2 && a.state == State.Appealed) {
            a.ruledRound = 2;
            a.pct2 = clientPct;
            emit RulingRecorded(id, 2, clientPct, reasoningHash);
            _settle(id, a.amount, clientPct, Reason.AppealRuling);
        } else {
            revert BadRound();
        }
    }

    function markAppealed(uint256 id) external {
        if (msg.sender != appealCourt) revert NotAppealCourt();
        Agreement storage a = _a[id];
        if (a.state != State.Ruled) revert BadState(a.state);
        if (block.timestamp > a.stateAt + APPEAL_WINDOW) revert TooLate();
        a.state = State.Appealed;
        a.stateAt = uint48(block.timestamp);
        emit AppealFiled(id);
    }

    function settleRuling(uint256 id) external nonReentrant {
        Agreement storage a = _a[id];
        if (a.state != State.Ruled) revert BadState(a.state);
        if (block.timestamp <= a.stateAt + APPEAL_WINDOW) revert TooEarly();
        _settle(id, a.amount, a.pct1, Reason.Ruling);
    }

    function timeoutSplit(uint256 id) external nonReentrant {
        Agreement storage a = _a[id];
        if (a.state != State.Disputed && a.state != State.Appealed) revert BadState(a.state);
        if (block.timestamp <= a.stateAt + VERDICT_TIMEOUT) revert TooEarly();
        _settle(id, a.amount, a.state == State.Disputed ? 50 : a.pct1, Reason.Timeout);
    }

    function _settle(uint256 id, uint128 toClient, uint128 toProvider, Reason reason) internal {
        Agreement storage a = _a[id];
        if (a.state == State.Resolved) revert BadState(a.state);
        a.state = State.Resolved;
        a.stateAt = uint48(block.timestamp);
        totalEscrowed -= a.amount;

        emit Settled(id, toClient, toProvider, reason);

        if (toClient != 0) {
            _push(a.client, toClient);
        }
        if (toProvider != 0) {
            _push(a.provider, toProvider);
        }
    }

    function _push(address to, uint256 amt) private {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amt)));
        if (!(ok && ret.length == 32 && abi.decode(ret, (bool)))) {
            claimable[to] += amt; // e.g. USDC blacklisted this address
            totalClaimable += amt;
            emit PayoutDeferred(to, amt);
        }
    }

    function withdrawClaimable() external nonReentrant {
        uint256 amt = claimable[msg.sender];
        if (amt == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        totalClaimable -= amt;
        token.safeTransfer(msg.sender, amt);
    }

    function getAgreement(uint256 id) external view returns (Agreement memory) {
        return _a[id];
    }

    function parties(uint256 id) external view returns (address, address, uint128) {
        Agreement storage a = _a[id];
        return (a.client, a.provider, a.amount);
    }

    function rulingInfo(uint256 id) external view returns (State, uint8, uint8, uint8) {
        Agreement storage a = _a[id];
        return (a.state, a.ruledRound, a.pct1, a.pct2);
    }
}
