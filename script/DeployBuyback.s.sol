// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/GitlawbBuybackVault.sol";

/// @notice Deploy the GitlawbBuybackVault standalone.
///
/// This contract does NOT touch the audit-gated staking stack — it only
/// receives bought-back $GITLAWB and burns it — so it can ship to Base mainnet
/// immediately, ahead of the FeeDistributor/Staking external audit.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY  — EOA that pays gas + becomes initial owner
///   GITLAWB_TOKEN         — $GITLAWB ERC20 (0x5F980Dcfc4c0fa3911554cf5ab288ed0eb13DBa3 on Base)
///
/// Optional:
///   BUYBACK_SINK          — remainder destination (default address(0) = 100% burn v0)
///   BUYBACK_BURN_BPS      — burn portion in bps (default 10000 = 100%)
///
/// Usage (Base mainnet):
///   forge script script/DeployBuyback.s.sol \
///     --rpc-url https://mainnet.base.org \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --verify --etherscan-api-key $BASESCAN_API_KEY
contract DeployBuyback is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address token = vm.envAddress("GITLAWB_TOKEN");
        address sink = vm.envOr("BUYBACK_SINK", address(0));
        uint256 burnBps = vm.envOr("BUYBACK_BURN_BPS", uint256(10_000));

        console.log("Deploying from:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("$GITLAWB token:", token);
        console.log("Sink:", sink);
        console.log("Burn bps:", burnBps);
        require(token != address(0), "GITLAWB_TOKEN unset");

        vm.startBroadcast(deployerKey);
        GitlawbBuybackVault vault = new GitlawbBuybackVault(token, sink, burnBps);
        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployed ===");
        console.log("GitlawbBuybackVault:", address(vault));
        console.log("");
        console.log("# Point the buyback bot at it:");
        console.log("BUYBACK_VAULT=%s", vm.toString(address(vault)));
    }
}
