# Bug: GitlawbNodeStaking.depositRevenue() O(n) gas exhaustion DoS

**Severity**: HIGH — protocol becomes unusable once `~3000+` nodes register. Base block gas limit hit, all weekly distributions fail.

**Affected**: `src/GitlawbNodeStaking.sol`, function `depositRevenue(uint256)`

## Root cause

`depositRevenue()` executes THREE O(n) loops over `nodeIds` in the same call :

```solidity
function depositRevenue(uint256 amount) external {
    if (amount == 0) revert InvalidAmount();

    // Loop 1 : _refreshActiveStake() iterates ALL nodes
    _refreshActiveStake();                          // O(n)
    
    uint256 activeStake = totalActiveStake;
    if (activeStake == 0) revert NoActiveStake();
    bool ok = token.transferFrom(msg.sender, address(this), amount);
    if (!ok) revert TransferFailed();

    uint256 len = nodeIds.length;

    // Loop 2 : harvest every node
    for (uint256 i = 0; i < len; i++) {
        _harvest(nodeIds[i]);                       // O(n) × _harvest
    }

    accRewardPerShare += (amount * ACC_PRECISION) / activeStake;
    totalRewardsDistributed += amount;

    // Loop 3 : seal inactive nodes against the new acc
    for (uint256 i = 0; i < len; i++) {
        Node storage n = nodes[nodeIds[i]];
        if (n.stake > 0 && !_isActive(n)) {
            n.rewardDebt = (n.stake * accRewardPerShare) / ACC_PRECISION;
        }
    }
}
```

Each loop iteration : storage read + arithmetic + maybe storage write. Roughly 8-15k gas per node per loop. With 3 loops :

- n=100 nodes → ~3M gas (OK)
- n=500 nodes → ~15M gas (tight on Base)
- n=1000 nodes → ~30M+ gas (exceeds Base block limit, varies by load)
- n=3000+ nodes → guaranteed revert

Once n exceeds the block-gas-limit threshold, **every weekly FeeDistributor.distribute() call reverts** because `nodeStaking.depositRevenue(...)` is inside `distribute()` and one revert nukes the whole tx. The protocol becomes permanently broken without an upgrade.

## The doc comment already acknowledges this

```solidity
/// Walk the nodes array and rebuild totalActiveStake based on live heartbeats.
/// O(n) in total registered nodes — acceptable for weekly deposits with
/// reasonable operator counts (< ~1000). For larger sets we'd switch to an
/// epoch-based checkpoint system.
function _refreshActiveStake() internal {
```

The team has acknowledged the limit but shipped it anyway, planning a future fix. With the project targeting "500+ independent operators" by Phase 8 (per the roadmap), the cap is already in the planned operating range.

## Recommended fix

**Option A — Epoch checkpoints** (recommended) :

Track active stake per epoch (week). Snapshot once per epoch. Reward accrual reads the active stake at deposit-epoch, not refreshed at deposit time.

**Option B — Pull-based accounting**:

Instead of looping over all nodes on every deposit, store `accRewardPerShareSnapshot[epoch]`. Each node calculates its earnings lazily on `claimRewards()` or `_harvest()`. No O(n) on deposit.

**Option C — Batched maintenance** (lowest disruption to current shape) :

Split `depositRevenue` into two calls :
- `depositRevenue(amount)` — transfer in + update `accRewardPerShare`. O(1).
- `processEpoch(uint256 from, uint256 to)` — anyone can call, processes a slice of nodes. Permissionless, anyone gets a small reward per processed node.

## Secondary DoS surface

`depositRevenue` is **permissionless** — any address with allowance can call. An attacker can spam tiny deposits (1 wei via transferFrom) to trigger the O(n) loops, burning gas for honest harvests. Adding a minimum amount filter (≥ 1 token, like the `MIN_DISTRIBUTION` already in `FeeDistributor`) helps.

## PoC

```solidity
function test_depositRevenue_dos_at_1000_nodes() public {
    // Register 1000 nodes (need 1000 wallets with 10k stake each = 10M GITLAWB locked)
    for (uint256 i = 0; i < 1000; i++) {
        address operator = makeAddr(string(abi.encodePacked("op", i)));
        deal(address(token), operator, 10_000 ether);
        vm.startPrank(operator);
        token.approve(address(nodeStaking), 10_000 ether);
        bytes32 nodeDid = keccak256(abi.encodePacked("did:gitlawb:", i));
        nodeStaking.registerNode(nodeDid, "https://x", 10_000 ether);
        vm.stopPrank();
    }
    
    // FeeDistributor tries to distribute 100 GITLAWB
    deal(address(token), feeDistributor, 100 ether);
    
    uint256 gasBefore = gasleft();
    vm.expectRevert(); // out of gas
    feeDistributor.distribute();
}
```

## Reporter

@philpof102-svg — operator wallet `0xAC3ca7c5d3cDD7702fd08F9C4C28dAA22296aDa9` (Base)
MainStreet : https://avisradar-production.up.railway.app/mainstreet.html
Related : PR [#5 (stranded rewards)](https://github.com/Gitlawb/contracts/pull/5), [#6 (claimBounty DoS)](https://github.com/Gitlawb/contracts/pull/6)
