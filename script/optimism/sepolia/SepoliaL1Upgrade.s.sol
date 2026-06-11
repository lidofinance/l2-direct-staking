// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {L1UpgradeActions} from "script/l1/L1UpgradeActions.s.sol";
import {SepoliaMigrationConstants as C} from "script/optimism/sepolia/SepoliaMigrationConstants.sol";

/**
 * @notice Sepolia testnet L1 upgrade script.
 * @dev Reuses L1UpgradeActions.execute() but builds config from env vars.
 *
 * Required env:
 * - L1_LIDO_CUSTOM_RECEIVER  (deployed receiver proxy on Sepolia L1)
 * - L1_PROXY_ADMIN           (deployed ProxyAdmin on Sepolia L1)
 * - INITIAL_OWNER_PRIVATE_KEY
 * - LIDO_DAO_AGENT            (new admin address)
 */
contract SepoliaL1UpgradeScript is Script, L1UpgradeActions {
    function sepoliaL1Config(address initialOwner, address lidoDaoAgent)
        public
        view
        returns (L1UpgradeConfig memory cfg)
    {
        cfg = L1UpgradeConfig({
            initialOwner: initialOwner,
            lidoDaoAgent: lidoDaoAgent,
            receiverProxy: vm.envAddress("L1_LIDO_CUSTOM_RECEIVER"),
            proxyAdmin: vm.envAddress("L1_PROXY_ADMIN")
        });
    }

    function run() external {
        assertL1ChainId(C.ETH_CHAIN_ID);

        uint256 initialOwnerPrivateKey = vm.envUint("INITIAL_OWNER_PRIVATE_KEY");
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        address lidoDaoAgent = vm.envAddress("LIDO_DAO_AGENT");

        L1UpgradeConfig memory cfg = sepoliaL1Config(initialOwner, lidoDaoAgent);

        vm.startBroadcast(initialOwnerPrivateKey);
        execute(cfg);
        vm.stopBroadcast();
    }
}
