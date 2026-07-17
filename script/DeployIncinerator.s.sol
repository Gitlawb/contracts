// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/Incinerator.sol";

/// @notice Deploy the Incinerator (attributed-burn router for robinincinerator).
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY — EOA that pays gas (contract has no owner/admin)
///
/// Robinhood TESTNET (46630) — do this first:
///   forge script script/DeployIncinerator.s.sol \
///     --rpc-url https://rpc.testnet.chain.robinhood.com/rpc \
///     --broadcast --private-key $DEPLOYER_PRIVATE_KEY
///
/// Robinhood MAINNET (4663) — after the testnet dry-run passes:
///   forge script script/DeployIncinerator.s.sol \
///     --rpc-url https://rpc.mainnet.chain.robinhood.com \
///     --broadcast --private-key $DEPLOYER_PRIVATE_KEY
///
/// The contract has no constructor args and no owner — the deployer only pays
/// gas. Record the printed address as NEXT_PUBLIC_INCINERATOR_ADDRESS in the app.
contract DeployIncinerator is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        Incinerator inc = new Incinerator();
        vm.stopBroadcast();
        console2.log("Incinerator deployed at:", address(inc));
        console2.log("Set NEXT_PUBLIC_INCINERATOR_ADDRESS to the above.");
    }
}
