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
 * - INITIAL_OWNER_PRIVATE_KEY (or L1_INITIAL_OWNER_PRIVATE_KEY) for {run}
 * - For anvil dress rehearsal use {runUnlocked} (no key; set INITIAL_OWNER / L1_INITIAL_OWNER or
 *   accept the L1MigrationConstants.INITIAL_OWNER default) with `--unlocked --sender`.
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

    function _envInitialOwnerAddress() internal view returns (address) {
        try vm.envAddress("INITIAL_OWNER") returns (address value) {
            return value;
        } catch {
            return vm.envOr("L1_INITIAL_OWNER", L1.INITIAL_OWNER);
        }
    }

    function run() external {
        uint256 key = _envInitialOwnerPrivateKey();
        _runBody(vm.addr(key), key);
    }

    /// @notice Same as {run} but impersonates the Initial Owner (anvil dress rehearsal only).
    function runUnlocked() external {
        _runBody(_envInitialOwnerAddress(), 0);
    }

    /// @dev One body for both entry points (key == 0 ⇒ impersonate), so the dress rehearsal cannot
    ///      drift from the irreversible broadcast it is supposed to prove.
    function _runBody(address initialOwner, uint256 key) internal {
        assertL1ChainId(L1.ETH_CHAIN_ID);

        // The DAO Agent is the fixed mainnet constant (verify-constants-sync'd), not an operator input,
        // so the irreversible admin/ProxyAdmin handover can never target a wrong env-supplied address.
        L1UpgradeConfig memory cfg = defaultL1Config(initialOwner, L1.LIDO_DAO_AGENT);

        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast(initialOwner);
        execute(cfg);
        vm.stopBroadcast();
    }
}
