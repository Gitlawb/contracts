# Bug: `claimBounty()` allows permissionless DoS of every open bounty

**Severity**: HIGH — denial-of-service attack with zero cost.

**Affected**: `src/GitlawbBounty.sol`, function `claimBounty(uint256, string)`

## Root cause

```solidity
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
```

No verification that :
1. `agentDid` belongs to the caller (DID Registry binding check missing)
2. The caller has any reputation / stake / eligibility
3. The caller is even an agent (could be a random EOA)

Any address can claim any open bounty for free.

## Attack: indefinite DoS griefing

1. Alice creates bounty (locks 1000 $GITLAWB)
2. Mallory calls `claimBounty(bountyId, "fake-did")` — succeeds with no checks
3. Mallory does nothing
4. Anyone calls `disputeBounty()` after deadline → bounty reopens
5. Mallory immediately calls `claimBounty()` again
6. Repeat indefinitely

Alice's 1000 $GITLAWB is locked forever in the contract. The only escape is `cancelBounty()` which refunds — but only works on `Status.Open`, so Alice must race Mallory to cancel between dispute and claim. Mallory can also send the cancel tx with higher gas to override.

## Secondary issue: agentDid spoofing for reputation manipulation

`agentDid` is a raw `string calldata`. On completion :

```solidity
bytes32 didHash = keccak256(bytes(b.claimantDid));
agentEarnings[didHash] += payout;
agentCompletedCount[didHash] += 1;
```

Earnings are credited to a DID hash that has NO relationship to the caller. Attacker can credit earnings to victim's DID OR steal credit for victim's work by colliding the DID string.

## Suggested fix

```solidity
import { IGitlawbDIDRegistry } from "./interfaces/IGitlawbDIDRegistry.sol";

IGitlawbDIDRegistry public immutable didRegistry;

function claimBounty(
    uint256 bountyId,
    string calldata agentDid
) external inStatus(bountyId, Status.Open) {
    // Caller must control the DID (cryptographic binding via DID Registry)
    require(
        didRegistry.controllerOf(keccak256(bytes(agentDid))) == msg.sender,
        "DID not owned by caller"
    );
    // (Optional) Require minimum stake or completed-count for anti-spam
    // require(stakingV.getTier(msg.sender) >= Tier.LightNode, "below min tier");
    Bounty storage b = bounties[bountyId];
    b.claimantDid = agentDid;
    b.claimantAddress = msg.sender;
    b.claimedAt = block.timestamp;
    b.status = Status.Claimed;
    emit BountyClaimed(bountyId, agentDid, msg.sender);
}
```

Or simpler if DID registry binding is not yet wired :

```solidity
require(
    keccak256(abi.encodePacked(agentDid, msg.sender)) == /* expected commit */,
    "agentDid commitment mismatch"
);
```

Or simplest : require a small claim deposit (e.g. 100 $GITLAWB) refunded on `submitBounty` and slashed on dispute. Makes DoS economically infeasible.

## Reporter

@philpof102-svg — operator wallet `0xAC3ca7c5d3cDD7702fd08F9C4C28dAA22296aDa9` (Base)
MainStreet: https://avisradar-production.up.railway.app/mainstreet.html
