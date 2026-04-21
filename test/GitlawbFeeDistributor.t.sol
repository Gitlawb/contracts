// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GitlawbFeeDistributor.sol";
import "../src/GitlawbStaking.sol";
import "../src/GitlawbNodeStaking.sol";
import "./MockERC20.sol";

contract GitlawbFeeDistributorTest is Test {
    GitlawbFeeDistributor public distributor;
    GitlawbStaking public userStaking;
    GitlawbNodeStaking public nodeStaking;
    MockERC20 public token;

    address alice = address(0xA11CE);   // user staker
    address nodeOp = address(0xBADA55);  // node operator
    address keeper = address(0x1EE1);    // calls distribute()
    address funder = address(0xF0ED);    // seeds the distributor

    bytes32 constant NODE_DID = keccak256("did:key:test-node");

    uint256 constant USER_STAKE = 10_000 * 1e18; // Curator tier
    uint256 constant NODE_STAKE = 10_000 * 1e18; // min

    function setUp() public {
        token = new MockERC20();
        userStaking = new GitlawbStaking(address(token));
        nodeStaking = new GitlawbNodeStaking(address(token));
        distributor = new GitlawbFeeDistributor(
            address(token),
            address(nodeStaking),
            address(userStaking)
        );

        // Seed accounts
        token.mint(alice, USER_STAKE * 10);
        token.mint(nodeOp, NODE_STAKE * 10);
        token.mint(funder, 1_000_000 * 1e18);

        // Approvals
        vm.prank(alice);
        token.approve(address(userStaking), type(uint256).max);
        vm.prank(nodeOp);
        token.approve(address(nodeStaking), type(uint256).max);

        // Set up a user staker and a node staker so depositRevenue won't revert
        vm.prank(alice);
        userStaking.stake(USER_STAKE);

        vm.prank(nodeOp);
        nodeStaking.registerNode(NODE_DID, "https://test-node", NODE_STAKE);
    }

    function _fundDistributor(uint256 amount) internal {
        vm.prank(funder);
        token.transfer(address(distributor), amount);
    }

    /// Node heartbeats right before distribution so it's considered active.
    /// In production the operator posts these daily from the node process.
    function _keepAlive() internal {
        vm.prank(nodeOp);
        nodeStaking.heartbeat(NODE_DID);
    }

    // ── Timing gate ─────────────────────────────────────────────────────────

    function test_distribute_revertsBeforeWeekElapses() public {
        _fundDistributor(100_000 * 1e18);

        vm.expectRevert();
        vm.prank(keeper);
        distributor.distribute();
    }

    function test_distribute_worksAfter7Days() public {
        _fundDistributor(100_000 * 1e18);
        vm.warp(block.timestamp + 7 days + 1);
        _keepAlive();

        vm.prank(keeper);
        distributor.distribute();

        assertEq(distributor.distributionCount(), 1);
        assertEq(distributor.totalDistributed(), 100_000 * 1e18);
    }

    // ── Split math ──────────────────────────────────────────────────────────

    function test_distribute_splits_75_24_1() public {
        uint256 pot = 100_000 * 1e18;
        _fundDistributor(pot);
        vm.warp(block.timestamp + 7 days + 1);
        _keepAlive();

        uint256 keeperBalBefore = token.balanceOf(keeper);

        vm.prank(keeper);
        distributor.distribute();

        // Keeper got 1%
        uint256 expectedKeeper = (pot * 100) / 10_000;
        assertEq(token.balanceOf(keeper) - keeperBalBefore, expectedKeeper);

        // NodeStaking got 75%
        uint256 expectedNode = (pot * 7500) / 10_000;
        assertEq(token.balanceOf(address(nodeStaking)), NODE_STAKE + expectedNode);

        // UserStaking got 24% (remainder)
        uint256 expectedUser = pot - expectedKeeper - expectedNode;
        assertEq(token.balanceOf(address(userStaking)), USER_STAKE + expectedUser);

        // Distributor is fully drained
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    function test_distribute_flowsIntoPendingRewards() public {
        uint256 pot = 100_000 * 1e18;
        _fundDistributor(pot);
        vm.warp(block.timestamp + 7 days + 1);
        _keepAlive();

        vm.prank(keeper);
        distributor.distribute();

        // Node operator should have ~75k pending (single active node)
        assertApproxEqAbs(nodeStaking.pendingRewards(NODE_DID), 75_000 * 1e18, 1e6);

        // User staker should have ~24k pending (single user staker)
        assertApproxEqAbs(userStaking.pendingRewards(alice), 24_000 * 1e18, 1e6);
    }

    // ── Dust / empty balance ────────────────────────────────────────────────

    function test_distribute_revertsIfBelowDustThreshold() public {
        // Only 0.5 tokens in the pot
        _fundDistributor(5e17);
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(GitlawbFeeDistributor.NothingToDistribute.selector);
        vm.prank(keeper);
        distributor.distribute();
    }

    // ── Consecutive epochs ──────────────────────────────────────────────────

    function test_distribute_twoConsecutiveEpochs() public {
        _fundDistributor(50_000 * 1e18);
        uint256 t1 = block.timestamp + 7 days + 1;
        vm.warp(t1);
        _keepAlive();
        vm.prank(keeper);
        distributor.distribute();

        // After another 7 days, second epoch works
        _fundDistributor(30_000 * 1e18);
        uint256 t2 = t1 + 7 days + 1;
        vm.warp(t2);
        _keepAlive();
        vm.prank(keeper);
        distributor.distribute();

        assertEq(distributor.distributionCount(), 2);
        assertEq(distributor.totalDistributed(), 80_000 * 1e18);
    }

    // ── Split reconfig ──────────────────────────────────────────────────────

    function test_setSplit_works() public {
        // 7500 → 7000 (delta 500 = MAX_BPS_CHANGE), 2400 → 2900, 100 → 100
        distributor.setSplit(7000, 2900, 100);
        assertEq(distributor.nodeShareBps(), 7000);
        assertEq(distributor.userShareBps(), 2900);
        assertEq(distributor.keeperShareBps(), 100);
    }

    function test_setSplit_revertsIfSumWrong() public {
        vm.expectRevert(GitlawbFeeDistributor.BadSplit.selector);
        distributor.setSplit(7500, 2000, 100); // sums to 9600
    }

    function test_setSplit_revertsIfChangeTooLarge() public {
        vm.expectRevert(GitlawbFeeDistributor.ChangeTooLarge.selector);
        distributor.setSplit(5000, 4900, 100); // node drops by 2500, > 500 max
    }

    function test_setSplit_revertsIfNotOwner() public {
        vm.expectRevert(GitlawbFeeDistributor.NotOwner.selector);
        vm.prank(alice);
        distributor.setSplit(7500, 2400, 100);
    }

    // ── Sinks reconfig ──────────────────────────────────────────────────────

    function test_setSinks() public {
        address newNode = address(0xC0FFEE);
        address newUser = address(0xBEEF);
        distributor.setSinks(newNode, newUser);
        assertEq(address(distributor.nodeStaking()), newNode);
        assertEq(address(distributor.userStaking()), newUser);
    }

    function test_setSinks_revertsZero() public {
        vm.expectRevert(GitlawbFeeDistributor.ZeroAddress.selector);
        distributor.setSinks(address(0), address(userStaking));
    }

    // ── Preview ─────────────────────────────────────────────────────────────

    function test_previewDistribution() public {
        _fundDistributor(100_000 * 1e18);

        (uint256 total, uint256 nodeShare, uint256 userShare, uint256 keeperShare) =
            distributor.previewDistribution();

        assertEq(total, 100_000 * 1e18);
        assertEq(nodeShare, 75_000 * 1e18);
        assertEq(keeperShare, 1_000 * 1e18);
        assertEq(userShare, 24_000 * 1e18);
    }

    // ── Ownership ───────────────────────────────────────────────────────────

    function test_transferOwnership() public {
        distributor.transferOwnership(alice);
        assertEq(distributor.owner(), alice);
    }
}
