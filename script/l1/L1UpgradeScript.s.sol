// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {L1UpgradeActions} from "script/l1/L1UpgradeActions.s.sol";
import {L1MigrationConstants as L1} from "script/l1/L1MigrationConstants.sol";

/**
 * @notice Broadcast script for L1 admin migration. Runs ONCE — the L1
 *         LidoCustomReceiver is shared across all four L2 lanes.
 *         Actor: Initial Owner.
 *
 * Migrates L1 Receiver admin and ProxyAdmin ownership to Lido DAO Agent.
 *
 * Required env:
 * - INITIAL_OWNER_PRIVATE_KEY (or L1_INITIAL_OWNER_PRIVATE_KEY)
 *
 * The Lido DAO Agent recipient is the fixed mainnet L1MigrationConstants.LIDO_DAO_AGENT constant
 * (cross-checked to the lidoDaoAgent .inputs.yaml anchor by verify-constants-sync) — never read from env.
 */
contract L1UpgradeScript is Script, L1UpgradeActions {
    function _envInitialOwnerPrivateKey() internal view returns (uint256) {
        try vm.envUint("INITIAL_OWNER_PRIVATE_KEY") returns (uint256 value) {
            return value;
        } catch {
            return vm.envUint("L1_INITIAL_OWNER_PRIVATE_KEY");
        }
    }

    function run() external {
        assertL1ChainId(L1.ETH_CHAIN_ID);

        uint256 initialOwnerPrivateKey = _envInitialOwnerPrivateKey();
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        // The DAO Agent is the fixed mainnet constant (verify-constants-sync'd), not an operator input,
        // so the irreversible admin/ProxyAdmin handover can never target a wrong env-supplied address.
        address lidoDaoAgent = L1.LIDO_DAO_AGENT;

        L1UpgradeConfig memory cfg = defaultL1Config(initialOwner, lidoDaoAgent);

        vm.startBroadcast(initialOwnerPrivateKey);
        execute(cfg);
        vm.stopBroadcast();
    }
}
