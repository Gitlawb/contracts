// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GitlawbBuybackVault.sol";
import "./MockERC20.sol";

contract GitlawbBuybackVaultTest is Test {
    GitlawbBuybackVault public vault;
    MockERC20 public token;

    address constant BURN = 0x000000000000000000000000000000000000dEaD;
    address owner = address(this);
    address sink = address(0x5151);
    address bot = address(0xB07);
    address keeper = address(0x1EE1);

    function setUp() public {
        token = new MockERC20();
        // v0 config: 100% burn, no sink.
        vault = new GitlawbBuybackVault(address(token), address(0), 10_000);
    }

    function _fund(uint256 amount) internal {
        token.mint(bot, amount);
        vm.prank(bot);
        token.transfer(address(vault), amount);
    }

    // ── Construction ───────────────────────────────────────────────────────

    function test_constructor_defaults() public view {
        assertEq(address(vault.token()), address(token));
        assertEq(vault.burnBps(), 10_000);
        assertEq(vault.sink(), address(0));
        assertEq(vault.owner(), owner);
    }

    function test_constructor_rejectsZeroToken() public {
        vm.expectRevert(GitlawbBuybackVault.ZeroAddress.selector);
        new GitlawbBuybackVault(address(0), sink, 5_000);
    }

    function test_constructor_rejectsBpsAboveMax() public {
        vm.expectRevert(GitlawbBuybackVault.BadBps.selector);
        new GitlawbBuybackVault(address(token), sink, 10_001);
    }

    function test_constructor_partialBurnRequiresSink() public {
        vm.expectRevert(GitlawbBuybackVault.SinkRequired.selector);
        new GitlawbBuybackVault(address(token), address(0), 5_000);
    }

    // ── 100% burn (v0) ───────────────────────────────────────────────────────

    function test_flush_burnsEverything() public {
        _fund(1_000 ether);

        vm.prank(keeper); // permissionless
        vault.flush();

        assertEq(token.balanceOf(BURN), 1_000 ether);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.totalBurned(), 1_000 ether);
        assertEq(vault.totalForwarded(), 0);
        assertEq(vault.totalProcessed(), 1_000 ether);
        assertEq(vault.flushCount(), 1);
    }

    function test_flush_emitsEvent() public {
        _fund(500 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit GitlawbBuybackVault.Flushed(1, 500 ether, 500 ether, 0);
        vault.flush();
    }

    function test_flush_revertsWhenEmpty() public {
        vm.expectRevert(GitlawbBuybackVault.NothingToFlush.selector);
        vault.flush();
    }

    function test_flush_accumulatesAcrossCalls() public {
        _fund(100 ether);
        vault.flush();
        _fund(250 ether);
        vault.flush();
        assertEq(vault.flushCount(), 2);
        assertEq(vault.totalBurned(), 350 ether);
        assertEq(token.balanceOf(BURN), 350 ether);
    }

    // ── Partial burn (post-audit config) ──────────────────────────────────────

    function test_flush_partialSplit() public {
        vault.setSink(sink);
        vault.setBurnBps(5_000); // 50/50
        _fund(1_000 ether);

        vault.flush();

        assertEq(token.balanceOf(BURN), 500 ether);
        assertEq(token.balanceOf(sink), 500 ether);
        assertEq(vault.totalBurned(), 500 ether);
        assertEq(vault.totalForwarded(), 500 ether);
    }

    function test_flush_remainderTakesDust() public {
        vault.setSink(sink);
        vault.setBurnBps(3_333); // 33.33% — leaves rounding dust
        _fund(10_000 ether + 1); // odd amount

        uint256 total = 10_000 ether + 1;
        uint256 expectedBurn = (total * 3_333) / 10_000;
        vault.flush();

        assertEq(token.balanceOf(BURN), expectedBurn);
        assertEq(token.balanceOf(sink), total - expectedBurn);
        // Nothing stranded.
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_flush_zeroForwardWhenFullBurnAfterSinkSet() public {
        vault.setSink(sink);
        // still 100% burn
        _fund(100 ether);
        vault.flush();
        assertEq(token.balanceOf(sink), 0);
        assertEq(token.balanceOf(BURN), 100 ether);
    }

    function test_previewFlush() public {
        vault.setSink(sink);
        vault.setBurnBps(7_000);
        _fund(1_000 ether);
        (uint256 total, uint256 burnAmt, uint256 fwdAmt) = vault.previewFlush();
        assertEq(total, 1_000 ether);
        assertEq(burnAmt, 700 ether);
        assertEq(fwdAmt, 300 ether);
    }

    // ── Admin / access control ─────────────────────────────────────────────

    function test_setBurnBps_onlyOwner() public {
        vm.prank(bot);
        vm.expectRevert(GitlawbBuybackVault.NotOwner.selector);
        vault.setBurnBps(5_000);
    }

    function test_setBurnBps_partialRequiresSink() public {
        vm.expectRevert(GitlawbBuybackVault.SinkRequired.selector);
        vault.setBurnBps(4_000); // no sink set
    }

    function test_setSink_onlyOwner() public {
        vm.prank(bot);
        vm.expectRevert(GitlawbBuybackVault.NotOwner.selector);
        vault.setSink(sink);
    }

    function test_setSink_cannotClearWhilePartialBurn() public {
        vault.setSink(sink);
        vault.setBurnBps(5_000);
        vm.expectRevert(GitlawbBuybackVault.SinkRequired.selector);
        vault.setSink(address(0));
    }

    function test_transferOwnership() public {
        vault.transferOwnership(bot);
        assertEq(vault.owner(), bot);
        vm.prank(owner);
        vm.expectRevert(GitlawbBuybackVault.NotOwner.selector);
        vault.setBurnBps(10_000);
    }

    function test_transferOwnership_rejectsZero() public {
        vm.expectRevert(GitlawbBuybackVault.ZeroAddress.selector);
        vault.transferOwnership(address(0));
    }

    function testFuzz_flushSplitConserves(uint96 amount, uint16 bps) public {
        bps = uint16(bound(bps, 0, 10_000));
        vm.assume(amount > 0);
        if (bps < 10_000) {
            vault.setSink(sink);
        }
        vault.setBurnBps(bps);
        _fund(amount);

        vault.flush();

        // Every token is either burned or forwarded — none stranded.
        assertEq(token.balanceOf(BURN) + token.balanceOf(sink), amount);
        assertEq(token.balanceOf(address(vault)), 0);
    }
}
