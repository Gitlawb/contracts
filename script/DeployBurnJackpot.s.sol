// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/GitlawbBurnJackpot.sol";

/// @notice Deploy the GitlawbBurnJackpot standalone.
///
/// Like the BuybackVault, this does NOT touch the audit-gated staking stack —
/// it burns tokens and pays ETH prizes via Chainlink VRF, nothing else — so it
/// can ship ahead of the external audit. The pot has no owner withdrawal.
///
/// Before deploying, create a VRF v2.5 subscription at https://vrf.chain.link
/// (Base), fund it with ETH (native payment — no LINK needed), and put its id
/// in VRF_SUB_ID. AFTER deploying, add the jackpot address as a consumer on
/// that subscription, then seed the pot:
///   cast send <jackpot> "seedPot()" --value 1ether \
///     --rpc-url https://mainnet.base.org --private-key $DEPLOYER_PRIVATE_KEY
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY — EOA that pays gas + becomes initial owner
///   VRF_SUB_ID           — VRF v2.5 subscription id (uint256)
///
/// Optional (defaults are Base mainnet launch config):
///   GITLAWB_TOKEN        — default 0x5F980Dcfc4c0fa3911554cf5ab288ed0eb13DBa3
///   VRF_COORDINATOR      — default 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634 (Base mainnet v2.5)
///   VRF_KEY_HASH         — default 30 gwei lane; use the 2 gwei lane
///                          (0x00b81b5a…ccab) to cap fulfilment gas cheaper
///   EPOCH_DURATION       — seconds per epoch (default 604800 = 7 days)
///   WINNER_BPS           — winner's share per draw (default 6000 = 60%)
///   MIN_BURN             — smallest ticket-earning burn in wei (default 1000 $GITLAWB)
///
/// Usage (Base mainnet):
///   forge script script/DeployBurnJackpot.s.sol \
///     --rpc-url https://mainnet.base.org \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --verify --etherscan-api-key $BASESCAN_API_KEY
contract DeployBurnJackpot is Script {
    address constant BASE_GITLAWB = 0x5F980Dcfc4c0fa3911554cf5ab288ed0eb13DBa3;
    address constant BASE_VRF_COORDINATOR = 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;
    bytes32 constant BASE_KEY_HASH_30_GWEI =
        0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address token = vm.envOr("GITLAWB_TOKEN", BASE_GITLAWB);
        address coordinator = vm.envOr("VRF_COORDINATOR", BASE_VRF_COORDINATOR);
        bytes32 keyHash = vm.envOr("VRF_KEY_HASH", BASE_KEY_HASH_30_GWEI);
        uint256 subId = vm.envUint("VRF_SUB_ID");
        uint256 epochDuration = vm.envOr("EPOCH_DURATION", uint256(7 days));
        uint256 winnerBps = vm.envOr("WINNER_BPS", uint256(6_000));
        uint256 minBurn = vm.envOr("MIN_BURN", uint256(1_000 ether));

        console.log("Deploying from:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("$GITLAWB token:", token);
        console.log("VRF coordinator:", coordinator);
        console.log("VRF sub id:", subId);
        console.log("Epoch duration (s):", epochDuration);
        console.log("Winner bps:", winnerBps);
        console.log("Min burn (wei):", minBurn);
        require(subId != 0, "VRF_SUB_ID unset");

        vm.startBroadcast(deployerKey);
        GitlawbBurnJackpot jackpot =
            new GitlawbBurnJackpot(token, coordinator, keyHash, subId, epochDuration, winnerBps, minBurn);
        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployed ===");
        console.log("GitlawbBurnJackpot:", address(jackpot));
        console.log("");
        console.log("# Next steps:");
        console.log("# 1. Add as consumer on VRF sub %s at vrf.chain.link", vm.toString(subId));
        console.log("# 2. Seed the pot:");
        console.log("#    cast send %s 'seedPot()' --value 1ether", vm.toString(address(jackpot)));
        console.log("# 3. Weekly keeper (only needed for zero-burn weeks; any burn auto-closes):");
        console.log("#    cast send %s 'closeEpoch()'", vm.toString(address(jackpot)));
    }
}
