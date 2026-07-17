// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

/// @title GitlawbBuybackVault
/// @notice On-chain split point for $GITLAWB bought back from protocol revenue.
///
/// The buyback bot market-buys $GITLAWB on Uniswap with USDC collected from
/// protocol revenue (x402 OpenGateway top-ups first), then sends the bought
/// tokens here and calls `flush()`. Each flush splits the full balance:
///
///   burnBps      → 0x…dEaD  (deflation; counted by gitlawb.com/burners)
///   remainder    → sink      (treasury now; FeeDistributor after audit)
///
/// Why a contract instead of letting the bot split directly: the ratio is
/// enforced on-chain and every flush emits an event, so the burn/forward
/// behaviour is publicly auditable and the bot only decides *when* to buy,
/// never how much to burn. There is deliberately NO DEX interaction here — the
/// swap lives off-chain — so this contract stays trivial and audit-free.
///
/// v0 launches at burnBps == 10_000 (100% burn), with sink unset.
contract GitlawbBuybackVault {
    // ── Storage ──────────────────────────────────────────────────────────────

    IERC20 public immutable token;
    address public owner;

    /// Destination for the non-burned remainder. May be address(0) only while
    /// burnBps == MAX_BPS (a 100% burn needs no sink).
    address public sink;

    /// Portion of each flush sent to the burn address, in basis points.
    uint256 public burnBps;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_BPS = 10_000;

    // Lifetime accounting (for the public flywheel dashboard)
    uint256 public totalProcessed;
    uint256 public totalBurned;
    uint256 public totalForwarded;
    uint256 public flushCount;

    // ── Events ───────────────────────────────────────────────────────────────

    event Flushed(uint256 indexed seq, uint256 total, uint256 burned, uint256 forwarded);
    event BurnBpsUpdated(uint256 burnBps);
    event SinkUpdated(address sink);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ── Errors ───────────────────────────────────────────────────────────────

    error NotOwner();
    error ZeroAddress();
    error BadBps();
    error NothingToFlush();
    error TransferFailed();
    error SinkRequired();

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address _token, address _sink, uint256 _burnBps) {
        if (_token == address(0)) revert ZeroAddress();
        if (_burnBps > MAX_BPS) revert BadBps();
        // A partial burn must have somewhere to send the remainder.
        if (_burnBps < MAX_BPS && _sink == address(0)) revert SinkRequired();
        token = IERC20(_token);
        sink = _sink;
        burnBps = _burnBps;
        owner = msg.sender;
    }

    // ── Core ─────────────────────────────────────────────────────────────────

    /// Permissionless. Splits the contract's full $GITLAWB balance per burnBps:
    /// burns burnBps, forwards the rest to `sink`.
    function flush() external {
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) revert NothingToFlush();

        uint256 burnAmt = (bal * burnBps) / MAX_BPS;
        // Remainder takes the rounding dust so nothing is stranded.
        uint256 fwdAmt = bal - burnAmt;

        flushCount += 1;
        totalProcessed += bal;

        if (burnAmt > 0) {
            totalBurned += burnAmt;
            if (!token.transfer(BURN_ADDRESS, burnAmt)) revert TransferFailed();
        }

        if (fwdAmt > 0) {
            address dest = sink;
            if (dest == address(0)) revert SinkRequired();
            totalForwarded += fwdAmt;
            if (!token.transfer(dest, fwdAmt)) revert TransferFailed();
        }

        emit Flushed(flushCount, bal, burnAmt, fwdAmt);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function pendingBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// Preview how the current balance would split without executing.
    function previewFlush() external view returns (uint256 total, uint256 burnAmt, uint256 fwdAmt) {
        total = token.balanceOf(address(this));
        burnAmt = (total * burnBps) / MAX_BPS;
        fwdAmt = total - burnAmt;
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    /// Adjust the burn ratio. Lowering below 100% requires a sink to be set.
    function setBurnBps(uint256 _burnBps) external {
        if (msg.sender != owner) revert NotOwner();
        if (_burnBps > MAX_BPS) revert BadBps();
        if (_burnBps < MAX_BPS && sink == address(0)) revert SinkRequired();
        burnBps = _burnBps;
        emit BurnBpsUpdated(_burnBps);
    }

    /// Set the remainder destination. May be cleared to address(0) only while
    /// burnBps == MAX_BPS (otherwise flush would have nowhere to send).
    function setSink(address _sink) external {
        if (msg.sender != owner) revert NotOwner();
        if (_sink == address(0) && burnBps < MAX_BPS) revert SinkRequired();
        sink = _sink;
        emit SinkUpdated(_sink);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
