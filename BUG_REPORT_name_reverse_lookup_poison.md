# Bug: GitlawbNameRegistry — reverse-lookup poisoning via unchecked `register`

**Severity**: MEDIUM — identity-confusion / phishing surface, not direct loss of funds.

**Affected**: `src/GitlawbNameRegistry.sol`, functions `register(string, string)` and `update(string, string)`

## Root cause

`register()` writes the `didToName` reverse mapping without checking whether the DID is already mapped to another name :

```solidity
function register(string calldata name, string calldata did) external {
    _validateName(name);
    bytes32 nameHash = keccak256(bytes(name));
    if (_records[nameHash].owner != address(0)) revert NameTaken(nameHash);

    _records[nameHash] = NameRecord({...});

    // Reverse mapping — silently overwrites
    bytes32 didHash = keccak256(bytes(did));
    didToName[didHash] = name;                          // ← no check
    
    emit NameRegistered(name, did, msg.sender, block.timestamp);
}
```

`update()` has the same issue : it deletes the OLD didToName entry but blindly overwrites if the NEW DID is already mapped to another name.

## Attack: identity confusion / phishing

1. Alice registers `name="alice"`, `did="did:key:z6MkAliceKey..."`
2. `didToName[keccak256(did:key:z6MkAliceKey...)]` = "alice" ✓
3. Bob, attacker, registers `name="alice-prime"` with `did="did:key:z6MkAliceKey..."` (Alice's DID)
4. Contract accepts — no check on reverse mapping
5. `didToName[keccak256(did:key:z6MkAliceKey...)]` = "alice-prime" — Alice's reverse lookup is silently broken

Any frontend/backend doing `reverseLookup(aliceDID)` returns Bob's chosen name. If Bob registers a phishing-flavored name (`alice-verified`, `alice-official`), apps display the wrong name when looking up Alice's DID.

The FORWARD mapping `name → did` is fine for Alice (she still owns "alice"). But the REVERSE direction is poisoned.

## Why this matters for Gitlawb

The reverse mapping is **the canonical way** to display a name for a known DID. Gitlawb-skill agents will commonly call `reverseLookup(agentDid)` to know what to display when showing other agents in the UI. A poisoned mapping shows the attacker-chosen name → social engineering.

## PoC

```solidity
function test_reverse_lookup_poisoning() public {
    string memory aliceDid = "did:key:z6MkAlice...";

    // Alice registers cleanly
    vm.prank(alice);
    nameRegistry.register("alice", aliceDid);
    assertEq(nameRegistry.reverseLookup(aliceDid), "alice");

    // Bob registers a different NAME but with Alice's DID
    vm.prank(bob);
    nameRegistry.register("alice-prime", aliceDid);

    // Alice's reverse mapping is now poisoned
    assertEq(nameRegistry.reverseLookup(aliceDid), "alice-prime"); // ← attacker wins
}
```

## Suggested fix

Add a check : the DID must not already have a reverse mapping when registering a new name, OR explicitly allow multiple names per DID (track as array).

```solidity
function register(string calldata name, string calldata did) external {
    _validateName(name);
    bytes32 nameHash = keccak256(bytes(name));
    if (_records[nameHash].owner != address(0)) revert NameTaken(nameHash);

    bytes32 didHash = keccak256(bytes(did));
+   // Forbid DID-squatting on the reverse mapping
+   if (bytes(didToName[didHash]).length != 0) revert DidAlreadyHasName(didHash);

    _records[nameHash] = NameRecord({...});
    didToName[didHash] = name;
    emit NameRegistered(name, did, msg.sender, block.timestamp);
}
```

Same in `update()` :

```solidity
function update(string calldata name, string calldata newDid) external {
    ...
    bytes32 newDidHash = keccak256(bytes(newDid));
+   if (bytes(didToName[newDidHash]).length != 0) revert DidAlreadyHasName(newDidHash);
    didToName[newDidHash] = name;
    ...
}
```

## Secondary issues

- `transfer()` doesn't validate `newOwner != address(0)` — accidental wipe possible
- `transfer()` doesn't update `updatedAt` consistently with `update()`

## Reporter

@philpof102-svg — operator `0xAC3ca7c5d3cDD7702fd08F9C4C28dAA22296aDa9` (Base)
MainStreet : https://avisradar-production.up.railway.app/mainstreet.html
Related : [#5 (stranded rewards)](https://github.com/Gitlawb/contracts/pull/5), [#6 (claimBounty DoS)](https://github.com/Gitlawb/contracts/pull/6), [#7 (NodeStaking O(n) DoS)](https://github.com/Gitlawb/contracts/pull/7)
