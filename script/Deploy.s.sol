// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/GitlawbDIDRegistry.sol";
import "../src/GitlawbNameRegistry.sol";
import "../src/GitlawbBounty.sol";
import "../src/GitlawbStaking.sol";
import "../src/GitlawbNodeStaking.sol";
import "../src/GitlawbFeeDistributor.sol";

/// @notice Deploy the full gitlawb on-chain stack.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY  — EOA that pays gas + becomes initial owner
///   GITLAWB_TOKEN         — $GITLAWB ERC20 address (e.g. 0x5F98...DBa3 on Base)
///
/// Usage (Base Sepolia):
///   forge script script/Deploy.s.sol \
///     --rpc-url https://sepolia.base.org \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --verify \
///     --etherscan-api-key $BASESCAN_API_KEY
///
/// Deploys in this order and wires them together:
///   1. DIDRegistry
///   2. NameRegistry
///   3. GitlawbStaking (user staking, tier-based)
///   4. GitlawbNodeStaking (PoS operator staking)
///   5. GitlawbFeeDistributor (reward wallet — weekly distribution)
///   6. GitlawbBounty (treasury set to FeeDistributor so fees auto-flow)
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address token = vm.envAddress("GITLAWB_TOKEN");

        console.log("Deploying from:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("$GITLAWB token:", token);
        require(token != address(0), "GITLAWB_TOKEN unset");

        vm.startBroadcast(deployerKey);

        // 1+2. Registries
        GitlawbDIDRegistry didRegistry = new GitlawbDIDRegistry();
        GitlawbNameRegistry nameRegistry = new GitlawbNameRegistry();

        // 3. User staking (tier-based, passive)
        GitlawbStaking userStaking = new GitlawbStaking(token);

        // 4. Node operator staking (PoS, uptime-gated)
        GitlawbNodeStaking nodeStaking = new GitlawbNodeStaking(token);

        // 5. Fee distributor — the protocol reward wallet.
        //    Fees from bounties and other services land here; anyone can call
        //    distribute() once per week to split 75/24/1 node/user/keeper.
        GitlawbFeeDistributor feeDistributor = new GitlawbFeeDistributor(
            token,
            address(nodeStaking),
            address(userStaking)
        );

        // 6. Bounty contract — treasury set to the fee distributor so protocol
        //    fees (5% of each completed bounty) flow straight into the reward
        //    pool. No manual withdraw step required.
        GitlawbBounty bounty = new GitlawbBounty(token, address(feeDistributor));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployed ===");
        console.log("GitlawbDIDRegistry:   ", address(didRegistry));
        console.log("GitlawbNameRegistry:  ", address(nameRegistry));
        console.log("GitlawbStaking:       ", address(userStaking));
        console.log("GitlawbNodeStaking:   ", address(nodeStaking));
        console.log("GitlawbFeeDistributor:", address(feeDistributor));
        console.log("GitlawbBounty:        ", address(bounty));

        console.log("");
        console.log("# Set on Fly nodes:");
        console.log("fly secrets set GITLAWB_CONTRACT_DID_REGISTRY=%s --app gitlawb-node", vm.toString(address(didRegistry)));
        console.log("fly secrets set GITLAWB_CONTRACT_NAME_REGISTRY=%s --app gitlawb-node", vm.toString(address(nameRegistry)));
        console.log("fly secrets set GITLAWB_CONTRACT_BOUNTY=%s --app gitlawb-node", vm.toString(address(bounty)));
        console.log("fly secrets set GITLAWB_CONTRACT_STAKING=%s --app gitlawb-node", vm.toString(address(userStaking)));
        console.log("fly secrets set GITLAWB_CONTRACT_NODE_STAKING=%s --app gitlawb-node", vm.toString(address(nodeStaking)));
        console.log("fly secrets set GITLAWB_CONTRACT_FEE_DISTRIBUTOR=%s --app gitlawb-node", vm.toString(address(feeDistributor)));
    }
}
