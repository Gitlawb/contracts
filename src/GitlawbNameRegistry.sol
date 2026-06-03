// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GitlawbNameRegistry
/// @notice Human-readable name → DID mapping on Base L2.
///
/// Names are lowercase ASCII strings (e.g. "alice", "acme-corp").
/// Each name maps to exactly one DID. The owner (Ethereum address) can
/// update the DID or transfer the name to another address.
///
/// This is gitlawb's answer to ENS: names are bound to cryptographic
/// identities, not just Ethereum addresses.
contract GitlawbNameRegistry {
    // ── Storage ──────────────────────────────────────────────────────────────

    struct NameRecord {
        address owner;
        string did;
        uint256 registeredAt;
        uint256 updatedAt;
    }

    /// Maps keccak256(name) → NameRecord
    mapping(bytes32 => NameRecord) private _records;

    /// Maps keccak256(did) → name (reverse lookup)
    mapping(bytes32 => string) public didToName;

    // ── Events ────────────────────────────────────────────────────────────────

    event NameRegistered(string indexed name, string did, address indexed owner, uint256 timestamp);
    event NameUpdated(string indexed name, string did, address indexed owner, uint256 timestamp);
    event NameTransferred(string indexed name, address indexed previousOwner, address indexed newOwner);

    // ── Errors ────────────────────────────────────────────────────────────────

    error NameTaken(bytes32 nameHash);
    error NotOwner(bytes32 nameHash, address caller);
    error NotRegistered(bytes32 nameHash);
    error InvalidName();
    error DIDAlreadyClaimed(bytes32 didHash); // PR #8
    error EmptyDID(); // PR #8

    // ── Functions ─────────────────────────────────────────────────────────────

    /// Register a name → DID mapping.
    /// @param name  Lowercase alphanumeric name (hyphens allowed, 1–64 chars)
    /// @param did   Full DID string to associate with this name
    function register(string calldata name, string calldata did) external {
        _validateName(name);
        if (bytes(did).length == 0) revert EmptyDID(); // PR #8 fix
        bytes32 nameHash = keccak256(bytes(name));
        if (_records[nameHash].owner != address(0)) revert NameTaken(nameHash);

        // PR #8 fix : reject if this DID is already mapped to another name.
        // Without this guard, an attacker can register "trusted-name-phish"
        // pointing at the same DID a legitimate name owns, overwriting the
        // didToName reverse mapping and turning consumers' reverseLookup(did)
        // into a phishing surface.
        bytes32 didHash = keccak256(bytes(did));
        if (bytes(didToName[didHash]).length != 0) revert DIDAlreadyClaimed(didHash);

        _records[nameHash] = NameRecord({
            owner: msg.sender,
            did: did,
            registeredAt: block.timestamp,
            updatedAt: block.timestamp
        });

        didToName[didHash] = name;

        emit NameRegistered(name, did, msg.sender, block.timestamp);
    }

    /// Update the DID associated with a name. Only the current owner can call.
    function update(string calldata name, string calldata newDid) external {
        if (bytes(newDid).length == 0) revert EmptyDID(); // PR #8 fix
        bytes32 nameHash = keccak256(bytes(name));
        NameRecord storage rec = _records[nameHash];
        if (rec.owner == address(0)) revert NotRegistered(nameHash);
        if (rec.owner != msg.sender) revert NotOwner(nameHash, msg.sender);

        bytes32 newDidHash = keccak256(bytes(newDid));
        bytes32 oldDidHash = keccak256(bytes(rec.did));

        // PR #8 fix : if the new DID is already mapped to a DIFFERENT name,
        // reject. Same-DID self-updates (newDid == oldDid) are allowed as a
        // no-op for callers that want to refresh updatedAt.
        if (newDidHash != oldDidHash && bytes(didToName[newDidHash]).length != 0) {
            revert DIDAlreadyClaimed(newDidHash);
        }

        // Remove old reverse mapping (no-op if same DID)
        if (newDidHash != oldDidHash) {
            delete didToName[oldDidHash];
        }

        rec.did = newDid;
        rec.updatedAt = block.timestamp;

        didToName[newDidHash] = name;

        emit NameUpdated(name, newDid, msg.sender, block.timestamp);
    }

    /// Transfer name ownership to a new Ethereum address.
    function transfer(string calldata name, address newOwner) external {
        bytes32 nameHash = keccak256(bytes(name));
        NameRecord storage rec = _records[nameHash];
        if (rec.owner == address(0)) revert NotRegistered(nameHash);
        if (rec.owner != msg.sender) revert NotOwner(nameHash, msg.sender);

        address prev = rec.owner;
        rec.owner = newOwner;
        rec.updatedAt = block.timestamp;

        emit NameTransferred(name, prev, newOwner);
    }

    /// Resolve a name → (owner, did, registeredAt, updatedAt).
    /// Returns zero values if not registered.
    function resolve(string calldata name)
        external
        view
        returns (address owner, string memory did, uint256 registeredAt, uint256 updatedAt)
    {
        bytes32 nameHash = keccak256(bytes(name));
        NameRecord storage rec = _records[nameHash];
        return (rec.owner, rec.did, rec.registeredAt, rec.updatedAt);
    }

    /// Reverse lookup: DID → name. Returns "" if not registered.
    function reverseLookup(string calldata did) external view returns (string memory name) {
        return didToName[keccak256(bytes(did))];
    }

    /// Check if a name is available.
    function isAvailable(string calldata name) external view returns (bool) {
        return _records[keccak256(bytes(name))].owner == address(0);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /// Validate: 1–64 chars, lowercase a-z, 0-9, hyphens (not at start/end).
    function _validateName(string calldata name) internal pure {
        bytes memory b = bytes(name);
        if (b.length == 0 || b.length > 64) revert InvalidName();
        if (b[0] == 0x2D || b[b.length - 1] == 0x2D) revert InvalidName(); // no leading/trailing hyphen
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            bool valid = (c >= 0x61 && c <= 0x7A) || // a-z
                         (c >= 0x30 && c <= 0x39) || // 0-9
                         (c == 0x2D);                // hyphen
            if (!valid) revert InvalidName();
        }
    }
}
