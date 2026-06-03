# Bug: GitlawbStaking — `requestUnstake` silently overwrites a pending request, restarting the 7-day cooldown

**Severity**: MEDIUM (poor UX + phishing surface, not direct fund loss)

**Affected**: `src/GitlawbStaking.sol`, `requestUnstake(uint256)`

## Root cause

`requestUnstake` allows itself to be called while a previous request is still pending. The new call **silently overwrites** both fields :

```solidity
function requestUnstake(uint256 amount) external {
    StakeInfo storage info = stakes[msg.sender];
    if (amount == 0) revert InvalidAmount();
    if (amount > info.amount) revert InsufficientStake();

    _harvest(msg.sender);

    info.unstakeRequestAt = block.timestamp;  // ← restarts cooldown clock
    info.unstakeAmount = amount;              // ← overwrites previous request
    emit UnstakeRequested(...);
}
```

No check for `info.unstakeAmount != 0` (which would mean a request is pending). Note this contrasts with `GitlawbNodeStaking.requestUnstake` which explicitly reverts with `UnstakePending` in the same situation :

```solidity
// GitlawbNodeStaking.requestUnstake
if (n.unstakeRequestAt != 0) revert UnstakePending();
```

The Staking contract is missing the same guard.

## Attack scenarios

### Scenario A — Phishing / UI bug

1. Alice has 1M $GITLAWB staked (Validator tier).
2. Alice calls `requestUnstake(1_000_000)` at day 0. Cooldown : day 7.
3. On day 6.9, a phishing UI or buggy frontend persuades Alice to "confirm" her unstake by signing `requestUnstake(1)`.
4. The contract silently RESETS : `unstakeRequestAt = block.timestamp` (day 6.9), `unstakeAmount = 1`.
5. Alice's intent to withdraw 1M is lost. Her cooldown restarts from scratch. She withdraws 1 token instead of 1M.

If Alice doesn't notice (no front-end warning), she's locked for another 7 days minimum. Worse, an attacker watching the mempool could submit `requestUnstake(1)` calls during this window on behalf of victims via signature replay or UI exploit.

### Scenario B — Operator self-grief

Alice operates a node-runner business. Her workflow calls `requestUnstake` whenever the operator-of-record key signs. A bug in the workflow re-triggers the call mid-cooldown → her treasury is locked an additional 7 days every accidental call.

### Scenario C — Combined with PR #5

PR #5 already documents that `unstake()` strands rewards accrued during cooldown. Combined with this overwrite : Alice could lose **two cooldowns of rewards** by an inadvertent second `requestUnstake` call. The compounding makes both findings more impactful when fixed together.

## Suggested fix

Add the same guard as `GitlawbNodeStaking.requestUnstake` :

```solidity
function requestUnstake(uint256 amount) external {
    StakeInfo storage info = stakes[msg.sender];
    if (amount == 0) revert InvalidAmount();
+   if (info.unstakeAmount != 0) revert UnstakePending();
    if (amount > info.amount) revert InsufficientStake();
    ...
}
```

To allow users to cancel and re-request, add an explicit `cancelUnstakeRequest()` function rather than silent overwrite :

```solidity
function cancelUnstakeRequest() external {
    StakeInfo storage info = stakes[msg.sender];
    if (info.unstakeAmount == 0) revert NoPendingUnstake();
    info.unstakeAmount = 0;
    info.unstakeRequestAt = 0;
    emit UnstakeCancelled(msg.sender);
}
```

This makes the user's intent explicit and ensures the cooldown reset is not silent.

## Consistency with NodeStaking

`GitlawbNodeStaking.requestUnstake` already implements the correct behavior :

```solidity
if (n.unstakeRequestAt != 0) revert UnstakePending();
```

The Staking contract just needs the same line. Same defensive pattern, same error type.

## Reporter

@philpof102-svg — operator `0xAC3ca7c5d3cDD7702fd08F9C4C28dAA22296aDa9` (Base)
8th PR in continuous Gitlawb audit. Related : #5, #6, #7, #8, #9, #10, #11.
