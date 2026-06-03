# Bug: `unstake()` strands all rewards accrued during 7-day cooldown

**Severity**: MEDIUM — funds not stealable but legitimately-earned rewards are forfeited to the contract.

**Affected**: `src/GitlawbStaking.sol`

## Root cause

```solidity
function unstake() external {
    StakeInfo storage info = stakes[msg.sender];
    if (info.unstakeAmount == 0) revert NoPendingUnstake();
    if (block.timestamp < info.unstakeRequestAt + COOLDOWN_PERIOD) revert CooldownNotElapsed();

    uint256 amount = info.unstakeAmount;

    // Remove old weighted stake
    uint256 oldWeight = _weightedAmount(info.amount);
    totalWeightedStake -= oldWeight;

    info.amount -= amount;
    // ...
    info.rewardDebt = (newWeight * accRewardPerShare) / ACC_PRECISION;
    // ...
}
```

**No `_harvest(msg.sender)` call before decrementing the stake**. During the mandatory 7-day cooldown, `depositRevenue()` calls advance `accRewardPerShare`. The staker's `info.amount` is still active during cooldown, so they should accrue rewards. But on `unstake()`, the rewardDebt is RESET to the new accumulator value with the new (often zero) weight, and the pending delta is never written to `info.pendingRewards`.

## Repro

```solidity
// 1. Alice stakes 1000 GITLAWB (Observer tier)
staking.stake(1000);

// 2. Revenue deposited, Alice claims her share, rewardDebt updated
revenueSink.depositRevenue(1000 ether);
staking.claimRewards();

// 3. Alice requests full unstake (cooldown starts)
staking.requestUnstake(1000);

// 4. Revenue deposited DURING cooldown — Alice's 1000 stake still
//    contributes to totalWeightedStake, so she should earn here
revenueSink.depositRevenue(2000 ether);

// 5. 7 days later, Alice unstakes
vm.warp(block.timestamp + 7 days);
staking.unstake();

// 6. Alice claims — REVERTS with NoRewards because pendingRewards = 0
staking.claimRewards(); // ← Alice lost her share of the 2000 ether deposited during cooldown
```

## Fix

Add `_harvest(msg.sender);` as the first line of `unstake()`, mirroring the pattern in `stake()`, `requestUnstake()`, and `claimRewards()`.

```solidity
function unstake() external {
    StakeInfo storage info = stakes[msg.sender];
    if (info.unstakeAmount == 0) revert NoPendingUnstake();
    if (block.timestamp < info.unstakeRequestAt + COOLDOWN_PERIOD) revert CooldownNotElapsed();

+   // Harvest pending rewards before changing stake (consistent with stake/requestUnstake/claimRewards)
+   _harvest(msg.sender);

    uint256 amount = info.unstakeAmount;
    // ... rest unchanged ...
}
```

## Note on the audit "fixed" claim

The 2026-04-20 internal review marked a "stranded-rewards bug in `_harvest` else-branch" as fixed. This is a related but DIFFERENT bug — the `_harvest` early-return on `info.amount == 0` is benign (math holds because weight = 0 → accumulated = 0). The real stranded-rewards path is `unstake()` skipping `_harvest`.

## Reporter

@philpof102-svg — operator wallet `0xAC3ca7c5d3cDD7702fd08F9C4C28dAA22296aDa9` (Base)
MainStreet project: https://avisradar-production.up.railway.app/mainstreet.html
