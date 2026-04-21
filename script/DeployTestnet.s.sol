// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/GitlawbTestToken.sol";
import "../src/GitlawbDIDRegistry.sol";
import "../src/GitlawbNameRegistry.sol";
import "../src/GitlawbBounty.sol";
import "../src/GitlawbStaking.sol";
import "../src/GitlawbNodeStaking.sol";
import "../src/GitlawbFeeDistributor.sol";

/// @notice One-shot testnet deploy for Base Sepolia.
///
/// Deploys:
///   - GitlawbTestToken (test $GITLAWB, public mint)
///   - All 6 protocol contracts, wired together
///   - Mints 10,000,000 tGITLAWB to the deployer for testing
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY — EOA that pays gas + becomes owner
///
/// Usage:
///   forge script script/DeployTestnet.s.sol \
///     --rpc-url https://sepolia.base.org \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY
contract DeployTestnet is Script {
    function run() external {
        console.log("=== gitlawb testnet deploy ===");
        console.log("Chain ID:", block.chainid);
        require(block.chainid != 8453, "DeployTestnet must not run on Base mainnet");

        // Uses --private-key from forge CLI flag
        vm.startBroadcast();
        address deployer = msg.sender;
        console.log("Deployer:", deployer);

        // 0. Test token
        GitlawbTestToken token = new GitlawbTestToken();
        token.mint(deployer, 10_000_000 * 1e18);

        // 1+2. Registries
        GitlawbDIDRegistry didRegistry = new GitlawbDIDRegistry();
        GitlawbNameRegistry nameRegistry = new GitlawbNameRegistry();

        // 3. User staking
        GitlawbStaking userStaking = new GitlawbStaking(address(token));

        // 4. Node operator staking
        GitlawbNodeStaking nodeStaking = new GitlawbNodeStaking(address(token));

        // 5. Fee distributor (reward wallet)
        GitlawbFeeDistributor feeDistributor = new GitlawbFeeDistributor(
            address(token),
            address(nodeStaking),
            address(userStaking)
        );

        // 6. Bounty with treasury = feeDistributor
        GitlawbBounty bounty = new GitlawbBounty(address(token), address(feeDistributor));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployed on Base Sepolia ===");
        console.log("GitlawbTestToken:     ", address(token));
        console.log("GitlawbDIDRegistry:   ", address(didRegistry));
        console.log("GitlawbNameRegistry:  ", address(nameRegistry));
        console.log("GitlawbStaking:       ", address(userStaking));
        console.log("GitlawbNodeStaking:   ", address(nodeStaking));
        console.log("GitlawbFeeDistributor:", address(feeDistributor));
        console.log("GitlawbBounty:        ", address(bounty));
        console.log("");
        console.log("=== Export these for the CLI/node ===");
        console.log("export GITLAWB_CHAIN_RPC_URL=https://sepolia.base.org");
        console.log("export GITLAWB_TOKEN=%s", vm.toString(address(token)));
        console.log("export GITLAWB_CONTRACT_NODE_STAKING=%s", vm.toString(address(nodeStaking)));
        console.log("export GITLAWB_CONTRACT_DID_REGISTRY=%s", vm.toString(address(didRegistry)));
        console.log("export GITLAWB_CONTRACT_NAME_REGISTRY=%s", vm.toString(address(nameRegistry)));
        console.log("");
        console.log("Deployer was minted 10,000,000 tGITLAWB.");
        console.log("Anyone can mint more via: cast send <token> 'mint(address,uint256)' <addr> <amount>");
    }
}
