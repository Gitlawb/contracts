// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GitlawbBounty.sol";
import "./MockERC20.sol";

contract GitlawbBountyTest is Test {
    GitlawbBounty public bounty;
    MockERC20 public token;

    address treasury = address(0xFEE);
    address creator  = address(0xA11CE);
    address delegate = address(0xDE1E6A7E);
    address agent    = address(0xA6E47);
    address anyone   = address(0xBAD);

    string constant REPO_OWNER = "did:key:z6Mk_owner";
    string constant REPO_NAME  = "my-repo";
    string constant ISSUE_ID   = "issue-001";
    string constant TITLE      = "Fix the login bug";
    string constant AGENT_DID  = "did:key:z6Mk_agent";
    string constant PR_ID      = "pr-42";

    uint256 constant AMOUNT = 100_000 * 1e18;

    function setUp() public {
        token = new MockERC20();
        bounty = new GitlawbBounty(address(token), treasury);

        // Fund creator and approve bounty contract
        token.mint(creator, AMOUNT * 10);
        vm.prank(creator);
        token.approve(address(bounty), type(uint256).max);

        // Fund agent for gas
        vm.deal(agent, 1 ether);
    }

    // ── createBounty ────────────────────────────────────────────────────────

    function test_createBounty() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        assertEq(id, 0);
        assertEq(token.balanceOf(address(bounty)), AMOUNT);
        assertEq(bounty.nextBountyId(), 1);
    }

    function test_createBounty_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit GitlawbBounty.BountyCreated(0, creator, AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(creator);
        bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);
    }

    function test_createBounty_revertsZeroAmount() public {
        vm.expectRevert(GitlawbBounty.InvalidAmount.selector);
        vm.prank(creator);
        bounty.createBounty(0, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);
    }

    // ── claimBounty ─────────────────────────────────────────────────────────

    function test_claimBounty() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(agent);
        bounty.claimBounty(id, AGENT_DID);

        (string memory claimantDid, address claimantAddr,,,,) = bounty.getBountyClaim(id);
        (,,, GitlawbBounty.Status status,,) = bounty.getBountyCore(id);
        assertEq(claimantDid, AGENT_DID);
        assertEq(claimantAddr, agent);
        assertEq(uint8(status), uint8(GitlawbBounty.Status.Claimed));
    }

    function test_claimBounty_revertsIfNotOpen() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(agent);
        bounty.claimBounty(id, AGENT_DID);

        // Second claim should fail
        vm.expectRevert(abi.encodeWithSelector(
            GitlawbBounty.InvalidStatus.selector, id, GitlawbBounty.Status.Open, GitlawbBounty.Status.Claimed
        ));
        vm.prank(anyone);
        bounty.claimBounty(id, "did:key:z6Mk_other");
    }

    // ── submitBounty ────────────────────────────────────────────────────────

    function test_submitBounty() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(agent);
        bounty.claimBounty(id, AGENT_DID);

        vm.prank(agent);
        bounty.submitBounty(id, PR_ID);

        (,, string memory prId,,,) = bounty.getBountyClaim(id);
        (,,, GitlawbBounty.Status status,,) = bounty.getBountyCore(id);
        assertEq(prId, PR_ID);
        assertEq(uint8(status), uint8(GitlawbBounty.Status.Submitted));
    }

    // ── approveBounty (full happy path) ─────────────────────────────────────

    function test_fullFlow_createClaimSubmitApprove() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(agent);
        bounty.claimBounty(id, AGENT_DID);

        vm.prank(agent);
        bounty.submitBounty(id, PR_ID);

        uint256 agentBalBefore = token.balanceOf(agent);
        uint256 treasuryBalBefore = token.balanceOf(treasury);

        vm.prank(creator);
        bounty.approveBounty(id);

        // 5% fee = 5,000 tokens, payout = 95,000 tokens
        uint256 expectedFee = (AMOUNT * 500) / 10000;
        uint256 expectedPayout = AMOUNT - expectedFee;

        assertEq(token.balanceOf(agent) - agentBalBefore, expectedPayout);
        assertEq(token.balanceOf(treasury) - treasuryBalBefore, expectedFee);

        (,,, GitlawbBounty.Status status,,) = bounty.getBountyCore(id);
        assertEq(uint8(status), uint8(GitlawbBounty.Status.Completed));

        // Agent stats
        (uint256 earnings, uint256 count) = bounty.getAgentStats(AGENT_DID);
        assertEq(earnings, expectedPayout);
        assertEq(count, 1);

        // Protocol stats
        (uint256 total, uint256 paid, uint256 fees) = bounty.getProtocolStats();
        assertEq(total, 1);
        assertEq(paid, expectedPayout);
        assertEq(fees, expectedFee);
    }

    function test_fullFlow_createClaimSubmitApprove_AsDelegate() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(agent);
        bounty.claimBounty(id, AGENT_DID);

        vm.prank(agent);
        bounty.submitBounty(id, PR_ID);

        uint256 agentBalBefore = token.balanceOf(agent);
        uint256 treasuryBalBefore = token.balanceOf(treasury);

        vm.prank(creator);
        bounty.addBountyManagementDelegate(id, delegate);

        vm.prank(delegate);
        bounty.approveBounty(id);

        // 5% fee = 5,000 tokens, payout = 95,000 tokens
        uint256 expectedFee = (AMOUNT * 500) / 10000;
        uint256 expectedPayout = AMOUNT - expectedFee;

        assertEq(token.balanceOf(agent) - agentBalBefore, expectedPayout);
        assertEq(token.balanceOf(treasury) - treasuryBalBefore, expectedFee);

        (,,, GitlawbBounty.Status status,,) = bounty.getBountyCore(id);
        assertEq(uint8(status), uint8(GitlawbBounty.Status.Completed));

        // Agent stats
        (uint256 earnings, uint256 count) = bounty.getAgentStats(AGENT_DID);
        assertEq(earnings, expectedPayout);
        assertEq(count, 1);

        // Protocol stats
        (uint256 total, uint256 paid, uint256 fees) = bounty.getProtocolStats();
        assertEq(total, 1);
        assertEq(paid, expectedPayout);
        assertEq(fees, expectedFee);
    }

    // ── cancelBounty ────────────────────────────────────────────────────────

    function test_cancelBounty() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        uint256 balBefore = token.balanceOf(creator);

        vm.prank(creator);
        bounty.cancelBounty(id);

        assertEq(token.balanceOf(creator) - balBefore, AMOUNT);

        (,,, GitlawbBounty.Status status,,) = bounty.getBountyCore(id);
        assertEq(uint8(status), uint8(GitlawbBounty.Status.Cancelled));
    }

    function test_cancelBounty_AsDelegate() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        uint256 balBefore = token.balanceOf(creator);
        vm.prank(creator);
        bounty.addBountyManagementDelegate(id, delegate);

        vm.prank(delegate);
        bounty.cancelBounty(id);

        assertEq(token.balanceOf(creator) - balBefore, AMOUNT);

        (,,, GitlawbBounty.Status status,,) = bounty.getBountyCore(id);
        assertEq(uint8(status), uint8(GitlawbBounty.Status.Cancelled));
    }

    function test_cancelBounty_revertsIfClaimed() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(agent);
        bounty.claimBounty(id, AGENT_DID);

        vm.expectRevert(abi.encodeWithSelector(
            GitlawbBounty.InvalidStatus.selector, id, GitlawbBounty.Status.Open, GitlawbBounty.Status.Claimed
        ));
        vm.prank(creator);
        bounty.cancelBounty(id);
    }

    function test_cancelBounty_revertsIfClaimed_AsDelegate() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(agent);
        bounty.claimBounty(id, AGENT_DID);

        vm.prank(creator);
        bounty.addBountyManagementDelegate(id, delegate);

        vm.expectRevert(abi.encodeWithSelector(
            GitlawbBounty.InvalidStatus.selector, id, GitlawbBounty.Status.Open, GitlawbBounty.Status.Claimed
        ));
        vm.prank(delegate);
        bounty.cancelBounty(id);
    }
    
    // ── disputeBounty ───────────────────────────────────────────────────────

    function test_disputeBounty_afterDeadline() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(agent);
        bounty.claimBounty(id, AGENT_DID);

        // Warp past the 7 day deadline
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(anyone);
        bounty.disputeBounty(id);

        (string memory claimantDid,,,,,) = bounty.getBountyClaim(id);
        (,,, GitlawbBounty.Status status,,) = bounty.getBountyCore(id);
        assertEq(uint8(status), uint8(GitlawbBounty.Status.Open));
        assertEq(bytes(claimantDid).length, 0);
    }

    function test_disputeBounty_revertsBeforeDeadline() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(agent);
        bounty.claimBounty(id, AGENT_DID);

        vm.expectRevert(abi.encodeWithSelector(GitlawbBounty.DeadlineNotExceeded.selector, id));
        vm.prank(anyone);
        bounty.disputeBounty(id);
    }

    // ── Admin ───────────────────────────────────────────────────────────────

    function test_setProtocolFee() public {
        bounty.setProtocolFee(300); // 3%
        assertEq(bounty.protocolFeeBps(), 300);
    }

    function test_setProtocolFee_revertsAboveMax() public {
        vm.expectRevert("fee too high");
        bounty.setProtocolFee(1001);
    }

    function test_setTreasury() public {
        address newTreasury = address(0xDEAD);
        bounty.setTreasury(newTreasury);
        assertEq(bounty.treasury(), newTreasury);
    }

    function test_addBountyManagementDelegate() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.startPrank(creator);
        vm.expectEmit(true, true, false, false);
        emit GitlawbBounty.BountyManagementDelegateAdded(id, delegate);
        bounty.addBountyManagementDelegate(id, delegate);
        vm.stopPrank();

        address[] memory delegates = bounty.bountyDelegates(id);
        assertEq(delegates.length, 1);
        assertEq(delegates[0], delegate);
    }

    function test_addBountyManagementDelegate_idempotent() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(creator);
        bounty.addBountyManagementDelegate(id, delegate);

        address[] memory delegates = bounty.bountyDelegates(id);
        assertEq(delegates.length, 1);
        assertEq(delegates[0], delegate);

        vm.prank(creator);
        bounty.addBountyManagementDelegate(id, delegate);

        delegates = bounty.bountyDelegates(id);
        assertEq(delegates.length, 1);
        assertEq(delegates[0], delegate);
    }


    function test_addBountyManagementDelegate_IfNotBountyCreator_empty() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.startPrank(anyone);
        vm.expectRevert(abi.encodeWithSelector(GitlawbBounty.NotBountyCreator.selector, id));
        bounty.addBountyManagementDelegate(id, delegate);
        vm.stopPrank();
    }

    function test_addBountyManagementDelegate_IfNotBountyCreator_filled() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(creator);
        bounty.addBountyManagementDelegate(id, delegate);

        address[] memory delegates = bounty.bountyDelegates(id);
        assertEq(delegates.length, 1);
        assertEq(delegates[0], delegate);

        vm.startPrank(anyone);
        vm.expectRevert(abi.encodeWithSelector(GitlawbBounty.NotBountyCreator.selector, id));
        bounty.addBountyManagementDelegate(id, delegate);
        vm.stopPrank();
    }

    function test_removeBountyDelegate() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.startPrank(creator);
        vm.expectEmit(true, true, false, false);
        emit GitlawbBounty.BountyManagementDelegateAdded(id, delegate);
        bounty.addBountyManagementDelegate(id, delegate);
        vm.stopPrank();

        address[] memory delegates = bounty.bountyDelegates(id);
        assertEq(delegates.length, 1);
        assertEq(delegates[0], delegate);

        vm.prank(creator);
        bounty.removeBountyDelegate(id, delegate);
        delegates = bounty.bountyDelegates(id);
        assertEq(delegates.length, 0);
        vm.stopPrank();
    }

    function test_removeBountyDelegate_IfNotBountyCreator_empty() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.startPrank(anyone);
        vm.expectRevert(abi.encodeWithSelector(GitlawbBounty.NotBountyCreator.selector, id));
        bounty.removeBountyDelegate(id, delegate);
        vm.stopPrank();

        address[] memory delegates = bounty.bountyDelegates(id);
        assertEq(delegates.length, 0);
    }

    function test_removeBountyDelegate_IfNotBountyCreator_filled() public {
        vm.prank(creator);
        uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

        vm.prank(creator);
        bounty.addBountyManagementDelegate(id, delegate);

        address[] memory delegates = bounty.bountyDelegates(id);
        assertEq(delegates.length, 1);
        assertEq(delegates[0], delegate);

        vm.startPrank(anyone);
        vm.expectRevert(abi.encodeWithSelector(GitlawbBounty.NotBountyCreator.selector, id));
        bounty.removeBountyDelegate(id, delegate);
        vm.stopPrank();

        delegates = bounty.bountyDelegates(id);
        assertEq(delegates.length, 1);
        assertEq(delegates[0], delegate);
    }

}
