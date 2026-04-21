// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GitlawbNameRegistry.sol";

contract GitlawbNameRegistryTest is Test {
    GitlawbNameRegistry public registry;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    string constant NAME = "alice";
    string constant DID  = "did:key:z6MknndwexV9umgQxPQ5R6cm5fAZLC2QuKFM9kCCV7Z3AdZp";
    string constant DID2 = "did:key:z6MkrV8ktCUnTzT5mEUzSTJdcj6tgBRqkLinRkGL2JrBKJwg";

    function setUp() public {
        registry = new GitlawbNameRegistry();
    }

    function test_register() public {
        vm.prank(alice);
        registry.register(NAME, DID);

        (address owner, string memory did,,) = registry.resolve(NAME);
        assertEq(owner, alice);
        assertEq(did, DID);
        assertFalse(registry.isAvailable(NAME));
    }

    function test_reverse_lookup() public {
        vm.prank(alice);
        registry.register(NAME, DID);
        assertEq(registry.reverseLookup(DID), NAME);
    }

    function test_name_taken_reverts() public {
        vm.prank(alice);
        registry.register(NAME, DID);

        bytes32 nameHash = keccak256(bytes(NAME));
        vm.expectRevert(abi.encodeWithSelector(GitlawbNameRegistry.NameTaken.selector, nameHash));
        vm.prank(bob);
        registry.register(NAME, DID2);
    }

    function test_update_did() public {
        vm.prank(alice);
        registry.register(NAME, DID);

        vm.prank(alice);
        registry.update(NAME, DID2);

        (, string memory did,,) = registry.resolve(NAME);
        assertEq(did, DID2);

        // Old reverse mapping removed, new one set
        assertEq(registry.reverseLookup(DID), "");
        assertEq(registry.reverseLookup(DID2), NAME);
    }

    function test_update_reverts_if_not_owner() public {
        vm.prank(alice);
        registry.register(NAME, DID);

        bytes32 nameHash = keccak256(bytes(NAME));
        vm.expectRevert(abi.encodeWithSelector(GitlawbNameRegistry.NotOwner.selector, nameHash, bob));
        vm.prank(bob);
        registry.update(NAME, DID2);
    }

    function test_transfer() public {
        vm.prank(alice);
        registry.register(NAME, DID);

        vm.prank(alice);
        registry.transfer(NAME, bob);

        (address owner,,,) = registry.resolve(NAME);
        assertEq(owner, bob);
    }

    function test_invalid_name_uppercase() public {
        vm.expectRevert(GitlawbNameRegistry.InvalidName.selector);
        registry.register("Alice", DID);
    }

    function test_invalid_name_leading_hyphen() public {
        vm.expectRevert(GitlawbNameRegistry.InvalidName.selector);
        registry.register("-alice", DID);
    }

    function test_invalid_name_trailing_hyphen() public {
        vm.expectRevert(GitlawbNameRegistry.InvalidName.selector);
        registry.register("alice-", DID);
    }

    function test_invalid_name_empty() public {
        vm.expectRevert(GitlawbNameRegistry.InvalidName.selector);
        registry.register("", DID);
    }

    function test_valid_hyphenated_name() public {
        vm.prank(alice);
        registry.register("acme-corp", DID);

        (address owner,,,) = registry.resolve("acme-corp");
        assertEq(owner, alice);
    }

    function test_available_before_register() public view {
        assertTrue(registry.isAvailable("unknown-name"));
    }
}
