// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

/// @title GitlawbNodeStaking
/// @notice Proof-of-Stake for gitlawb node operators on Base L2.
///
/// Operators stake $GITLAWB to run a node. They must post a heartbeat at
/// least once per 24h. Nodes that have not heartbeat'd within the inactive
/// threshold (3 days) are excluded from reward distribution — their share
/// rolls back into the next epoch's pot.
///
/// Rewards are deposited by the FeeDistributor and distributed pro-rata
/// across active stake (stake × 1 for active, × 0 for offline).
///
/// 7-day cooldown on unstaking. Node is deregistered once unstake completes.
contract GitlawbNodeStaking {
    // ── Types ────────────────────────────────────────────────────────────────

    struct Node {
        address operator;
        string httpUrl;
        uint256 stake;
        uint256 lastHeartbeat;
        uint256 registeredAt;
        uint256 rewardDebt;        // reward offset for pro-rata calc
        uint256 pendingRewards;    // unclaimed rewards
        uint256 unstakeRequestAt;  // timestamp of unstake request (0 = none)
        bool active;               // false after deregister
    }

    // ── Constants ────────────────────────────────────────────────────────────

    uint256 public constant MIN_STAKE = 10_000 * 1e18;       // 10k $GITLAWB
    uint256 public constant HEARTBEAT_WINDOW = 1 days;        // expected cadence
    uint256 public constant INACTIVE_THRESHOLD = 3 days;      // no rewards beyond this
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;

    uint256 private constant ACC_PRECISION = 1e18;

    // ── Storage ──────────────────────────────────────────────────────────────

    IERC20 public immutable token;
    address public owner;

    /// nodeDidHash = keccak256(bytes(nodeDid))
    mapping(bytes32 => Node) public nodes;
    bytes32[] public nodeIds;

    /// Sum of stake across currently-active (heartbeat'd within threshold) nodes.
    /// Updated lazily — on deposit we rebuild from live heartbeats.
    uint256 public totalActiveStake;
    uint256 public totalRegisteredStake;
    uint256 public accRewardPerShare;
    uint256 public totalRewardsDistributed;

    // ── Events ───────────────────────────────────────────────────────────────

    event NodeRegistered(bytes32 indexed nodeDidHash, address indexed operator, string httpUrl, uint256 stake);
    event NodeHeartbeat(bytes32 indexed nodeDidHash, uint256 timestamp);
    event NodeUnstakeRequested(bytes32 indexed nodeDidHash, uint256 availableAt);
    event NodeDeregistered(bytes32 indexed nodeDidHash, uint256 returnedStake);
    event RewardsClaimed(bytes32 indexed nodeDidHash, address indexed operator, uint256 amount);
    event RevenueDeposited(address indexed depositor, uint256 amount, uint256 activeStakeAtDeposit);
    event HttpUrlUpdated(bytes32 indexed nodeDidHash, string httpUrl);

    // ── Errors ───────────────────────────────────────────────────────────────

    error NotOwner();
    error NotOperator();
    error InvalidAmount();
    error BelowMinimumStake();
    error AlreadyRegistered();
    error NodeNotFound();
    error NodeInactive();
    error CooldownNotElapsed();
    error NoPendingUnstake();
    error UnstakePending();
    error NoRewards();
    error NoActiveStake();
    error TransferFailed();
    error ZeroAddress();

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address _token) {
        if (_token == address(0)) revert ZeroAddress();
        token = IERC20(_token);
        owner = msg.sender;
    }

    // ── Core: registration ───────────────────────────────────────────────────

    /// Register a node. Operator must have approved this contract for `stakeAmount`.
    /// `nodeDidHash` is keccak256(bytes(nodeDid)) — pre-hashed to keep storage cheap.
    function registerNode(
        bytes32 nodeDidHash,
        string calldata httpUrl,
        uint256 stakeAmount
    ) external {
        if (stakeAmount < MIN_STAKE) revert BelowMinimumStake();
        Node storage n = nodes[nodeDidHash];
        if (n.operator != address(0)) revert AlreadyRegistered();

        bool ok = token.transferFrom(msg.sender, address(this), stakeAmount);
        if (!ok) revert TransferFailed();

        n.operator = msg.sender;
        n.httpUrl = httpUrl;
        n.stake = stakeAmount;
        n.lastHeartbeat = block.timestamp;
        n.registeredAt = block.timestamp;
        n.active = true;
        // Reward debt starts at current acc — no retroactive rewards
        n.rewardDebt = (stakeAmount * accRewardPerShare) / ACC_PRECISION;

        nodeIds.push(nodeDidHash);
        totalRegisteredStake += stakeAmount;
        totalActiveStake += stakeAmount;

        emit NodeRegistered(nodeDidHash, msg.sender, httpUrl, stakeAmount);
    }

    /// Post a heartbeat. Must be called by the node's operator wallet.
    /// Updates lastHeartbeat; if node was marked inactive due to missed beats,
    /// re-activates it for future distributions.
    function heartbeat(bytes32 nodeDidHash) external {
        Node storage n = nodes[nodeDidHash];
        if (n.operator == address(0)) revert NodeNotFound();
        if (msg.sender != n.operator) revert NotOperator();
        if (!n.active) revert NodeInactive(); // deregistered; cannot re-activate

        // Harvest before (potentially) changing active status
        _harvest(nodeDidHash);

        n.lastHeartbeat = block.timestamp;
        emit NodeHeartbeat(nodeDidHash, block.timestamp);
    }

    /// Update the advertised HTTP URL (e.g. after operator moves hosts).
    function updateHttpUrl(bytes32 nodeDidHash, string calldata httpUrl) external {
        Node storage n = nodes[nodeDidHash];
        if (n.operator == address(0)) revert NodeNotFound();
        if (msg.sender != n.operator) revert NotOperator();
        n.httpUrl = httpUrl;
        emit HttpUrlUpdated(nodeDidHash, httpUrl);
    }

    // ── Core: unstake ────────────────────────────────────────────────────────

    /// Request unstake — starts 7-day cooldown. Node remains in the active set
    /// until unstake() completes (so it can still earn during cooldown if it
    /// heartbeats). Only full-stake unstake is supported — partial would change
    /// the PoS weight mid-epoch.
    function requestUnstake(bytes32 nodeDidHash) external {
        Node storage n = nodes[nodeDidHash];
        if (n.operator == address(0)) revert NodeNotFound();
        if (msg.sender != n.operator) revert NotOperator();
        if (n.unstakeRequestAt != 0) revert UnstakePending();

        _harvest(nodeDidHash);

        n.unstakeRequestAt = block.timestamp;
        emit NodeUnstakeRequested(nodeDidHash, block.timestamp + UNSTAKE_COOLDOWN);
    }

    /// Complete unstake after cooldown. Auto-claims pending rewards.
    function unstake(bytes32 nodeDidHash) external {
        Node storage n = nodes[nodeDidHash];
        if (n.operator == address(0)) revert NodeNotFound();
        if (msg.sender != n.operator) revert NotOperator();
        if (n.unstakeRequestAt == 0) revert NoPendingUnstake();
        if (block.timestamp < n.unstakeRequestAt + UNSTAKE_COOLDOWN) revert CooldownNotElapsed();

        _harvest(nodeDidHash);

        uint256 stakeAmount = n.stake;
        uint256 rewards = n.pendingRewards;

        // Remove from active stake tracking if still counted
        if (_isActive(n)) {
            totalActiveStake -= stakeAmount;
        }
        totalRegisteredStake -= stakeAmount;

        // Wipe node
        n.stake = 0;
        n.pendingRewards = 0;
        n.rewardDebt = 0;
        n.active = false;
        n.unstakeRequestAt = 0;

        uint256 payout = stakeAmount + rewards;
        bool ok = token.transfer(msg.sender, payout);
        if (!ok) revert TransferFailed();

        emit NodeDeregistered(nodeDidHash, stakeAmount);
        if (rewards > 0) emit RewardsClaimed(nodeDidHash, msg.sender, rewards);
    }

    // ── Core: rewards ────────────────────────────────────────────────────────

    /// Claim accumulated rewards for a node without unstaking.
    function claimRewards(bytes32 nodeDidHash) external {
        Node storage n = nodes[nodeDidHash];
        if (n.operator == address(0)) revert NodeNotFound();
        if (msg.sender != n.operator) revert NotOperator();

        _harvest(nodeDidHash);

        uint256 rewards = n.pendingRewards;
        if (rewards == 0) revert NoRewards();
        n.pendingRewards = 0;

        bool ok = token.transfer(msg.sender, rewards);
        if (!ok) revert TransferFailed();

        emit RewardsClaimed(nodeDidHash, msg.sender, rewards);
    }

    /// Deposit revenue from the FeeDistributor. Distributed pro-rata across
    /// currently-active stake (nodes that heartbeat'd within INACTIVE_THRESHOLD).
    /// Inactive nodes are excluded from the divisor and sealed against this
    /// deposit's accRewardPerShare bump so they can't claim its share later.
    function depositRevenue(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();

        // Refresh active stake snapshot before distributing
        _refreshActiveStake();
        uint256 activeStake = totalActiveStake;
        if (activeStake == 0) revert NoActiveStake();

        bool ok = token.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        uint256 len = nodeIds.length;

        // 1. Harvest every node with the PRE-update accRewardPerShare. Active
        //    nodes get their prior accrual credited to pendingRewards; inactive
        //    nodes with no prior accrual no-op (their debt already equals acc).
        for (uint256 i = 0; i < len; i++) {
            _harvest(nodeIds[i]);
        }

        // 2. Bump accRewardPerShare for this deposit.
        accRewardPerShare += (amount * ACC_PRECISION) / activeStake;
        totalRewardsDistributed += amount;

        // 3. Seal inactive nodes against the new acc — advance their rewardDebt
        //    so this deposit's bump is NOT counted as their earnings when they
        //    next interact. Active nodes are left alone; they'll earn their
        //    share at next harvest.
        for (uint256 i = 0; i < len; i++) {
            Node storage n = nodes[nodeIds[i]];
            if (n.stake > 0 && !_isActive(n)) {
                n.rewardDebt = (n.stake * accRewardPerShare) / ACC_PRECISION;
            }
        }

        emit RevenueDeposited(msg.sender, amount, activeStake);
    }

    // ── View functions ───────────────────────────────────────────────────────

    /// Number of registered nodes (including historically-deregistered).
    function nodeCount() external view returns (uint256) {
        return nodeIds.length;
    }

    /// Is a node currently considered active for reward purposes?
    function isActive(bytes32 nodeDidHash) external view returns (bool) {
        return _isActive(nodes[nodeDidHash]);
    }

    /// Pending (unclaimed) rewards for a node.
    function pendingRewards(bytes32 nodeDidHash) external view returns (uint256) {
        Node storage n = nodes[nodeDidHash];
        if (!_isActive(n)) return n.pendingRewards;
        uint256 accumulated = (n.stake * accRewardPerShare) / ACC_PRECISION;
        return n.pendingRewards + accumulated - n.rewardDebt;
    }

    /// Full node info.
    function getNodeInfo(bytes32 nodeDidHash) external view returns (
        address operator,
        string memory httpUrl,
        uint256 stake,
        uint256 lastHeartbeat,
        uint256 registeredAt,
        bool active,
        bool currentlyActive,
        uint256 _pendingRewards,
        uint256 unstakeRequestAt
    ) {
        Node storage n = nodes[nodeDidHash];
        uint256 pending = n.pendingRewards;
        if (_isActive(n)) {
            uint256 accumulated = (n.stake * accRewardPerShare) / ACC_PRECISION;
            pending += accumulated - n.rewardDebt;
        }
        return (
            n.operator,
            n.httpUrl,
            n.stake,
            n.lastHeartbeat,
            n.registeredAt,
            n.active,
            _isActive(n),
            pending,
            n.unstakeRequestAt
        );
    }

    /// Protocol-level stats.
    function getProtocolStats() external view returns (
        uint256 _totalRegisteredStake,
        uint256 _totalActiveStake,
        uint256 _totalRewardsDistributed,
        uint256 _accRewardPerShare,
        uint256 _nodeCount
    ) {
        return (
            totalRegisteredStake,
            totalActiveStake,
            totalRewardsDistributed,
            accRewardPerShare,
            nodeIds.length
        );
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _isActive(Node storage n) internal view returns (bool) {
        if (!n.active || n.stake == 0) return false;
        return block.timestamp <= n.lastHeartbeat + INACTIVE_THRESHOLD;
    }

    function _harvest(bytes32 nodeDidHash) internal {
        Node storage n = nodes[nodeDidHash];
        if (n.stake == 0) return;

        // Credit any earned delta in both branches. Rewards earned while the
        // node was active at deposit time must not be stripped just because the
        // operator missed subsequent heartbeats — `_refreshActiveStake` already
        // prevents FURTHER accrual by excluding inactive nodes from the divisor.
        uint256 accumulated = (n.stake * accRewardPerShare) / ACC_PRECISION;
        if (accumulated > n.rewardDebt) {
            n.pendingRewards += accumulated - n.rewardDebt;
        }
        n.rewardDebt = accumulated;
    }

    /// Walk the nodes array and rebuild totalActiveStake based on live heartbeats.
    /// O(n) in total registered nodes — acceptable for weekly deposits with
    /// reasonable operator counts (< ~1000). For larger sets we'd switch to an
    /// epoch-based checkpoint system.
    function _refreshActiveStake() internal {
        uint256 live = 0;
        uint256 len = nodeIds.length;
        for (uint256 i = 0; i < len; i++) {
            Node storage n = nodes[nodeIds[i]];
            if (_isActive(n)) {
                live += n.stake;
            }
        }
        totalActiveStake = live;
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}
