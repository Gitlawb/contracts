function transfer(string calldata did, address newOwner) external {
+    if (newOwner == address(0)) revert ZeroAddress();
    bytes32 didHash = keccak256(bytes(did));
    if (didToOwner[didHash] == address(0)) revert NotRegistered(didHash);
    if (didToOwner[didHash] != msg.sender) revert NotOwner(didHash, msg.sender);
    didToOwner[didHash] = newOwner;   
    // ...
}