// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {L1UpgradeActions} from "script/shared/L1UpgradeActions.s.sol";

/**
 * @notice Shared broadcast script for L1 upgrade operations.
 *         Actor: Initial Owner.
 *
 * Migrates L1 Receiver admin and ProxyAdmin ownership to Lido DAO Agent.
 * The L1 receiver is shared across all L2 networks, so this only needs
 * to run if L1 admin migration hasn't already been done via another network.
 *
 * Required env:
 * - INITIAL_OWNER_PRIVATE_KEY (or L1_INITIAL_OWNER_PRIVATE_KEY)
 * - LIDO_DAO_AGENT (or LIDO_NEW_OWNER)
 */
abstract contract L1UpgradeScriptBase is Script, L1UpgradeActions {
    function _envInitialOwnerPrivateKey() internal view returns (uint256) {
        try vm.envUint("INITIAL_OWNER_PRIVATE_KEY") returns (uint256 value) {
            return value;
        } catch {
            return vm.envUint("L1_INITIAL_OWNER_PRIVATE_KEY");
        }
    }

    function _envLidoDaoAgent() internal view returns (address) {
        try vm.envAddress("LIDO_DAO_AGENT") returns (address value) {
            return value;
        } catch {
            return vm.envAddress("LIDO_NEW_OWNER");
        }
    }

    function run() external {
        uint256 initialOwnerPrivateKey = _envInitialOwnerPrivateKey();
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        address lidoDaoAgent = _envLidoDaoAgent();

        L1UpgradeConfig memory cfg = defaultL1Config(initialOwner, lidoDaoAgent);

        vm.startBroadcast(initialOwnerPrivateKey);
        execute(cfg);
        vm.stopBroadcast();
    }
}
