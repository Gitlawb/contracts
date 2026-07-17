// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

/// Minimal slice of the Chainlink VRF v2.5 coordinator interface. Vendored so
/// the repo stays dependency-free (forge-std only); matches the deployed
/// coordinator ABI on Base.
interface IVRFCoordinatorV2Plus {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId);
}

/// @title GitlawbBurnJackpot
/// @notice Weekly burn lottery: burn $GITLAWB through this contract to earn
/// tickets (1 wei burned = 1 ticket), one winner drawn per epoch via Chainlink
/// VRF v2.5, prize paid in ETH from a rolling pot.
///
/// Mechanics:
///   - Burns go straight to 0x…dEaD, so gitlawb.com/burners keeps counting
///     them; attribution here is by on-chain event instead of a signed message.
///   - Epochs are fixed-length (e.g. 7 days). When an epoch is over, anyone
///     may call `closeEpoch()` — or the next `burnForTickets()` closes it
///     automatically, so the first burn of a new week triggers last week's
///     draw. An epoch with zero tickets rolls over without a draw.
///   - Each draw pays the winner `winnerBps` of the pot (launch: 60%); the
///     remainder stays and compounds with seeds/donations into future epochs.
///   - Prizes are pull-payment: winners `claim()` at their leisure.
///
/// Trust properties, deliberately:
///   - There is NO owner withdrawal. ETH that enters the pot can only ever
///     leave through a VRF-drawn winner's claim. The pot is un-ruggable.
///   - Randomness is Chainlink VRF (subscription, native-ETH payment); the
///     team never touches the dice. The owner can only tune parameters
///     (split, min burn, VRF config) and pause NEW entries — never claims.
contract GitlawbBurnJackpot {
    // ── Types ────────────────────────────────────────────────────────────────

    /// One burn = one entry covering the ticket range
    /// (previous cumulative, cumulative]. Winner lookup is a binary search
    /// for the first entry whose cumulative exceeds the drawn number.
    struct Entry {
        address account;
        uint256 cumulative;
    }

    // ── Storage ──────────────────────────────────────────────────────────────

    IERC20 public immutable token;
    uint256 public immutable epochDuration;
    address public owner;

    // Chainlink VRF v2.5 (updatable in case of a coordinator migration).
    IVRFCoordinatorV2Plus public coordinator;
    bytes32 public keyHash;
    uint256 public subId;
    uint32 public callbackGasLimit = 300_000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;

    /// Winner's share of the pot per draw, in basis points. Remainder rolls.
    uint256 public winnerBps;
    /// Smallest burn that earns tickets (spam floor for the entries array).
    uint256 public minBurn;
    /// Blocks new entries only; draws and claims always work.
    bool public paused;

    uint256 public currentEpoch = 1;
    uint256 public epochEnds;

    mapping(uint256 => Entry[]) private entries; // epoch → entries
    mapping(uint256 => mapping(address => uint256)) public ticketsOf; // epoch → account → tickets
    mapping(uint256 => address) public winnerOf; // epoch → winner (0 until drawn)
    mapping(uint256 => uint256) public prizeOf; // epoch → prize paid
    mapping(uint256 => uint256) public pendingRequest; // epoch → live VRF request id
    mapping(uint256 => uint256) public requestedAt; // epoch → when VRF was requested
    mapping(uint256 => uint256) private requestEpoch; // VRF request id → epoch

    /// ETH owed to winners but not yet claimed. Never part of the pot.
    uint256 public reserved;
    mapping(address => uint256) public claimable;

    // Lifetime accounting (for the public flywheel dashboard)
    uint256 public totalBurnedForTickets;
    uint256 public totalPrizesAwarded;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_BPS = 10_000;
    /// A draw stuck this long without VRF fulfilment may be re-requested.
    uint256 public constant RETRY_DELAY = 4 hours;

    // ── Events ───────────────────────────────────────────────────────────────

    event BurnedForTickets(uint256 indexed epoch, address indexed account, uint256 amount, uint256 epochTickets);
    event EpochClosed(uint256 indexed epoch, uint256 requestId, uint256 totalTickets);
    event EpochRolled(uint256 indexed epoch); // zero entries, no draw
    event WinnerDrawn(uint256 indexed epoch, address indexed winner, uint256 prize, uint256 randomWord);
    event DrawRetried(uint256 indexed epoch, uint256 oldRequestId, uint256 newRequestId);
    event PrizeClaimed(address indexed account, uint256 amount);
    event PotSeeded(address indexed from, uint256 amount);
    event WinnerBpsUpdated(uint256 winnerBps);
    event MinBurnUpdated(uint256 minBurn);
    event VrfConfigUpdated(address coordinator, bytes32 keyHash, uint256 subId, uint32 callbackGasLimit);
    event PausedUpdated(bool paused);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ── Errors ───────────────────────────────────────────────────────────────

    error NotOwner();
    error NotCoordinator();
    error ZeroAddress();
    error BadBps();
    error BurnTooSmall();
    error EntriesPaused();
    error EpochStillOpen();
    error UnknownRequest();
    error AlreadyDrawn();
    error NothingPending();
    error RetryTooSoon();
    error NothingToClaim();
    error TransferFailed();

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _token,
        address _coordinator,
        bytes32 _keyHash,
        uint256 _subId,
        uint256 _epochDuration,
        uint256 _winnerBps,
        uint256 _minBurn
    ) {
        if (_token == address(0) || _coordinator == address(0)) revert ZeroAddress();
        if (_winnerBps == 0 || _winnerBps > MAX_BPS) revert BadBps();
        token = IERC20(_token);
        coordinator = IVRFCoordinatorV2Plus(_coordinator);
        keyHash = _keyHash;
        subId = _subId;
        epochDuration = _epochDuration;
        winnerBps = _winnerBps;
        minBurn = _minBurn;
        owner = msg.sender;
        epochEnds = block.timestamp + _epochDuration;
    }

    // ── Entries ──────────────────────────────────────────────────────────────

    /// Burn $GITLAWB for jackpot tickets, 1 wei = 1 ticket. Tokens go straight
    /// to the burn address. If the current epoch has ended, it is closed first,
    /// so this burn lands in the fresh epoch and triggers the previous draw.
    function burnForTickets(uint256 amount) external {
        if (paused) revert EntriesPaused();
        if (amount < minBurn || amount == 0) revert BurnTooSmall();

        if (block.timestamp >= epochEnds) _closeEpoch();

        if (!token.transferFrom(msg.sender, BURN_ADDRESS, amount)) revert TransferFailed();

        uint256 epoch = currentEpoch;
        Entry[] storage list = entries[epoch];
        uint256 cumulative = list.length == 0 ? amount : list[list.length - 1].cumulative + amount;
        list.push(Entry({account: msg.sender, cumulative: cumulative}));

        ticketsOf[epoch][msg.sender] += amount;
        totalBurnedForTickets += amount;

        emit BurnedForTickets(epoch, msg.sender, amount, ticketsOf[epoch][msg.sender]);
    }

    // ── Draws ────────────────────────────────────────────────────────────────

    /// Permissionless. Ends the current epoch once its deadline has passed:
    /// requests VRF randomness for the draw (or rolls over if nobody entered)
    /// and opens the next epoch immediately — entries never pause.
    function closeEpoch() external {
        if (block.timestamp < epochEnds) revert EpochStillOpen();
        _closeEpoch();
    }

    function _closeEpoch() internal {
        uint256 epoch = currentEpoch;
        uint256 total = _totalTickets(epoch);

        if (total == 0) {
            emit EpochRolled(epoch);
        } else {
            uint256 requestId = _requestRandomness();
            pendingRequest[epoch] = requestId;
            requestedAt[epoch] = block.timestamp;
            requestEpoch[requestId] = epoch;
            emit EpochClosed(epoch, requestId, total);
        }

        currentEpoch = epoch + 1;
        epochEnds = block.timestamp + epochDuration;
    }

    /// If VRF never delivers (subscription ran dry, coordinator hiccup), the
    /// owner can re-request after RETRY_DELAY. The stale request id is
    /// invalidated so a late fulfilment of it cannot double-draw.
    function retryDraw(uint256 epoch) external {
        if (msg.sender != owner) revert NotOwner();
        uint256 oldId = pendingRequest[epoch];
        if (oldId == 0) revert NothingPending();
        if (winnerOf[epoch] != address(0)) revert AlreadyDrawn();
        if (block.timestamp < requestedAt[epoch] + RETRY_DELAY) revert RetryTooSoon();

        delete requestEpoch[oldId];
        uint256 newId = _requestRandomness();
        pendingRequest[epoch] = newId;
        requestedAt[epoch] = block.timestamp;
        requestEpoch[newId] = epoch;
        emit DrawRetried(epoch, oldId, newId);
    }

    /// VRF v2.5 callback entrypoint (subscription, native-ETH payment).
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(coordinator)) revert NotCoordinator();
        uint256 epoch = requestEpoch[requestId];
        if (epoch == 0) revert UnknownRequest();
        if (winnerOf[epoch] != address(0)) revert AlreadyDrawn();

        uint256 word = randomWords[0];
        address winner = _pickWinner(epoch, word % _totalTickets(epoch));

        uint256 prize = (pot() * winnerBps) / MAX_BPS;
        winnerOf[epoch] = winner;
        prizeOf[epoch] = prize;
        claimable[winner] += prize;
        reserved += prize;
        totalPrizesAwarded += prize;

        delete requestEpoch[requestId];
        delete pendingRequest[epoch];

        emit WinnerDrawn(epoch, winner, prize, word);
    }

    /// Binary search for the first entry whose cumulative range covers `n`.
    function _pickWinner(uint256 epoch, uint256 n) internal view returns (address) {
        Entry[] storage list = entries[epoch];
        uint256 lo = 0;
        uint256 hi = list.length - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (list[mid].cumulative > n) hi = mid;
            else lo = mid + 1;
        }
        return list[lo].account;
    }

    function _requestRandomness() internal returns (uint256) {
        return coordinator.requestRandomWords(
            IVRFCoordinatorV2Plus.RandomWordsRequest({
                keyHash: keyHash,
                subId: subId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                // ExtraArgsV1 { nativePayment: true } — pay VRF fees in ETH.
                extraArgs: abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true)
            })
        );
    }

    // ── Prizes & pot ─────────────────────────────────────────────────────────

    function claim() external {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        reserved -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit PrizeClaimed(msg.sender, amount);
    }

    /// Anyone can grow the jackpot: protocol fee routers, whales, anons.
    function seedPot() external payable {
        emit PotSeeded(msg.sender, msg.value);
    }

    receive() external payable {
        emit PotSeeded(msg.sender, msg.value);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /// ETH up for grabs (excludes prizes already owed to past winners).
    function pot() public view returns (uint256) {
        return address(this).balance - reserved;
    }

    function totalTickets(uint256 epoch) external view returns (uint256) {
        return _totalTickets(epoch);
    }

    function entryCount(uint256 epoch) external view returns (uint256) {
        return entries[epoch].length;
    }

    /// Prize the current epoch's winner would take if drawn right now.
    function previewPrize() external view returns (uint256) {
        return (pot() * winnerBps) / MAX_BPS;
    }

    function _totalTickets(uint256 epoch) internal view returns (uint256) {
        Entry[] storage list = entries[epoch];
        return list.length == 0 ? 0 : list[list.length - 1].cumulative;
    }

    // ── Admin ────────────────────────────────────────────────────────────────
    // Note the absence of any ETH/token withdrawal: the pot only pays winners.

    function setWinnerBps(uint256 _winnerBps) external {
        if (msg.sender != owner) revert NotOwner();
        if (_winnerBps == 0 || _winnerBps > MAX_BPS) revert BadBps();
        winnerBps = _winnerBps;
        emit WinnerBpsUpdated(_winnerBps);
    }

    function setMinBurn(uint256 _minBurn) external {
        if (msg.sender != owner) revert NotOwner();
        minBurn = _minBurn;
        emit MinBurnUpdated(_minBurn);
    }

    function setVrfConfig(address _coordinator, bytes32 _keyHash, uint256 _subId, uint32 _callbackGasLimit)
        external
    {
        if (msg.sender != owner) revert NotOwner();
        if (_coordinator == address(0)) revert ZeroAddress();
        coordinator = IVRFCoordinatorV2Plus(_coordinator);
        keyHash = _keyHash;
        subId = _subId;
        callbackGasLimit = _callbackGasLimit;
        emit VrfConfigUpdated(_coordinator, _keyHash, _subId, _callbackGasLimit);
    }

    function setPaused(bool _paused) external {
        if (msg.sender != owner) revert NotOwner();
        paused = _paused;
        emit PausedUpdated(_paused);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
