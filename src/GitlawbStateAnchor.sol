// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGitlawbDIDRegistry {
    function didToOwner(bytes32 didHash) external view returns (address);
}

/// @title GitlawbStateAnchor
/// @notice Bridge between Gitlawb DIDs and GM-NET verifiable state roots.
/// @dev Powered by @bankr
contract GitlawbStateAnchor {
    IGitlawbDIDRegistry public immutable registry;
    
    /// Maps keccak256(did) => latest anchored state root
    mapping(bytes32 => bytes32) public latestStateRoot;
    
    event RepoStateAnchored(bytes32 indexed didHash, bytes32 indexed stateRoot, address indexed anchorer);

    error NotDIDOwner(bytes32 didHash, address caller);

    constructor(address _registry) {
        registry = IGitlawbDIDRegistry(_registry);
    }

    /// @notice Anchor a new state root for a Gitlawb DID.
    /// @param did Full DID string (e.g. "did:key:z6Mk...")
    /// @param stateRoot The bytes32 root from GM-NET
    function anchorRepoState(string calldata did, bytes32 stateRoot) external {
        bytes32 didHash = keccak256(bytes(did));
        address owner = registry.didToOwner(didHash);
        
        if (owner != msg.sender) revert NotDIDOwner(didHash, msg.sender);
        
        latestStateRoot[didHash] = stateRoot;
        emit RepoStateAnchored(didHash, stateRoot, msg.sender);
    }
}
