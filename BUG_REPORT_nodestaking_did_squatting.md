# Bug: GitlawbNodeStaking — DID squatting via `registerNode` + unbounded `nodeIds` growth

**Severity**: HIGH (combined : identity squat + amplifies the O(n) DoS from PR #7)

**Affected**: `src/GitlawbNodeStaking.sol`

## Issue 1 — `registerNode` accepts any bytes32 hash without proving DID control

```solidity
function registerNode(
    bytes32 nodeDidHash,    // ← any hash, no proof
    string calldata httpUrl,
    uint256 stakeAmount
) external {
    if (stakeAmount < MIN_STAKE) revert BelowMinimumStake();
    Node storage n = nodes[nodeDidHash];
    if (n.operator != address(0)) revert AlreadyRegistered();
    ...
    n.operator = msg.sender;
    ...
}
```

No verification that `msg.sender` controls the DID corresponding to `nodeDidHash`. Attacker scenarios :

1. **DID squatting** : Mallory computes `keccak256("did:gitlawb:alice-foundation")` and registers a node with that hash, gaining the on-chain operator-of-record for Alice's intended DID. Alice now CANNOT register because `AlreadyRegistered` reverts.

2. **Reputation theft** : Once protocol revenue starts flowing, Mallory accrues rewards under Alice's brand. Resolvers showing the DID get Mallory's httpUrl.

3. **Coordinated grief** : 100 random hashes can be registered at MIN_STAKE × 100 = 1 000 000 $GITLAWB locked. With $GITLAWB at $0.00009 that's ~$90 total cost to permanently squat 100 future DIDs.

The DIDRegistry contract documents this as "first-come-first-served" by design, but NodeStaking inherits the same property without acknowledgement. Result : any non-Gitlawb-native DID (`did:web:`, `did:key:`) can be claimed at low cost by any address.

## Issue 2 — `nodeIds` array never shrinks

```solidity
function registerNode(...) {
    ...
    nodeIds.push(nodeDidHash);  // ← grows monotonically
    ...
}

function unstake(...) {
    ...
    n.stake = 0;
    n.active = false;
    // nodeIds entry NOT removed
}
```

`unstake` zeros out the Node struct but never removes the entry from `nodeIds`. The array grows forever. Combined with PR #7's three O(n) loops in `depositRevenue`, the protocol bricks even when the ACTIVE node count is low — because the iteration runs over EVERY historically-registered node, including ones that exited years ago.

After 5 years of node churn with ~200 average registrations / month, `nodeIds` has 12 000 entries — even though only ~500 are active. Each `depositRevenue` now iterates 12 000 + 12 000 + 12 000 = 36 000 storage reads. Guaranteed gas-out.

## Issue 3 — Slashing documented but not implemented

The README and roadmap state :

> "Misbehavior triggers slashing penalties ranging from 10–100% of staked amounts."

But there is NO slash function in `GitlawbNodeStaking.sol`. Only `transferOwnership` admin path. Misbehaving operators cannot be punished — only the operator themselves can `requestUnstake` to leave.

This is a documented-vs-implemented gap. Listing it here so it's tracked in the same conversation, not as a fix request — it's a scope item.

## Suggested fixes

**For Issue 1** : require a signature from the DID's controller key (Ed25519 verifier for `did:key:`, GitlawbDIDRegistry lookup for `did:gitlawb:`).

```solidity
function registerNode(
    bytes32 nodeDidHash,
    bytes calldata didControllerSignature,  // ← new
    string calldata httpUrl,
    uint256 stakeAmount
) external {
    require(
        didRegistry.verifyControllerSignature(
            nodeDidHash, msg.sender, didControllerSignature
        ),
        "DID controller mismatch"
    );
    ...
}
```

**For Issue 2** : track an `activeNodeIds` view that filters by `n.stake > 0`. Cheaper : on `unstake`, swap-and-pop the deregistered entry out of `nodeIds`.

```solidity
function unstake(bytes32 nodeDidHash) external {
    ...
    // swap-and-pop
    uint256 idx = nodeIdsIndex[nodeDidHash];
    uint256 last = nodeIds.length - 1;
    if (idx != last) {
        nodeIds[idx] = nodeIds[last];
        nodeIdsIndex[nodeIds[idx]] = idx;
    }
    nodeIds.pop();
    delete nodeIdsIndex[nodeDidHash];
    ...
}
```

**For Issue 3** : implement `slash(bytes32 nodeDidHash, uint256 bps)` callable by a designated slasher role + governance-controlled.

## Reporter

@philpof102-svg — operator `0xAC3ca7c5d3cDD7702fd08F9C4C28dAA22296aDa9` (Base)
Related : [#5](https://github.com/Gitlawb/contracts/pull/5), [#6](https://github.com/Gitlawb/contracts/pull/6), [#7](https://github.com/Gitlawb/contracts/pull/7), [#8](https://github.com/Gitlawb/contracts/pull/8)

This is the 5th finding in a continuous audit of all 6 Gitlawb contracts. Helping you ship Phase 8 mainnet safe.
