// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Minimal EIP-2612 permit surface — lets a burn be a single transaction on
/// tokens that support it (no separate approve). Vendored so the repo stays
/// dependency-free (forge-std only).
interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @title Incinerator
/// @notice Routes ERC-20 burns to 0x…dEaD and emits an attributed `Incinerated`
/// event. robinincinerator credits embers, leaderboard position, and raffle
/// tickets ONLY to burns that pass through here — a raw `transfer(0xdEaD, …)` is
/// indistinguishable on-chain from an app burn, so the contract is the only way
/// to prove a burn was made through the app. Raw burns still show in the global
/// feed; they just don't earn.
///
/// Mechanics:
///   - Tokens move straight from the burner to 0x…dEaD via `transferFrom`; the
///     contract never holds them. The authoritative amount burned is the
///     token's own `Transfer(_, 0xdEaD, _)` log — the indexer reads that and
///     uses `Incinerated` only for attribution (burner + referrer), so
///     fee-on-transfer tokens are accounted correctly without extra on-chain
///     bookkeeping.
///   - `referrer` is recorded on-chain for the app's referral rewards. A
///     self-referral is zeroed so it can't be gamed at the contract layer;
///     reward caps/anti-farming live in the app's indexer.
///   - `incinerateWithPermit` folds the approval into the same tx for
///     permit-enabled tokens; a failing/absent permit is ignored so a
///     pre-approved or non-permit token still burns.
///
/// Trust properties, deliberately:
///   - No owner, no admin, no upgradeability, no pause.
///   - No custody: the contract holds no tokens and no ETH. It has no payable
///     function, so ETH sent to it reverts.
///   - Reentrancy is harmless: nothing is stored or paid out, so a hostile
///     token that re-enters only burns more of the caller's own tokens.
contract Incinerator {
    /// Standard EVM burn address — tokens sent here are unspendable.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @param burner    The address whose tokens were burned (the attributed user).
    /// @param token     The ERC-20 that was incinerated.
    /// @param amount    Amount requested to burn (authoritative value = the
    ///                  token's own Transfer log; equal here for normal tokens).
    /// @param referrer  Who referred this burner (address(0) if none).
    /// @param timestamp Block timestamp of the burn.
    event Incinerated(
        address indexed burner,
        address indexed token,
        uint256 amount,
        address indexed referrer,
        uint256 timestamp
    );

    error ZeroAmount();
    error TransferFailed();

    /// @notice Burn `amount` of `token` to 0x…dEaD, attributed to msg.sender.
    /// Requires the caller to have approved this contract for `amount` first
    /// (or use `incinerateWithPermit`).
    function incinerate(address token, uint256 amount, address referrer) public {
        if (amount == 0) revert ZeroAmount();
        address ref = referrer == msg.sender ? address(0) : referrer;
        _safeTransferFrom(token, msg.sender, DEAD, amount);
        emit Incinerated(msg.sender, token, amount, ref, block.timestamp);
    }

    /// @notice One-transaction burn for EIP-2612 tokens: permit then burn.
    /// A reverting or unsupported permit is swallowed, so pre-approved or
    /// non-permit tokens still burn (the `transferFrom` will enforce allowance).
    function incinerateWithPermit(
        address token,
        uint256 amount,
        address referrer,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        try IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, v, r, s) {}
        catch {}
        incinerate(token, amount, referrer);
    }

    /// @dev transferFrom that tolerates non-standard ERC-20s (USDT-style tokens
    /// that return no value): success if the call succeeds AND either returns
    /// nothing or returns true.
    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount)); // transferFrom(address,address,uint256)
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
