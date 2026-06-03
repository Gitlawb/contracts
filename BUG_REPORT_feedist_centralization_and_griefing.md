# Bug: GitlawbFeeDistributor — owner can rug keeperShare to 0; griefing surface on weekly distribute

**Severity**: MEDIUM (centralization) + LOW (griefing)

**Affected**: `src/GitlawbFeeDistributor.sol`

## Issue 1 — Owner can drop keeperShareBps to 0 in one tx

`setSplit` enforces `MAX_BPS_CHANGE = 500` per call but with no timelock. Current `keeperShareBps = 100`. From the constants :

```solidity
uint256 public constant MAX_BPS_CHANGE = 500; // owner can shift at most 5% per update
```

Diff calculation `_diff(100, 0) = 100 ≤ 500`. Owner can call `setSplit(7600, 2400, 0)` in a single tx with no notice :
- nodeBps : 7500 → 7600 (diff 100 ≤ 500) ✓
- userBps : 2400 → 2400 (diff 0) ✓
- keeperBps : 100 → 0 (diff 100 ≤ 500) ✓
- sum = 10000 ✓

Keepers who built infrastructure expecting 1% caller reward suddenly get 0. Worse, the owner can front-run an inflight `distribute()` in the mempool with the rug-`setSplit` tx (higher gas) so the caller pays gas for 0 reward.

## Issue 2 — `distribute()` reverts on sink failure → griefing

```solidity
nodeStaking.depositRevenue(nodeShare);   // ← if reverts, whole distribute() reverts
userStaking.depositRevenue(userShare);   // ← same
```

If either sink reverts (paused, gas exhaust, or PR #7's O(n) DoS), the entire weekly distribution is bricked. Keepers lose gas trying. The fee pool grows uncollected until owner intervenes.

Combined with PR #7's O(n) DoS in `GitlawbNodeStaking.depositRevenue`, this is a guaranteed lockup once the node count crosses the gas-limit threshold.

## Issue 3 — `setSinks` has no timelock

```solidity
function setSinks(address _nodeStaking, address _userStaking) external {
    if (msg.sender != owner) revert NotOwner();
    ...
    nodeStaking = IRevenueSink(_nodeStaking);
    userStaking = IRevenueSink(_userStaking);
}
```

Owner can redirect 99% of the protocol's revenue to a wallet they control by setting both sinks to an attacker contract. No timelock, no governance, no event the community can react to before the next distribute() fires.

The doc claims protocol is "permissionless weekly distribution" but the owner can drain the next distribution into their own pocket.

## Issue 4 — `lastDistribution = block.timestamp` set BEFORE balance check

```solidity
function distribute() external {
    uint256 next = lastDistribution + DISTRIBUTION_PERIOD;
    if (block.timestamp < next) revert TooSoon(next);

    uint256 bal = token.balanceOf(address(this));
    if (bal < MIN_DISTRIBUTION) revert NothingToDistribute();

    lastDistribution = block.timestamp;  // ← set after bal check, OK
    ...
}
```

Actually checked — `lastDistribution` is set AFTER the `NothingToDistribute` check. Safe. (Including this so audit log shows it was reviewed.)

## Suggested fixes

**Issue 1+3 — timelock on admin functions** :

```solidity
mapping(bytes32 => uint256) public pendingChange;
uint256 public constant TIMELOCK = 7 days;

function proposeSplit(uint256 _nodeBps, uint256 _userBps, uint256 _keeperBps) external {
    if (msg.sender != owner) revert NotOwner();
    bytes32 h = keccak256(abi.encode(_nodeBps, _userBps, _keeperBps));
    pendingChange[h] = block.timestamp + TIMELOCK;
    emit ChangeProposed(h, _nodeBps, _userBps, _keeperBps);
}

function applySplit(uint256 _nodeBps, uint256 _userBps, uint256 _keeperBps) external {
    bytes32 h = keccak256(abi.encode(_nodeBps, _userBps, _keeperBps));
    require(pendingChange[h] != 0 && block.timestamp >= pendingChange[h], "not ready");
    delete pendingChange[h];
    // existing setSplit logic
}
```

Same pattern for `setSinks`. 7-day timelock gives stakers and keepers time to exit if they disagree.

**Issue 2 — graceful sink failure** :

```solidity
try nodeStaking.depositRevenue(nodeShare) {
    // ok
} catch {
    emit SinkFailed("node");
    // accumulate for next epoch instead of bricking
    nodeShareCarryover += nodeShare;
}
```

## Reporter

@philpof102-svg — operator `0xAC3ca7c5d3cDD7702fd08F9C4C28dAA22296aDa9` (Base)
6th PR in the continuous Gitlawb audit. Related : #5, #6, #7, #8, #9.
