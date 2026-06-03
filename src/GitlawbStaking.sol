// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

/// @title GitlawbStaking
/// @notice Stake $GITLAWB to earn protocol fee revenue share on Base L2.
///
/// Four tiers with multiplied rewards:
///   Observer   (1,000+)       → 1x
///   Curator    (10,000+)      → 2x
///   Steward    (100,000+)     → 4x
///   Validator  (1,000,000+)   → 8x
///
/// Revenue is deposited by the treasury (from bounty fees, etc.)
/// and distributed pro-rata to stakers weighted by tier multiplier.
/// 7-day cooldown on unstaking to prevent reward sniping.
contract GitlawbStaking {
    // ── Types ────────────────────────────────────────────────────────────────

    enum Tier { None, Observer, Curator, Steward, Validator }

    struct StakeInfo {
        uint256 amount;
        uint256 rewardDebt;        // accumulated reward offset (for pro-rata calc)
        uint256 pendingRewards;    // unclaimed rewards
        uint256 unstakeRequestAt;  // timestamp of unstake request (0 = none)
        uint256 unstakeAmount;     // amount requested to unstake
    }

    // ── Constants ────────────────────────────────────────────────────────────

    uint256 public constant OBSERVER_THRESHOLD  = 1_000 * 1e18;
    uint256 public constant CURATOR_THRESHOLD   = 10_000 * 1e18;
    uint256 public constant STEWARD_THRESHOLD   = 100_000 * 1e18;
    uint256 public constant VALIDATOR_THRESHOLD = 1_000_000 * 1e18;

    uint256 public constant COOLDOWN_PERIOD = 7 days;

    // Precision for reward-per-share calculations
    uint256 private constant ACC_PRECISION = 1e18;

    // ── Storage ──────────────────────────────────────────────────────────────

    IERC20 public immutable token;
    address public owner;

    mapping(address => StakeInfo) public stakes;

    uint256 public totalWeightedStake;      // sum of (amount * multiplier) across all stakers
    uint256 public accRewardPerShare;       // accumulated rewards per weighted share
    uint256 public totalStaked;             // total raw tokens staked
    uint256 public totalRewardsDistributed; // lifetime rewards deposited

    // ── Events ───────────────────────────────────────────────────────────────

    event Staked(address indexed staker, uint256 amount, Tier tier);
    event UnstakeRequested(address indexed staker, uint256 amount, uint256 availableAt);
    event Unstaked(address indexed staker, uint256 amount);
    event RewardsClaimed(address indexed staker, uint256 amount);
    event RevenueDeposited(address indexed depositor, uint256 amount);

    // ── Errors ───────────────────────────────────────────────────────────────

    error NotOwner();
    error InvalidAmount();
    error InsufficientStake();
    error CooldownNotElapsed();
    error NoPendingUnstake();
    error NoRewards();
    error TransferFailed();
    error ZeroAddress();
    error BelowMinimumStake();

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address _token) {
        token = IERC20(_token);
        owner = msg.sender;
    }

    // ── Core functions ───────────────────────────────────────────────────────

    /// Stake $GITLAWB tokens. Must have approved this contract first.
    function stake(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();

        StakeInfo storage info = stakes[msg.sender];

        // Harvest pending rewards before changing stake
        _harvest(msg.sender);

        bool ok = token.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        // Remove old weighted stake
        uint256 oldWeight = _weightedAmount(info.amount);
        totalWeightedStake -= oldWeight;

        info.amount += amount;
        totalStaked += amount;

        // Must meet minimum tier threshold
        if (info.amount < OBSERVER_THRESHOLD) revert BelowMinimumStake();

        // Add new weighted stake
        uint256 newWeight = _weightedAmount(info.amount);
        totalWeightedStake += newWeight;

        // Reset reward debt to current accumulated value
        info.rewardDebt = (newWeight * accRewardPerShare) / ACC_PRECISION;

        emit Staked(msg.sender, amount, getTier(msg.sender));
    }

    /// Request unstake — starts 7-day cooldown.
    function requestUnstake(uint256 amount) external {
        StakeInfo storage info = stakes[msg.sender];
        if (amount == 0) revert InvalidAmount();
        if (amount > info.amount) revert InsufficientStake();

        // Harvest pending rewards first
        _harvest(msg.sender);

        info.unstakeRequestAt = block.timestamp;
        info.unstakeAmount = amount;

        emit UnstakeRequested(msg.sender, amount, block.timestamp + COOLDOWN_PERIOD);
    }

    /// Complete unstake after cooldown has elapsed.
    function unstake() external {
        StakeInfo storage info = stakes[msg.sender];
        if (info.unstakeAmount == 0) revert NoPendingUnstake();
        if (block.timestamp < info.unstakeRequestAt + COOLDOWN_PERIOD) revert CooldownNotElapsed();

        // Harvest pending rewards before changing stake (mirrors stake/requestUnstake/claimRewards)
        _harvest(msg.sender);

        uint256 amount = info.unstakeAmount;

        // Remove old weighted stake
        uint256 oldWeight = _weightedAmount(info.amount);
        totalWeightedStake -= oldWeight;

        info.amount -= amount;
        totalStaked -= amount;

        // Add new weighted stake (may be 0)
        uint256 newWeight = _weightedAmount(info.amount);
        totalWeightedStake += newWeight;

        // Reset reward debt
        info.rewardDebt = (newWeight * accRewardPerShare) / ACC_PRECISION;

        // Clear unstake request
        info.unstakeAmount = 0;
        info.unstakeRequestAt = 0;

        // PR #5 fix : auto-pay pendingRewards along with the unstake so a user
        // who fully exits doesn't leave rewards stranded in storage. Mirrors
        // GitlawbNodeStaking.unstake() which pays stake + rewards in one tx.
        // Without this, full-exit stakers who forget to call claimRewards lose
        // access in practice (stake = 0 but pendingRewards > 0 sitting forever).
        uint256 rewards = info.pendingRewards;
        info.pendingRewards = 0;

        uint256 payout = amount + rewards;
        bool ok = token.transfer(msg.sender, payout);
        if (!ok) revert TransferFailed();

        emit Unstaked(msg.sender, amount);
        if (rewards > 0) emit RewardsClaimed(msg.sender, rewards);
    }

    /// Claim accumulated rewards.
    function claimRewards() external {
        _harvest(msg.sender);

        StakeInfo storage info = stakes[msg.sender];
        uint256 rewards = info.pendingRewards;
        if (rewards == 0) revert NoRewards();

        info.pendingRewards = 0;

        bool ok = token.transfer(msg.sender, rewards);
        if (!ok) revert TransferFailed();

        emit RewardsClaimed(msg.sender, rewards);
    }

    /// Deposit revenue (protocol fees) for distribution to stakers.
    /// Called by treasury/bounty contract when fees are collected.
    function depositRevenue(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        if (totalWeightedStake == 0) revert InvalidAmount(); // no stakers

        bool ok = token.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        accRewardPerShare += (amount * ACC_PRECISION) / totalWeightedStake;
        totalRewardsDistributed += amount;

        emit RevenueDeposited(msg.sender, amount);
    }

    // ── View functions ───────────────────────────────────────────────────────

    /// Get the staking tier for an address.
    function getTier(address staker) public view returns (Tier) {
        uint256 amount = stakes[staker].amount;
        if (amount >= VALIDATOR_THRESHOLD) return Tier.Validator;
        if (amount >= STEWARD_THRESHOLD) return Tier.Steward;
        if (amount >= CURATOR_THRESHOLD) return Tier.Curator;
        if (amount >= OBSERVER_THRESHOLD) return Tier.Observer;
        return Tier.None;
    }

    /// Get tier multiplier (1x, 2x, 4x, 8x).
    function getTierMultiplier(Tier tier) public pure returns (uint256) {
        if (tier == Tier.Validator) return 8;
        if (tier == Tier.Steward) return 4;
        if (tier == Tier.Curator) return 2;
        if (tier == Tier.Observer) return 1;
        return 0;
    }

    /// Pending (unclaimed) rewards for a staker.
    function pendingRewards(address staker) external view returns (uint256) {
        StakeInfo storage info = stakes[staker];
        uint256 weight = _weightedAmount(info.amount);
        uint256 accumulated = (weight * accRewardPerShare) / ACC_PRECISION;
        return info.pendingRewards + accumulated - info.rewardDebt;
    }

    /// Full staker info.
    function getStakeInfo(address staker) external view returns (
        uint256 amount,
        Tier tier,
        uint256 multiplier,
        uint256 _pendingRewards,
        uint256 unstakeRequestAt,
        uint256 unstakeAmount
    ) {
        StakeInfo storage info = stakes[staker];
        Tier t = getTier(staker);
        uint256 weight = _weightedAmount(info.amount);
        uint256 accumulated = (weight * accRewardPerShare) / ACC_PRECISION;
        uint256 pending = info.pendingRewards + accumulated - info.rewardDebt;
        return (info.amount, t, getTierMultiplier(t), pending, info.unstakeRequestAt, info.unstakeAmount);
    }

    /// Protocol-level stats.
    function getProtocolStats() external view returns (
        uint256 _totalStaked,
        uint256 _totalWeightedStake,
        uint256 _totalRewardsDistributed,
        uint256 _accRewardPerShare
    ) {
        return (totalStaked, totalWeightedStake, totalRewardsDistributed, accRewardPerShare);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _harvest(address staker) internal {
        StakeInfo storage info = stakes[staker];
        if (info.amount == 0) return;

        uint256 weight = _weightedAmount(info.amount);
        uint256 accumulated = (weight * accRewardPerShare) / ACC_PRECISION;
        uint256 pending = accumulated - info.rewardDebt;

        if (pending > 0) {
            info.pendingRewards += pending;
        }
        info.rewardDebt = accumulated;
    }

    function _weightedAmount(uint256 amount) internal pure returns (uint256) {
        if (amount >= VALIDATOR_THRESHOLD) return amount * 8;
        if (amount >= STEWARD_THRESHOLD) return amount * 4;
        if (amount >= CURATOR_THRESHOLD) return amount * 2;
        if (amount >= OBSERVER_THRESHOLD) return amount;
        return 0;
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}
