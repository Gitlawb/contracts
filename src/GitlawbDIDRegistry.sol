// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GitlawbDIDRegistry
/// @notice On-chain DID registry for gitlawb identities on Base L2.
///
/// Each DID (e.g. `did:key:z6Mk...`) is registered by an Ethereum address.
/// The owner can update the DID document (public key JSON-LD) or transfer
/// ownership to another address.
///
/// DID resolution:
///   1. Look up didToOwner[keccak256(did)] — confirms the DID is registered.
///   2. Read didDocuments[keccak256(did)] — returns the DID document JSON.
contract GitlawbDIDRegistry {
    // ── Storage ──────────────────────────────────────────────────────────────

    /// Maps keccak256(did) → Ethereum owner address
    mapping(bytes32 => address) public didToOwner;

    /// Maps keccak256(did) → DID document (JSON string)
    mapping(bytes32 => string) public didDocuments;

    /// Maps keccak256(did) → raw DID string (for enumeration)
    mapping(bytes32 => string) public didStrings;

    // ── Events ────────────────────────────────────────────────────────────────

    event DIDRegistered(bytes32 indexed didHash, address indexed owner, string did, string document);
    event DIDUpdated(bytes32 indexed didHash, address indexed owner, string document);
    event DIDTransferred(bytes32 indexed didHash, address indexed previousOwner, address indexed newOwner);

    // ── Errors ────────────────────────────────────────────────────────────────

    error AlreadyRegistered(bytes32 didHash);
    error NotOwner(bytes32 didHash, address caller);
    error NotRegistered(bytes32 didHash);
    error EmptyDID();

    // ── Functions ─────────────────────────────────────────────────────────────

    /// Register a new DID. Reverts if already registered.
    /// @param did     Full DID string, e.g. "did:key:z6Mk..."
    /// @param document DID document JSON (JSON-LD, compact representation)
    function register(string calldata did, string calldata document) external {
        if (bytes(did).length == 0) revert EmptyDID();
        bytes32 didHash = keccak256(bytes(did));
        if (didToOwner[didHash] != address(0)) revert AlreadyRegistered(didHash);

        didToOwner[didHash] = msg.sender;
        didDocuments[didHash] = document;
        didStrings[didHash] = did;

        emit DIDRegistered(didHash, msg.sender, did, document);
    }

    /// Update the DID document. Only the current owner can call this.
    function update(string calldata did, string calldata document) external {
        bytes32 didHash = keccak256(bytes(did));
        if (didToOwner[didHash] == address(0)) revert NotRegistered(didHash);
        if (didToOwner[didHash] != msg.sender) revert NotOwner(didHash, msg.sender);

        didDocuments[didHash] = document;
        emit DIDUpdated(didHash, msg.sender, document);
    }

    /// Transfer DID ownership to a new Ethereum address.
    function transfer(string calldata did, address newOwner) external {
        bytes32 didHash = keccak256(bytes(did));
        if (didToOwner[didHash] == address(0)) revert NotRegistered(didHash);
        if (didToOwner[didHash] != msg.sender) revert NotOwner(didHash, msg.sender);

        address prev = didToOwner[didHash];
        didToOwner[didHash] = newOwner;
        emit DIDTransferred(didHash, prev, newOwner);
    }

    /// Resolve a DID — returns the owner address and document.
    /// Returns (address(0), "") if not registered.
    function resolve(string calldata did)
        external
        view
        returns (address owner, string memory document)
    {
        bytes32 didHash = keccak256(bytes(did));
        owner = didToOwner[didHash];
        document = didDocuments[didHash];
    }

    /// Check whether a DID is registered.
    function isRegistered(string calldata did) external view returns (bool) {
        return didToOwner[keccak256(bytes(did))] != address(0);
    }
}
