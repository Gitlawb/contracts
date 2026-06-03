# Bug: GitlawbBounty — retroactive fee bump rugpulls existing escrowed bounties

**Severity**: MEDIUM-HIGH (theft surface for owner against escrowed funds)

**Affected**: `src/GitlawbBounty.sol`, `setProtocolFee` + `approveBounty`

## Root cause

`setProtocolFee` lets the owner update `protocolFeeBps` up to 1000 bps (10%). When `approveBounty` runs, the fee is computed from the CURRENT `protocolFeeBps`, not the fee that was in effect when the bounty was created :

```solidity
function approveBounty(uint256 bountyId) external onlyBountyCreator(bountyId) inStatus(bountyId, Status.Submitted) {
    Bounty storage b = bounties[bountyId];

    uint256 fee = (b.amount * protocolFeeBps) / 10000;   // ← CURRENT bps, not at creation
    uint256 payout = b.amount - fee;
    ...
}
```

`Bounty` struct stores no `feeBpsAtCreation` field. So the owner can change the cut applied to bounties that were already escrowed.

## Attack scenarios

### Scenario A — Owner rugs the claimant share

1. Alice creates a high-value bounty (1 000 000 $GITLAWB escrowed at default 5% fee → claimant expects 950k).
2. Claimant works, submits PR, bounty enters `Status.Submitted`.
3. Owner front-runs Alice's `approveBounty` call with `setProtocolFee(1000)` (max 10%, single tx).
4. `approveBounty` executes — claimant gets 900k instead of 950k. **Owner siphons 50k extra** on a bounty they had no role in creating.

### Scenario B — Owner times the bump to maximize theft

Owner sees the largest pending Submitted bounty in the mempool. Bumps fee right before approval. Repeats across many bounties. Cumulative theft can be significant.

### Scenario C — Owner bumps fee before mass approvals

If the protocol ships a "batch approve" UX later, owner sees N bounties in queue, bumps fee, then a large batch processes at the higher fee. Single tx of owner privilege drains 5% extra across all pending bounties.

## Why this matters

The whole point of escrow is that the terms of the deal are fixed at the moment funds enter the contract. Both Alice (the bounty creator) and the agent (the claimant) priced their participation against 5%. The protocol's promise to them is broken if the owner can move that number mid-flight.

This is the same class of bug as variable-rate-without-notice in lending protocols. The fix is universally to snapshot the rate at the moment it locks against escrowed funds.

## Suggested fix

Add `feeBpsAtCreation` to the `Bounty` struct, snapshot in `createBounty`, read in `approveBounty` :

```solidity
struct Bounty {
    ...
    uint256 feeBpsAtCreation;   // ← snapshot
}

function createBounty(...) external returns (uint256 bountyId) {
    ...
    bounties[bountyId] = Bounty({
        ...
        feeBpsAtCreation: protocolFeeBps   // ← snapshot
    });
}

function approveBounty(uint256 bountyId) external ... {
    Bounty storage b = bounties[bountyId];
    uint256 fee = (b.amount * b.feeBpsAtCreation) / 10000;   // ← use snapshot
    uint256 payout = b.amount - fee;
    ...
}
```

## Secondary observation

`setProtocolFee` allows max 10% (`require(_feeBps <= 1000, "fee too high")`). For an established marketplace, a 10% cut is reasonable, but combined with the retroactive issue, the owner has unilateral 5%-of-escrow theft capacity at any moment.

A timelock + per-call ceiling (e.g. ±100 bps per change) would also protect against this without removing flexibility entirely.

## Reporter

@philpof102-svg — operator `0xAC3ca7c5d3cDD7702fd08F9C4C28dAA22296aDa9` (Base)
7th PR in continuous Gitlawb audit. Related : #5, #6, #7, #8, #9, #10.
