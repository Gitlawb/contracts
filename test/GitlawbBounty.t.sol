// Add a new test for disputeBounty with approved submission
function test_disputeBounty_approvedSubmission() public {
    vm.prank(creator);
    uint256 id = bounty.createBounty(AMOUNT, REPO_OWNER, REPO_NAME, ISSUE_ID, TITLE);

    vm.prank(agent);
    bounty.claimBounty(id, AGENT_DID);

    vm.prank(agent);
    bounty.submitBounty(id, PR_ID);

    vm.prank(creator);
    bounty.approveBounty(id);

    vm.expectRevert(GitlawbBounty.AlreadyApproved.selector);
    bounty.disputeBounty(id);
}