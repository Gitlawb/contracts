// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

/// @title GitlawbBounty
/// @notice Token-powered bounty marketplace for AI agents on Base L2.
///
/// Repo owners post bounties (denominated in $GITLAWB) on issues.
/// Agents claim bounties, submit PRs, and get paid on approval.
/// Protocol takes a 5% fee on every completed bounty.
contract GitlawbBounty {
    // ── Types ────────────────────────────────────────────────────────────────

    enum Status {
        Open,       // 0 — waiting for an agent to claim
        Claimed,    // 1 — agent is working on it
        Submitted,  // 2 — agent submitted a PR, pending approval
        Completed,  // 3 — owner approved, funds released
        Cancelled,  // 4 — owner cancelled (unclaimed only)
        Disputed    // 5 — expired claim, bounty re-opened
    }

    struct Bounty {
        address creator;
        uint256 amount;
        string repoOwner;
        string repoName;
        string issueId;
        string title;
        string claimantDid;      // DID of the agent that claimed
        address claimantAddress;  // wallet of the claimant (for payout)
        string prId;             // PR submitted as completion
        Status status;
        uint256 createdAt;
        uint256 claimedAt;
        uint256 submittedAt;
        uint256 completedAt;
        uint256 deadline;        // seconds from claim — auto-dispute after
        uint256 feeBpsSnapshot;  // PR #11 : fee in effect when bounty was created
    }

    // ── Storage ──────────────────────────────────────────────────────────────

    IERC20 public immutable token;
    address public treasury;
    address public owner;
    uint256 public protocolFeeBps; // basis points (500 = 5%)
    uint256 public nextBountyId;
    uint256 public defaultDeadline; // seconds (default 7 days)

    mapping(uint256 => Bounty) public bounties;

    /// Track total earnings per agent DID (keccak256 hash)
    mapping(bytes32 => uint256) public agentEarnings;
    /// Track completed bounty count per agent DID
    mapping(bytes32 => uint256) public agentCompletedCount;
    /// Total $GITLAWB paid out through bounties
    uint256 public totalPaidOut;
    /// Total protocol fees collected
    uint256 public totalFeesCollected;

    // ── Events ───────────────────────────────────────────────────────────────

    event BountyCreated(uint256 indexed bountyId, address indexed creator, uint256 amount, string repoOwner, string repoName, string issueId, string title);
    event BountyClaimed(uint256 indexed bountyId, string claimantDid, address indexed claimantAddress);
    event BountySubmitted(uint256 indexed bountyId, string prId);
    event BountyCompleted(uint256 indexed bountyId, address indexed claimant, uint256 payout, uint256 fee);
    event BountyCancelled(uint256 indexed bountyId);
    event BountyDisputed(uint256 indexed bountyId);
    event TreasuryUpdated(address indexed newTreasury);
    event FeeUpdated(uint256 newFeeBps);

    // ── Errors ───────────────────────────────────────────────────────────────

    error NotOwner();
    error NotBountyCreator(uint256 bountyId);
    error InvalidAmount();
    error InvalidStatus(uint256 bountyId, Status expected, Status actual);
    error DeadlineExceeded(uint256 bountyId);
    error DeadlineNotExceeded(uint256 bountyId);
    error TransferFailed();
    error ZeroAddress();

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyBountyCreator(uint256 bountyId) {
        if (msg.sender != bounties[bountyId].creator) revert NotBountyCreator(bountyId);
        _;
    }

    modifier inStatus(uint256 bountyId, Status expected) {
        Status actual = bounties[bountyId].status;
        if (actual != expected) revert InvalidStatus(bountyId, expected, actual);
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address _token, address _treasury) {
        token = IERC20(_token);
        treasury = _treasury;
        owner = msg.sender;
        protocolFeeBps = 500; // 5%
        defaultDeadline = 7 days;
    }

    // ── Core functions ───────────────────────────────────────────────────────

    /// Create a bounty — escrows `amount` $GITLAWB from msg.sender.
    /// Caller must have approved this contract for `amount` tokens first.
    function createBounty(
        uint256 amount,
        string calldata repoOwner,
        string calldata repoName,
        string calldata issueId,
        string calldata title
    ) external returns (uint256 bountyId) {
        if (amount == 0) revert InvalidAmount();

        bool ok = token.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        bountyId = nextBountyId++;

        bounties[bountyId] = Bounty({
            creator: msg.sender,
            amount: amount,
            repoOwner: repoOwner,
            repoName: repoName,
            issueId: issueId,
            title: title,
            claimantDid: "",
            claimantAddress: address(0),
            prId: "",
            status: Status.Open,
            createdAt: block.timestamp,
            claimedAt: 0,
            submittedAt: 0,
            completedAt: 0,
            deadline: defaultDeadline,
            feeBpsSnapshot: protocolFeeBps // PR #11 : lock the fee at escrow time
        });

        emit BountyCreated(bountyId, msg.sender, amount, repoOwner, repoName, issueId, title);
    }

    /// Agent claims an open bounty. Starts the deadline clock.
    function claimBounty(
        uint256 bountyId,
        string calldata agentDid
    ) external inStatus(bountyId, Status.Open) {
        Bounty storage b = bounties[bountyId];
        b.claimantDid = agentDid;
        b.claimantAddress = msg.sender;
        b.claimedAt = block.timestamp;
        b.status = Status.Claimed;

        emit BountyClaimed(bountyId, agentDid, msg.sender);
    }

    /// Agent submits a PR as bounty completion. Only the claimant can call.
    function submitBounty(
        uint256 bountyId,
        string calldata prId
    ) external inStatus(bountyId, Status.Claimed) {
        Bounty storage b = bounties[bountyId];
        require(msg.sender == b.claimantAddress, "only claimant");
        if (block.timestamp > b.claimedAt + b.deadline) revert DeadlineExceeded(bountyId);

        b.prId = prId;
        b.submittedAt = block.timestamp;
        b.status = Status.Submitted;

        emit BountySubmitted(bountyId, prId);
    }

    /// Bounty creator approves completion — releases funds to agent minus protocol fee.
    function approveBounty(
        uint256 bountyId
    ) external onlyBountyCreator(bountyId) inStatus(bountyId, Status.Submitted) {
        Bounty storage b = bounties[bountyId];

        // PR #11 fix : honor the fee that was in effect when the bounty was
        // created. Stops the owner-induced rugpull where setProtocolFee bumps
        // the fee on already-escrowed funds, stealing from the agent's payout.
        uint256 fee = (b.amount * b.feeBpsSnapshot) / 10000;
        uint256 payout = b.amount - fee;

        b.status = Status.Completed;
        b.completedAt = block.timestamp;

        // Transfer payout to agent
        bool ok1 = token.transfer(b.claimantAddress, payout);
        if (!ok1) revert TransferFailed();

        // Transfer fee to treasury
        if (fee > 0) {
            bool ok2 = token.transfer(treasury, fee);
            if (!ok2) revert TransferFailed();
        }

        // Update agent stats
        bytes32 didHash = keccak256(bytes(b.claimantDid));
        agentEarnings[didHash] += payout;
        agentCompletedCount[didHash] += 1;
        totalPaidOut += payout;
        totalFeesCollected += fee;

        emit BountyCompleted(bountyId, b.claimantAddress, payout, fee);
    }

    /// Cancel an open (unclaimed) bounty — refunds creator.
    function cancelBounty(
        uint256 bountyId
    ) external onlyBountyCreator(bountyId) inStatus(bountyId, Status.Open) {
        Bounty storage b = bounties[bountyId];
        b.status = Status.Cancelled;

        bool ok = token.transfer(b.creator, b.amount);
        if (!ok) revert TransferFailed();

        emit BountyCancelled(bountyId);
    }

    /// Dispute a bounty if the agent missed the deadline.
    /// Anyone can call this — bounty returns to Open status.
    function disputeBounty(
        uint256 bountyId
    ) external {
        Bounty storage b = bounties[bountyId];
        // Can dispute Claimed or Submitted if deadline passed
        if (b.status != Status.Claimed && b.status != Status.Submitted) {
            revert InvalidStatus(bountyId, Status.Claimed, b.status);
        }
        if (block.timestamp <= b.claimedAt + b.deadline) {
            revert DeadlineNotExceeded(bountyId);
        }

        b.status = Status.Open;
        b.claimantDid = "";
        b.claimantAddress = address(0);
        b.prId = "";
        b.claimedAt = 0;
        b.submittedAt = 0;

        emit BountyDisputed(bountyId);
    }

    // ── View functions ───────────────────────────────────────────────────────

    /// Get bounty core details.
    function getBountyCore(uint256 bountyId) external view returns (
        address creator,
        uint256 amount,
        string memory title,
        Status status,
        uint256 createdAt,
        uint256 deadline
    ) {
        Bounty storage b = bounties[bountyId];
        return (b.creator, b.amount, b.title, b.status, b.createdAt, b.deadline);
    }

    /// Get bounty claim details.
    function getBountyClaim(uint256 bountyId) external view returns (
        string memory claimantDid,
        address claimantAddress,
        string memory prId,
        string memory repoOwner,
        string memory repoName,
        string memory issueId
    ) {
        Bounty storage b = bounties[bountyId];
        return (b.claimantDid, b.claimantAddress, b.prId, b.repoOwner, b.repoName, b.issueId);
    }

    /// Get agent stats by DID.
    function getAgentStats(string calldata agentDid) external view returns (
        uint256 earnings,
        uint256 completedCount
    ) {
        bytes32 didHash = keccak256(bytes(agentDid));
        return (agentEarnings[didHash], agentCompletedCount[didHash]);
    }

    /// Protocol stats.
    function getProtocolStats() external view returns (
        uint256 totalBounties,
        uint256 _totalPaidOut,
        uint256 _totalFeesCollected
    ) {
        return (nextBountyId, totalPaidOut, totalFeesCollected);
    }

    // ── Admin functions ──────────────────────────────────────────────────────

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setProtocolFee(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 1000, "fee too high"); // max 10%
        protocolFeeBps = _feeBps;
        emit FeeUpdated(_feeBps);
    }

    function setDefaultDeadline(uint256 _seconds) external onlyOwner {
        require(_seconds >= 1 hours, "deadline too short");
        defaultDeadline = _seconds;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}
