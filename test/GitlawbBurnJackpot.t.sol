// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GitlawbBurnJackpot.sol";
import "./MockERC20.sol";

/// Mock VRF v2.5 coordinator: hands out sequential request ids and lets tests
/// deliver arbitrary "random" words to the consumer.
contract MockVRFCoordinator {
    uint256 public nextId = 1;
    uint256 public lastRequestId;
    bytes32 public lastKeyHash;
    uint256 public lastSubId;
    uint32 public lastNumWords;
    bytes public lastExtraArgs;
    uint256 public requestCount;

    function requestRandomWords(IVRFCoordinatorV2Plus.RandomWordsRequest calldata req)
        external
        returns (uint256 id)
    {
        id = nextId++;
        lastRequestId = id;
        lastKeyHash = req.keyHash;
        lastSubId = req.subId;
        lastNumWords = req.numWords;
        lastExtraArgs = req.extraArgs;
        requestCount++;
    }

    function fulfill(address consumer, uint256 requestId, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        GitlawbBurnJackpot(payable(consumer)).rawFulfillRandomWords(requestId, words);
    }
}

contract GitlawbBurnJackpotTest is Test {
    GitlawbBurnJackpot public jackpot;
    MockERC20 public token;
    MockVRFCoordinator public coord;

    address constant BURN = 0x000000000000000000000000000000000000dEaD;
    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);
    address rando = address(0x4A2D0);

    uint256 constant DURATION = 7 days;
    uint256 constant WINNER_BPS = 6_000;
    uint256 constant MIN_BURN = 100 ether;

    function setUp() public {
        token = new MockERC20();
        coord = new MockVRFCoordinator();
        jackpot = new GitlawbBurnJackpot(
            address(token), address(coord), bytes32("keyhash"), 42, DURATION, WINNER_BPS, MIN_BURN
        );
        // Kevin's initial jackpot seed.
        vm.deal(owner, 1 ether);
        jackpot.seedPot{value: 1 ether}();
    }

    function _burn(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(jackpot), amount);
        vm.prank(who);
        jackpot.burnForTickets(amount);
    }

    /// Close the current epoch after its deadline and return the VRF request id.
    function _closeAndGetRequest() internal returns (uint256) {
        vm.warp(jackpot.epochEnds());
        jackpot.closeEpoch();
        return coord.lastRequestId();
    }

    // ── Construction ─────────────────────────────────────────────────────────

    function test_constructor_state() public view {
        assertEq(address(jackpot.token()), address(token));
        assertEq(address(jackpot.coordinator()), address(coord));
        assertEq(jackpot.winnerBps(), WINNER_BPS);
        assertEq(jackpot.minBurn(), MIN_BURN);
        assertEq(jackpot.currentEpoch(), 1);
        assertEq(jackpot.epochEnds(), block.timestamp + DURATION);
        assertEq(jackpot.pot(), 1 ether);
        assertEq(jackpot.owner(), owner);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(GitlawbBurnJackpot.ZeroAddress.selector);
        new GitlawbBurnJackpot(address(0), address(coord), bytes32(0), 1, DURATION, WINNER_BPS, 0);
        vm.expectRevert(GitlawbBurnJackpot.ZeroAddress.selector);
        new GitlawbBurnJackpot(address(token), address(0), bytes32(0), 1, DURATION, WINNER_BPS, 0);
    }

    function test_constructor_rejectsBadBps() public {
        vm.expectRevert(GitlawbBurnJackpot.BadBps.selector);
        new GitlawbBurnJackpot(address(token), address(coord), bytes32(0), 1, DURATION, 0, 0);
        vm.expectRevert(GitlawbBurnJackpot.BadBps.selector);
        new GitlawbBurnJackpot(address(token), address(coord), bytes32(0), 1, DURATION, 10_001, 0);
    }

    // ── Entries ──────────────────────────────────────────────────────────────

    function test_burn_creditsTicketsAndBurnsTokens() public {
        _burn(alice, 500 ether);

        assertEq(token.balanceOf(BURN), 500 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(jackpot.ticketsOf(1, alice), 500 ether);
        assertEq(jackpot.totalTickets(1), 500 ether);
        assertEq(jackpot.entryCount(1), 1);
        assertEq(jackpot.totalBurnedForTickets(), 500 ether);
    }

    function test_burn_accumulatesAcrossBurnsAndBurners() public {
        _burn(alice, 100 ether);
        _burn(bob, 300 ether);
        _burn(alice, 200 ether);

        assertEq(jackpot.ticketsOf(1, alice), 300 ether);
        assertEq(jackpot.ticketsOf(1, bob), 300 ether);
        assertEq(jackpot.totalTickets(1), 600 ether);
        assertEq(jackpot.entryCount(1), 3);
    }

    function test_burn_belowMinReverts() public {
        token.mint(alice, MIN_BURN - 1);
        vm.prank(alice);
        token.approve(address(jackpot), MIN_BURN - 1);
        vm.prank(alice);
        vm.expectRevert(GitlawbBurnJackpot.BurnTooSmall.selector);
        jackpot.burnForTickets(MIN_BURN - 1);
    }

    function test_burn_whenPausedReverts() public {
        jackpot.setPaused(true);
        token.mint(alice, 500 ether);
        vm.prank(alice);
        token.approve(address(jackpot), 500 ether);
        vm.prank(alice);
        vm.expectRevert(GitlawbBurnJackpot.EntriesPaused.selector);
        jackpot.burnForTickets(500 ether);

        jackpot.setPaused(false);
        vm.prank(alice);
        jackpot.burnForTickets(500 ether);
        assertEq(jackpot.ticketsOf(1, alice), 500 ether);
    }

    // ── Epoch lifecycle ──────────────────────────────────────────────────────

    function test_closeEpoch_beforeDeadlineReverts() public {
        _burn(alice, 500 ether);
        vm.expectRevert(GitlawbBurnJackpot.EpochStillOpen.selector);
        jackpot.closeEpoch();
    }

    function test_closeEpoch_zeroEntriesRollsWithoutDraw() public {
        vm.warp(jackpot.epochEnds());
        jackpot.closeEpoch();

        assertEq(coord.requestCount(), 0);
        assertEq(jackpot.currentEpoch(), 2);
        assertEq(jackpot.epochEnds(), block.timestamp + DURATION);
        assertEq(jackpot.pot(), 1 ether); // pot untouched
    }

    function test_closeEpoch_requestsVrfAndOpensNextEpoch() public {
        _burn(alice, 500 ether);
        uint256 requestId = _closeAndGetRequest();

        assertEq(jackpot.pendingRequest(1), requestId);
        assertEq(jackpot.currentEpoch(), 2);
        assertEq(coord.lastSubId(), 42);
        assertEq(coord.lastNumWords(), 1);
        // Native-payment extraArgs: tag + bool true.
        assertEq(
            coord.lastExtraArgs(), abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true)
        );
    }

    function test_burn_afterDeadlineAutoClosesAndLandsInNewEpoch() public {
        _burn(alice, 500 ether);
        vm.warp(jackpot.epochEnds() + 1);
        _burn(bob, 300 ether);

        // Alice's epoch got its draw requested; Bob's burn opened epoch 2.
        assertEq(jackpot.pendingRequest(1), coord.lastRequestId());
        assertEq(jackpot.currentEpoch(), 2);
        assertEq(jackpot.ticketsOf(2, bob), 300 ether);
        assertEq(jackpot.ticketsOf(1, bob), 0);
    }

    // ── Draws ────────────────────────────────────────────────────────────────

    function test_draw_paysWinnerSplitAndRollsRemainder() public {
        _burn(alice, 500 ether);
        uint256 requestId = _closeAndGetRequest();

        coord.fulfill(address(jackpot), requestId, 12345);

        assertEq(jackpot.winnerOf(1), alice);
        assertEq(jackpot.prizeOf(1), 0.6 ether);
        assertEq(jackpot.claimable(alice), 0.6 ether);
        assertEq(jackpot.reserved(), 0.6 ether);
        assertEq(jackpot.pot(), 0.4 ether); // rollover
        assertEq(jackpot.pendingRequest(1), 0);
    }

    function test_draw_weightedSelection_boundaries() public {
        // alice covers tickets [0, 100e18), bob covers [100e18, 400e18).
        _burn(alice, 100 ether);
        _burn(bob, 300 ether);
        uint256 requestId = _closeAndGetRequest();

        // Snapshot so we can test both boundary words on identical state.
        uint256 snap = vm.snapshotState();

        coord.fulfill(address(jackpot), requestId, 100 ether - 1); // last alice ticket
        assertEq(jackpot.winnerOf(1), alice);

        vm.revertToState(snap);
        coord.fulfill(address(jackpot), requestId, 100 ether); // first bob ticket
        assertEq(jackpot.winnerOf(1), bob);

        vm.revertToState(snap);
        coord.fulfill(address(jackpot), requestId, 400 ether + 7); // modulo wraps → ticket 7
        assertEq(jackpot.winnerOf(1), alice);
    }

    function test_draw_fuzz_winnerIsAlwaysAnEntrant(uint256 word) public {
        _burn(alice, 100 ether);
        _burn(bob, 300 ether);
        _burn(carol, 250 ether);
        uint256 requestId = _closeAndGetRequest();

        coord.fulfill(address(jackpot), requestId, word);

        address winner = jackpot.winnerOf(1);
        assertTrue(winner == alice || winner == bob || winner == carol);
        assertEq(jackpot.claimable(winner), 0.6 ether);
    }

    function test_draw_onlyCoordinatorCanFulfill() public {
        _burn(alice, 500 ether);
        uint256 requestId = _closeAndGetRequest();

        uint256[] memory words = new uint256[](1);
        vm.prank(rando);
        vm.expectRevert(GitlawbBurnJackpot.NotCoordinator.selector);
        jackpot.rawFulfillRandomWords(requestId, words);
    }

    function test_draw_unknownRequestReverts() public {
        vm.expectRevert(GitlawbBurnJackpot.UnknownRequest.selector);
        coord.fulfill(address(jackpot), 999, 1);
    }

    function test_draw_cannotFulfillTwice() public {
        _burn(alice, 500 ether);
        uint256 requestId = _closeAndGetRequest();
        coord.fulfill(address(jackpot), requestId, 1);

        // Request id is deleted after settling, so a replay is unknown.
        vm.expectRevert(GitlawbBurnJackpot.UnknownRequest.selector);
        coord.fulfill(address(jackpot), requestId, 1);
    }

    function test_draw_concurrentPendingEpochsSettleIndependently() public {
        _burn(alice, 500 ether);
        vm.warp(jackpot.epochEnds());
        jackpot.closeEpoch();
        uint256 req1 = coord.lastRequestId();

        _burn(bob, 500 ether);
        vm.warp(jackpot.epochEnds());
        jackpot.closeEpoch();
        uint256 req2 = coord.lastRequestId();

        // Settle out of order: epoch 2 first.
        coord.fulfill(address(jackpot), req2, 0);
        assertEq(jackpot.winnerOf(2), bob);
        assertEq(jackpot.prizeOf(2), 0.6 ether);

        coord.fulfill(address(jackpot), req1, 0);
        assertEq(jackpot.winnerOf(1), alice);
        // Epoch 1 settled after epoch 2 took 0.6, so 60% of the 0.4 remainder.
        assertEq(jackpot.prizeOf(1), 0.24 ether);
    }

    // ── Retry ────────────────────────────────────────────────────────────────

    function test_retry_replacesStaleRequestSafely() public {
        _burn(alice, 500 ether);
        uint256 staleId = _closeAndGetRequest();

        vm.expectRevert(GitlawbBurnJackpot.RetryTooSoon.selector);
        jackpot.retryDraw(1);

        vm.warp(block.timestamp + jackpot.RETRY_DELAY());
        jackpot.retryDraw(1);
        uint256 freshId = coord.lastRequestId();
        assertTrue(freshId != staleId);

        // The stale request can no longer settle the epoch…
        vm.expectRevert(GitlawbBurnJackpot.UnknownRequest.selector);
        coord.fulfill(address(jackpot), staleId, 1);

        // …but the fresh one can.
        coord.fulfill(address(jackpot), freshId, 1);
        assertEq(jackpot.winnerOf(1), alice);
    }

    function test_retry_guards() public {
        vm.expectRevert(GitlawbBurnJackpot.NothingPending.selector);
        jackpot.retryDraw(1);

        _burn(alice, 500 ether);
        uint256 requestId = _closeAndGetRequest();

        vm.prank(rando);
        vm.expectRevert(GitlawbBurnJackpot.NotOwner.selector);
        jackpot.retryDraw(1);

        coord.fulfill(address(jackpot), requestId, 1);
        // pendingRequest is cleared once drawn.
        vm.expectRevert(GitlawbBurnJackpot.NothingPending.selector);
        jackpot.retryDraw(1);
    }

    // ── Claims & pot ─────────────────────────────────────────────────────────

    function test_claim_paysOutOnce() public {
        _burn(alice, 500 ether);
        uint256 requestId = _closeAndGetRequest();
        coord.fulfill(address(jackpot), requestId, 1);

        vm.prank(alice);
        jackpot.claim();
        assertEq(alice.balance, 0.6 ether);
        assertEq(jackpot.reserved(), 0);
        assertEq(jackpot.claimable(alice), 0);

        vm.prank(alice);
        vm.expectRevert(GitlawbBurnJackpot.NothingToClaim.selector);
        jackpot.claim();
    }

    function test_claim_nothingReverts() public {
        vm.prank(rando);
        vm.expectRevert(GitlawbBurnJackpot.NothingToClaim.selector);
        jackpot.claim();
    }

    function test_pot_excludesReservedPrizes() public {
        _burn(alice, 500 ether);
        uint256 requestId = _closeAndGetRequest();
        coord.fulfill(address(jackpot), requestId, 1);

        assertEq(address(jackpot).balance, 1 ether);
        assertEq(jackpot.pot(), 0.4 ether);
        assertEq(jackpot.previewPrize(), 0.24 ether);
    }

    function test_pot_growsFromDonationsAndCompounds() public {
        // Epoch 1: alice wins 0.6, pot rolls to 0.4.
        _burn(alice, 500 ether);
        coord.fulfill(address(jackpot), _closeAndGetRequest(), 1);

        // An anon tops up the pot mid-epoch via plain transfer.
        vm.deal(rando, 2 ether);
        vm.prank(rando);
        (bool ok,) = address(jackpot).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(jackpot.pot(), 2.4 ether);

        // Epoch 2: winner takes 60% of the compounded pot.
        _burn(bob, 500 ether);
        coord.fulfill(address(jackpot), _closeAndGetRequest(), 1);
        assertEq(jackpot.prizeOf(2), 1.44 ether);
    }

    function test_draw_withEmptyPotAwardsZero() public {
        // Fresh jackpot with no seed at all.
        GitlawbBurnJackpot dry = new GitlawbBurnJackpot(
            address(token), address(coord), bytes32("k"), 42, DURATION, WINNER_BPS, MIN_BURN
        );
        token.mint(alice, 500 ether);
        vm.startPrank(alice);
        token.approve(address(dry), 500 ether);
        dry.burnForTickets(500 ether);
        vm.stopPrank();

        vm.warp(dry.epochEnds());
        dry.closeEpoch();
        coord.fulfill(address(dry), coord.lastRequestId(), 1);

        assertEq(dry.winnerOf(1), alice);
        assertEq(dry.prizeOf(1), 0);
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function test_admin_onlyOwnerGuards() public {
        vm.startPrank(rando);
        vm.expectRevert(GitlawbBurnJackpot.NotOwner.selector);
        jackpot.setWinnerBps(5_000);
        vm.expectRevert(GitlawbBurnJackpot.NotOwner.selector);
        jackpot.setMinBurn(1);
        vm.expectRevert(GitlawbBurnJackpot.NotOwner.selector);
        jackpot.setVrfConfig(address(coord), bytes32(0), 1, 100_000);
        vm.expectRevert(GitlawbBurnJackpot.NotOwner.selector);
        jackpot.setPaused(true);
        vm.expectRevert(GitlawbBurnJackpot.NotOwner.selector);
        jackpot.transferOwnership(rando);
        vm.stopPrank();
    }

    function test_admin_setWinnerBpsBounds() public {
        vm.expectRevert(GitlawbBurnJackpot.BadBps.selector);
        jackpot.setWinnerBps(0);
        vm.expectRevert(GitlawbBurnJackpot.BadBps.selector);
        jackpot.setWinnerBps(10_001);

        jackpot.setWinnerBps(10_000);
        assertEq(jackpot.winnerBps(), 10_000);
    }

    function test_admin_setVrfConfig() public {
        jackpot.setVrfConfig(address(0xC0FFEE), bytes32("new"), 7, 500_000);
        assertEq(address(jackpot.coordinator()), address(0xC0FFEE));
        assertEq(jackpot.subId(), 7);
        assertEq(jackpot.callbackGasLimit(), 500_000);

        vm.expectRevert(GitlawbBurnJackpot.ZeroAddress.selector);
        jackpot.setVrfConfig(address(0), bytes32(0), 1, 100_000);
    }

    function test_admin_transferOwnership() public {
        jackpot.transferOwnership(alice);
        assertEq(jackpot.owner(), alice);
        vm.expectRevert(GitlawbBurnJackpot.NotOwner.selector);
        jackpot.setPaused(true);
    }
}
