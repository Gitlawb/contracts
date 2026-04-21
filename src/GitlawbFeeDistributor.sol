// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

interface IRevenueSink {
    function depositRevenue(uint256 amount) external;
}

/// @title GitlawbFeeDistributor
/// @notice The protocol reward wallet.
///
/// Accumulates $GITLAWB from every fee source:
///   - GitlawbBounty (5% protocol fee via setTreasury)
///   - Manual deposits from bankr (treasury → this address)
///   - Future protocol services (node fees, name registrations, etc.)
///
/// Once every 7 days, anyone can call `distribute()` which splits the full
/// balance between two sinks and pays the caller a small keeper reward:
///
///   75%  → GitlawbNodeStaking  (PoS operator rewards)
///   24%  → GitlawbStaking      (passive user stakers)
///    1%  → msg.sender          (keeper reward)
///
/// The split is owner-adjustable but constrained to sum to 10,000 bps and
/// capped per-change to prevent abrupt reallocations.
contract GitlawbFeeDistributor {
    // ── Storage ──────────────────────────────────────────────────────────────

    IERC20 public immutable token;
    address public owner;

    IRevenueSink public nodeStaking;
    IRevenueSink public userStaking;

    uint256 public nodeShareBps;    // default 7500
    uint256 public userShareBps;    // default 2400
    uint256 public keeperShareBps;  // default  100
    // invariant: nodeShareBps + userShareBps + keeperShareBps == 10000

    uint256 public constant DISTRIBUTION_PERIOD = 7 days;
    uint256 public constant MAX_BPS_CHANGE = 500; // owner can shift at most 5% per update
    uint256 public constant MIN_DISTRIBUTION = 1e18; // 1 token — dust gate

    uint256 public lastDistribution;
    uint256 public totalDistributed;
    uint256 public distributionCount;

    // ── Events ───────────────────────────────────────────────────────────────

    event FeesDistributed(
        uint256 indexed epoch,
        uint256 total,
        uint256 nodeShare,
        uint256 userShare,
        uint256 keeperShare,
        address indexed keeper
    );
    event SplitUpdated(uint256 nodeShareBps, uint256 userShareBps, uint256 keeperShareBps);
    event SinksUpdated(address nodeStaking, address userStaking);

    // ── Errors ───────────────────────────────────────────────────────────────

    error NotOwner();
    error TooSoon(uint256 availableAt);
    error NothingToDistribute();
    error BadSplit();
    error ChangeTooLarge();
    error ZeroAddress();
    error TransferFailed();

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address _token, address _nodeStaking, address _userStaking) {
        if (_token == address(0) || _nodeStaking == address(0) || _userStaking == address(0)) {
            revert ZeroAddress();
        }
        token = IERC20(_token);
        nodeStaking = IRevenueSink(_nodeStaking);
        userStaking = IRevenueSink(_userStaking);
        owner = msg.sender;

        nodeShareBps = 7500;
        userShareBps = 2400;
        keeperShareBps = 100;

        // Start the clock so the first distribution fires one period after deploy
        lastDistribution = block.timestamp;
    }

    // ── Core ─────────────────────────────────────────────────────────────────

    /// Permissionless weekly distribution. Caller receives `keeperShareBps` of
    /// the pot for triggering it.
    function distribute() external {
        uint256 next = lastDistribution + DISTRIBUTION_PERIOD;
        if (block.timestamp < next) revert TooSoon(next);

        uint256 bal = token.balanceOf(address(this));
        if (bal < MIN_DISTRIBUTION) revert NothingToDistribute();

        lastDistribution = block.timestamp;
        distributionCount += 1;
        totalDistributed += bal;

        uint256 keeperShare = (bal * keeperShareBps) / 10_000;
        uint256 nodeShare = (bal * nodeShareBps) / 10_000;
        // userShare takes the remainder so we don't leave dust
        uint256 userShare = bal - keeperShare - nodeShare;

        // Keeper first (no external call dependency)
        if (keeperShare > 0) {
            bool ok = token.transfer(msg.sender, keeperShare);
            if (!ok) revert TransferFailed();
        }

        // Node staking sink
        if (nodeShare > 0) {
            bool ok = token.approve(address(nodeStaking), nodeShare);
            if (!ok) revert TransferFailed();
            nodeStaking.depositRevenue(nodeShare);
        }

        // User staking sink
        if (userShare > 0) {
            bool ok = token.approve(address(userStaking), userShare);
            if (!ok) revert TransferFailed();
            userStaking.depositRevenue(userShare);
        }

        emit FeesDistributed(distributionCount, bal, nodeShare, userShare, keeperShare, msg.sender);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function nextDistributionAt() external view returns (uint256) {
        return lastDistribution + DISTRIBUTION_PERIOD;
    }

    function pendingBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// Preview the split of the current balance without executing.
    function previewDistribution() external view returns (
        uint256 total,
        uint256 nodeShare,
        uint256 userShare,
        uint256 keeperShare
    ) {
        uint256 bal = token.balanceOf(address(this));
        keeperShare = (bal * keeperShareBps) / 10_000;
        nodeShare = (bal * nodeShareBps) / 10_000;
        userShare = bal - keeperShare - nodeShare;
        return (bal, nodeShare, userShare, keeperShare);
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    /// Update the split. Each bps value may change by at most MAX_BPS_CHANGE
    /// per update, and the three must sum to 10,000.
    function setSplit(uint256 _nodeBps, uint256 _userBps, uint256 _keeperBps) external {
        if (msg.sender != owner) revert NotOwner();
        if (_nodeBps + _userBps + _keeperBps != 10_000) revert BadSplit();

        if (_diff(_nodeBps, nodeShareBps) > MAX_BPS_CHANGE) revert ChangeTooLarge();
        if (_diff(_userBps, userShareBps) > MAX_BPS_CHANGE) revert ChangeTooLarge();
        if (_diff(_keeperBps, keeperShareBps) > MAX_BPS_CHANGE) revert ChangeTooLarge();

        nodeShareBps = _nodeBps;
        userShareBps = _userBps;
        keeperShareBps = _keeperBps;

        emit SplitUpdated(_nodeBps, _userBps, _keeperBps);
    }

    function setSinks(address _nodeStaking, address _userStaking) external {
        if (msg.sender != owner) revert NotOwner();
        if (_nodeStaking == address(0) || _userStaking == address(0)) revert ZeroAddress();
        nodeStaking = IRevenueSink(_nodeStaking);
        userStaking = IRevenueSink(_userStaking);
        emit SinksUpdated(_nodeStaking, _userStaking);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function _diff(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
