// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GitlawbNodeStaking.sol";
import "./MockERC20.sol";

contract GitlawbNodeStakingTest is Test {
    GitlawbNodeStaking public nodeStaking;
    MockERC20 public token;

    address alice = address(0xA11CE);   // node operator 1
    address bob   = address(0xB0B);     // node operator 2
    address carol = address(0xCA201);   // node operator 3
    address depositor = address(0xDE90); // plays the FeeDistributor role

    bytes32 constant DID_A = keccak256("did:key:alice-node");
    bytes32 constant DID_B = keccak256("did:key:bob-node");
    bytes32 constant DID_C = keccak256("did:key:carol-node");

    uint256 constant MIN = 10_000 * 1e18;

    function setUp() public {
        token = new MockERC20();
        nodeStaking = new GitlawbNodeStaking(address(token));

        token.mint(alice, MIN * 100);
        token.mint(bob, MIN * 100);
        token.mint(carol, MIN * 100);
        token.mint(depositor, MIN * 100);

        vm.prank(alice);
        token.approve(address(nodeStaking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(nodeStaking), type(uint256).max);
        vm.prank(carol);
        token.approve(address(nodeStaking), type(uint256).max);
        vm.prank(depositor);
        token.approve(address(nodeStaking), type(uint256).max);
    }

    // ── Registration ────────────────────────────────────────────────────────

    function test_registerNode() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://alice.gitlawb.com", MIN);

        (address op, string memory url, uint256 stake,,,, bool currentlyActive,,) =
            nodeStaking.getNodeInfo(DID_A);
        assertEq(op, alice);
        assertEq(url, "https://alice.gitlawb.com");
        assertEq(stake, MIN);
        assertTrue(currentlyActive);
        assertEq(nodeStaking.totalRegisteredStake(), MIN);
        assertEq(nodeStaking.totalActiveStake(), MIN);
    }

    function test_registerNode_revertsBelowMin() public {
        vm.expectRevert(GitlawbNodeStaking.BelowMinimumStake.selector);
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN - 1);
    }

    function test_registerNode_revertsAlreadyRegistered() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);

        vm.expectRevert(GitlawbNodeStaking.AlreadyRegistered.selector);
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);
    }

    // ── Heartbeat ───────────────────────────────────────────────────────────

    function test_heartbeat_updatesTimestamp() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);

        vm.warp(block.timestamp + 12 hours);
        vm.prank(alice);
        nodeStaking.heartbeat(DID_A);

        (,,, uint256 lastHb,,,,,) = nodeStaking.getNodeInfo(DID_A);
        assertEq(lastHb, block.timestamp);
    }

    function test_heartbeat_revertsIfNotOperator() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);

        vm.expectRevert(GitlawbNodeStaking.NotOperator.selector);
        vm.prank(bob);
        nodeStaking.heartbeat(DID_A);
    }

    function test_heartbeat_revertsIfUnknown() public {
        vm.expectRevert(GitlawbNodeStaking.NodeNotFound.selector);
        vm.prank(alice);
        nodeStaking.heartbeat(DID_A);
    }

    // ── Active/inactive detection ───────────────────────────────────────────

    function test_isActive_trueWithinThreshold() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);

        vm.warp(block.timestamp + 2 days);
        assertTrue(nodeStaking.isActive(DID_A));
    }

    function test_isActive_falseAfterThreshold() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);

        vm.warp(block.timestamp + 3 days + 1);
        assertFalse(nodeStaking.isActive(DID_A));
    }

    // ── Revenue distribution ────────────────────────────────────────────────

    function test_depositRevenue_singleActiveNode() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);

        uint256 rev = 1_000 * 1e18;
        vm.prank(depositor);
        nodeStaking.depositRevenue(rev);

        assertApproxEqAbs(nodeStaking.pendingRewards(DID_A), rev, 1e6);
    }

    function test_depositRevenue_skipsOfflineNode() public {
        // Alice registers, Bob registers
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://a", MIN);
        vm.prank(bob);
        nodeStaking.registerNode(DID_B, "https://b", MIN);

        // Alice heartbeats, Bob goes dark
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(alice);
        nodeStaking.heartbeat(DID_A);
        // Bob has NOT heartbeat — should be considered inactive

        // Deposit 1,000 revenue
        uint256 rev = 1_000 * 1e18;
        vm.prank(depositor);
        nodeStaking.depositRevenue(rev);

        // Alice gets all of it, Bob gets nothing
        assertApproxEqAbs(nodeStaking.pendingRewards(DID_A), rev, 1e6);
        assertEq(nodeStaking.pendingRewards(DID_B), 0);
        // totalActiveStake should have been refreshed to only Alice
        assertEq(nodeStaking.totalActiveStake(), MIN);
    }

    function test_depositRevenue_proRataAcrossActiveNodes() public {
        // Three nodes register with different stakes
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://a", MIN);        // 10k
        vm.prank(bob);
        nodeStaking.registerNode(DID_B, "https://b", MIN * 3);    // 30k
        vm.prank(carol);
        nodeStaking.registerNode(DID_C, "https://c", MIN * 6);    // 60k

        uint256 rev = 100_000 * 1e18;
        vm.prank(depositor);
        nodeStaking.depositRevenue(rev);

        // Total active = 100k; Alice = 10%, Bob = 30%, Carol = 60%
        assertApproxEqAbs(nodeStaking.pendingRewards(DID_A), 10_000 * 1e18, 1e12);
        assertApproxEqAbs(nodeStaking.pendingRewards(DID_B), 30_000 * 1e18, 1e12);
        assertApproxEqAbs(nodeStaking.pendingRewards(DID_C), 60_000 * 1e18, 1e12);
    }

    function test_depositRevenue_revertsIfNoActiveStake() public {
        // No nodes registered at all
        vm.expectRevert(GitlawbNodeStaking.NoActiveStake.selector);
        vm.prank(depositor);
        nodeStaking.depositRevenue(1_000 * 1e18);
    }

    function test_depositRevenue_revertsIfAllInactive() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);

        vm.warp(block.timestamp + 10 days);

        vm.expectRevert(GitlawbNodeStaking.NoActiveStake.selector);
        vm.prank(depositor);
        nodeStaking.depositRevenue(1_000 * 1e18);
    }

    // ── Reactivation after downtime ─────────────────────────────────────────

    function test_offlineNode_doesNotEarnDuringDowntime_butResumesAfter() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://a", MIN);
        vm.prank(bob);
        nodeStaking.registerNode(DID_B, "https://b", MIN);

        // Bob goes offline, Alice stays online
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(alice);
        nodeStaking.heartbeat(DID_A);

        // Epoch 1: Alice gets all
        vm.prank(depositor);
        nodeStaking.depositRevenue(1_000 * 1e18);

        uint256 aliceE1 = nodeStaking.pendingRewards(DID_A);
        assertApproxEqAbs(aliceE1, 1_000 * 1e18, 1e6);
        assertEq(nodeStaking.pendingRewards(DID_B), 0);

        // Bob comes back online
        vm.warp(block.timestamp + 1 hours);
        vm.prank(bob);
        nodeStaking.heartbeat(DID_B);
        vm.prank(alice);
        nodeStaking.heartbeat(DID_A);

        // Epoch 2: Alice and Bob split 50/50
        vm.prank(depositor);
        nodeStaking.depositRevenue(1_000 * 1e18);

        uint256 aliceE2 = nodeStaking.pendingRewards(DID_A);
        uint256 bobE2 = nodeStaking.pendingRewards(DID_B);
        // Alice now has epoch1 + half of epoch2
        assertApproxEqAbs(aliceE2, aliceE1 + 500 * 1e18, 1e6);
        assertApproxEqAbs(bobE2, 500 * 1e18, 1e6);
    }

    // ── Regression: pre-outage earnings must not be stripped after 3d offline ──

    /// An operator who was active at the time of a deposit must still be able
    /// to claim those rewards after going offline for more than 3 days.
    /// Previously the _harvest else-branch overwrote rewardDebt without
    /// crediting the earned delta into pendingRewards — permanently stranding
    /// the tokens in the contract.
    function test_harvest_preservesPreOutageRewards() public {
        // Alice registers and is active
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://a", MIN);

        // Deposit while Alice is active — she is entitled to all of it
        uint256 rev = 1_000 * 1e18;
        vm.prank(depositor);
        nodeStaking.depositRevenue(rev);

        // Alice goes offline (misses heartbeats for >3 days)
        vm.warp(block.timestamp + 4 days);

        // Alice recovers and heartbeats — _harvest runs on the stale node
        vm.prank(alice);
        nodeStaking.heartbeat(DID_A);

        // Her pre-outage earnings must be intact
        uint256 pending = nodeStaking.pendingRewards(DID_A);
        assertApproxEqAbs(pending, rev, 1e6);

        // And she can actually claim them
        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        nodeStaking.claimRewards(DID_A);
        assertApproxEqAbs(token.balanceOf(alice) - balBefore, rev, 1e6);
    }

    /// Same scenario but the operator calls claimRewards (not heartbeat) after
    /// returning. The bug manifested on all harvest-triggering paths.
    function test_harvest_preservesPreOutageRewards_viaClaim() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://a", MIN);

        vm.prank(depositor);
        nodeStaking.depositRevenue(1_000 * 1e18);

        vm.warp(block.timestamp + 5 days);

        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        nodeStaking.claimRewards(DID_A);
        assertApproxEqAbs(token.balanceOf(alice) - balBefore, 1_000 * 1e18, 1e6);
    }

    // ── Claim rewards ───────────────────────────────────────────────────────

    function test_claimRewards() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);

        vm.prank(depositor);
        nodeStaking.depositRevenue(1_000 * 1e18);

        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        nodeStaking.claimRewards(DID_A);
        uint256 balAfter = token.balanceOf(alice);

        assertApproxEqAbs(balAfter - balBefore, 1_000 * 1e18, 1e6);
        assertEq(nodeStaking.pendingRewards(DID_A), 0);
    }

    function test_claimRewards_revertsNoRewards() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);

        vm.expectRevert(GitlawbNodeStaking.NoRewards.selector);
        vm.prank(alice);
        nodeStaking.claimRewards(DID_A);
    }

    // ── Unstake flow ────────────────────────────────────────────────────────

    function test_unstake_fullFlow() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);

        vm.prank(alice);
        nodeStaking.requestUnstake(DID_A);

        // Cannot unstake before cooldown
        vm.expectRevert(GitlawbNodeStaking.CooldownNotElapsed.selector);
        vm.prank(alice);
        nodeStaking.unstake(DID_A);

        vm.warp(block.timestamp + 7 days + 1);

        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        nodeStaking.unstake(DID_A);
        uint256 balAfter = token.balanceOf(alice);

        // Stake returned
        assertEq(balAfter - balBefore, MIN);
        assertEq(nodeStaking.totalRegisteredStake(), 0);

        // Node deactivated
        (address op,, uint256 stake,,,bool active,,,) = nodeStaking.getNodeInfo(DID_A);
        assertEq(op, alice); // record persists
        assertEq(stake, 0);
        assertFalse(active);
    }

    function test_unstake_revertsIfNoRequest() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);

        vm.expectRevert(GitlawbNodeStaking.NoPendingUnstake.selector);
        vm.prank(alice);
        nodeStaking.unstake(DID_A);
    }

    function test_requestUnstake_doubleRequestReverts() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://x", MIN);

        vm.prank(alice);
        nodeStaking.requestUnstake(DID_A);

        vm.expectRevert(GitlawbNodeStaking.UnstakePending.selector);
        vm.prank(alice);
        nodeStaking.requestUnstake(DID_A);
    }

    // ── URL update ──────────────────────────────────────────────────────────

    function test_updateHttpUrl() public {
        vm.prank(alice);
        nodeStaking.registerNode(DID_A, "https://old", MIN);

        vm.prank(alice);
        nodeStaking.updateHttpUrl(DID_A, "https://new");

        (, string memory url,,,,,,,) = nodeStaking.getNodeInfo(DID_A);
        assertEq(url, "https://new");
    }

    // ── Admin ───────────────────────────────────────────────────────────────

    function test_transferOwnership() public {
        nodeStaking.transferOwnership(alice);
        assertEq(nodeStaking.owner(), alice);
    }

    function test_transferOwnership_revertsNotOwner() public {
        vm.expectRevert(GitlawbNodeStaking.NotOwner.selector);
        vm.prank(alice);
        nodeStaking.transferOwnership(bob);
    }
}
