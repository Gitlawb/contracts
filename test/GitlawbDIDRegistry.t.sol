// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GitlawbDIDRegistry.sol";

contract GitlawbDIDRegistryTest is Test {
    GitlawbDIDRegistry public registry;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    string constant DID = "did:key:z6MknndwexV9umgQxPQ5R6cm5fAZLC2QuKFM9kCCV7Z3AdZp";
    string constant DOC = '{"@context":"https://www.w3.org/ns/did/v1","id":"did:key:z6Mk..."}';

    function setUp() public {
        registry = new GitlawbDIDRegistry();
    }

    function test_register() public {
        vm.prank(alice);
        registry.register(DID, DOC);

        (address owner, string memory doc) = registry.resolve(DID);
        assertEq(owner, alice);
        assertEq(doc, DOC);
        assertTrue(registry.isRegistered(DID));
    }

    function test_register_emits_event() public {
        bytes32 didHash = keccak256(bytes(DID));
        vm.expectEmit(true, true, false, false);
        emit GitlawbDIDRegistry.DIDRegistered(didHash, alice, DID, DOC);

        vm.prank(alice);
        registry.register(DID, DOC);
    }

    function test_register_reverts_if_duplicate() public {
        vm.prank(alice);
        registry.register(DID, DOC);

        bytes32 didHash = keccak256(bytes(DID));
        vm.expectRevert(abi.encodeWithSelector(GitlawbDIDRegistry.AlreadyRegistered.selector, didHash));
        vm.prank(bob);
        registry.register(DID, DOC);
    }

    function test_update_document() public {
        vm.prank(alice);
        registry.register(DID, DOC);

        string memory newDoc = '{"@context":"...","id":"did:key:z6Mk...","updated":true}';
        vm.prank(alice);
        registry.update(DID, newDoc);

        (, string memory doc) = registry.resolve(DID);
        assertEq(doc, newDoc);
    }

    function test_update_reverts_if_not_owner() public {
        vm.prank(alice);
        registry.register(DID, DOC);

        bytes32 didHash = keccak256(bytes(DID));
        vm.expectRevert(abi.encodeWithSelector(GitlawbDIDRegistry.NotOwner.selector, didHash, bob));
        vm.prank(bob);
        registry.update(DID, "new doc");
    }

    function test_transfer_ownership() public {
        vm.prank(alice);
        registry.register(DID, DOC);

        vm.prank(alice);
        registry.transfer(DID, bob);

        (address owner,) = registry.resolve(DID);
        assertEq(owner, bob);
    }

    function test_transfer_reverts_if_not_owner() public {
        vm.prank(alice);
        registry.register(DID, DOC);

        bytes32 didHash = keccak256(bytes(DID));
        vm.expectRevert(abi.encodeWithSelector(GitlawbDIDRegistry.NotOwner.selector, didHash, bob));
        vm.prank(bob);
        registry.transfer(DID, bob);
    }

    function test_resolve_unregistered_returns_zero() public view {
        (address owner, string memory doc) = registry.resolve("did:key:unknown");
        assertEq(owner, address(0));
        assertEq(bytes(doc).length, 0);
    }

    function test_empty_did_reverts() public {
        vm.expectRevert(GitlawbDIDRegistry.EmptyDID.selector);
        registry.register("", DOC);
    }
}
