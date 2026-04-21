// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GitlawbStaking.sol";
import "./MockERC20.sol";

contract GitlawbStakingTest is Test {
    GitlawbStaking public staking;
    MockERC20 public token;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address depositor = address(0xDE90);

    uint256 constant OBSERVER_AMT  = 1_000 * 1e18;
    uint256 constant CURATOR_AMT   = 10_000 * 1e18;
    uint256 constant STEWARD_AMT   = 100_000 * 1e18;
    uint256 constant VALIDATOR_AMT = 1_000_000 * 1e18;

    function setUp() public {
        token = new MockERC20();
        staking = new GitlawbStaking(address(token));

        // Fund test accounts
        token.mint(alice, VALIDATOR_AMT * 10);
        token.mint(bob, VALIDATOR_AMT * 10);
        token.mint(depositor, VALIDATOR_AMT * 10);

        // Approve staking contract
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);
        vm.prank(depositor);
        token.approve(address(staking), type(uint256).max);
    }

    // ── Stake + Tiers ───────────────────────────────────────────────────────

    function test_stake_observerTier() public {
        vm.prank(alice);
        staking.stake(OBSERVER_AMT);

        assertEq(uint8(staking.getTier(alice)), uint8(GitlawbStaking.Tier.Observer));
        assertEq(staking.totalStaked(), OBSERVER_AMT);
    }

    function test_stake_curatorTier() public {
        vm.prank(alice);
        staking.stake(CURATOR_AMT);
        assertEq(uint8(staking.getTier(alice)), uint8(GitlawbStaking.Tier.Curator));
    }

    function test_stake_stewardTier() public {
        vm.prank(alice);
        staking.stake(STEWARD_AMT);
        assertEq(uint8(staking.getTier(alice)), uint8(GitlawbStaking.Tier.Steward));
    }

    function test_stake_validatorTier() public {
        vm.prank(alice);
        staking.stake(VALIDATOR_AMT);
        assertEq(uint8(staking.getTier(alice)), uint8(GitlawbStaking.Tier.Validator));
    }

    function test_stake_revertsBelow_minimumThreshold() public {
        vm.expectRevert(GitlawbStaking.BelowMinimumStake.selector);
        vm.prank(alice);
        staking.stake(500 * 1e18); // below 1,000
    }

    function test_stake_revertsZeroAmount() public {
        vm.expectRevert(GitlawbStaking.InvalidAmount.selector);
        vm.prank(alice);
        staking.stake(0);
    }

    // ── Unstake flow ────────────────────────────────────────────────────────

    function test_unstake_fullFlow() public {
        vm.prank(alice);
        staking.stake(CURATOR_AMT);

        // Request unstake
        vm.prank(alice);
        staking.requestUnstake(CURATOR_AMT);

        // Cannot unstake before cooldown
        vm.expectRevert(GitlawbStaking.CooldownNotElapsed.selector);
        vm.prank(alice);
        staking.unstake();

        // Warp past cooldown
        vm.warp(block.timestamp + 7 days + 1);

        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        staking.unstake();

        assertEq(token.balanceOf(alice) - balBefore, CURATOR_AMT);
        assertEq(staking.totalStaked(), 0);
    }

    function test_unstake_revertsIfNoPending() public {
        vm.prank(alice);
        staking.stake(OBSERVER_AMT);

        vm.expectRevert(GitlawbStaking.NoPendingUnstake.selector);
        vm.prank(alice);
        staking.unstake();
    }

    // ── Revenue + Rewards ───────────────────────────────────────────────────

    function test_rewardDistribution_singleStaker() public {
        vm.prank(alice);
        staking.stake(OBSERVER_AMT); // 1x multiplier

        // Deposit 1,000 tokens as revenue
        uint256 revenueAmount = 1_000 * 1e18;
        vm.prank(depositor);
        staking.depositRevenue(revenueAmount);

        // Alice should get all rewards
        uint256 pending = staking.pendingRewards(alice);
        assertEq(pending, revenueAmount);

        // Claim
        vm.prank(alice);
        staking.claimRewards();
        assertEq(staking.pendingRewards(alice), 0);
    }

    function test_rewardDistribution_twoStakers_differentTiers() public {
        // Alice stakes Observer (1x), Bob stakes Curator (2x)
        vm.prank(alice);
        staking.stake(OBSERVER_AMT);

        vm.prank(bob);
        staking.stake(CURATOR_AMT);

        // Deposit revenue
        uint256 revenueAmount = 3_000 * 1e18;
        vm.prank(depositor);
        staking.depositRevenue(revenueAmount);

        // Weighted: Alice = 1,000 * 1 = 1,000; Bob = 10,000 * 2 = 20,000
        // Total weighted = 21,000
        // Alice share = 1,000/21,000 * 3,000 ≈ 142.857...
        // Bob share = 20,000/21,000 * 3,000 ≈ 2,857.142...
        uint256 alicePending = staking.pendingRewards(alice);
        uint256 bobPending = staking.pendingRewards(bob);

        // Verify proportions (allow rounding from integer division)
        assertApproxEqAbs(alicePending + bobPending, revenueAmount, 1e4);
        assertTrue(bobPending > alicePending * 15); // Bob gets ~20x more (2x tier * 10x stake)
    }

    function test_depositRevenue_revertsIfNoStakers() public {
        vm.expectRevert(GitlawbStaking.InvalidAmount.selector);
        vm.prank(depositor);
        staking.depositRevenue(1_000 * 1e18);
    }

    function test_claimRewards_revertsIfNone() public {
        vm.prank(alice);
        staking.stake(OBSERVER_AMT);

        vm.expectRevert(GitlawbStaking.NoRewards.selector);
        vm.prank(alice);
        staking.claimRewards();
    }

    // ── getStakeInfo ────────────────────────────────────────────────────────

    function test_getStakeInfo() public {
        vm.prank(alice);
        staking.stake(STEWARD_AMT);

        (
            uint256 amount,
            GitlawbStaking.Tier tier,
            uint256 multiplier,
            uint256 pending,
            uint256 unstakeReqAt,
            uint256 unstakeAmt
        ) = staking.getStakeInfo(alice);

        assertEq(amount, STEWARD_AMT);
        assertEq(uint8(tier), uint8(GitlawbStaking.Tier.Steward));
        assertEq(multiplier, 4);
        assertEq(pending, 0);
        assertEq(unstakeReqAt, 0);
        assertEq(unstakeAmt, 0);
    }

    // ── Protocol stats ──────────────────────────────────────────────────────

    function test_protocolStats() public {
        vm.prank(alice);
        staking.stake(OBSERVER_AMT);

        uint256 rev = 500 * 1e18;
        vm.prank(depositor);
        staking.depositRevenue(rev);

        (uint256 totalSt, uint256 totalW, uint256 totalRew,) = staking.getProtocolStats();
        assertEq(totalSt, OBSERVER_AMT);
        assertEq(totalW, OBSERVER_AMT * 1); // 1x multiplier
        assertEq(totalRew, rev);
    }
}
