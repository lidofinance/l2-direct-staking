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
 * - LIDO_DAO_AGENT (or LIDO_NEW_OWNER)
 */
contract L1UpgradeScript is Script, L1UpgradeActions {
    function _envInitialOwnerPrivateKey() internal view returns (uint256) {
        try vm.envUint("INITIAL_OWNER_PRIVATE_KEY") returns (uint256 value) {
            return value;
        } catch {
            return vm.envUint("L1_INITIAL_OWNER_PRIVATE_KEY");
        }
    }

    error L1UpgradeWrongLidoDaoAgent(address actual, address expected);

    /// @dev Reads the DAO Agent from env and asserts it matches the known-correct mainnet constant.
    ///      The handover (receiver admin + ProxyAdmin owner) is irreversible by the Initial Owner,
    ///      so a wrong-but-nonzero env value must be rejected before broadcast — same guard class
    ///      as `_envGovernanceExecutor()` on the L2 side.
    function _envLidoDaoAgent() internal view returns (address lidoDaoAgent) {
        try vm.envAddress("LIDO_DAO_AGENT") returns (address value) {
            lidoDaoAgent = value;
        } catch {
            lidoDaoAgent = vm.envAddress("LIDO_NEW_OWNER");
        }
        if (lidoDaoAgent != L1.LIDO_DAO_AGENT) {
            revert L1UpgradeWrongLidoDaoAgent(lidoDaoAgent, L1.LIDO_DAO_AGENT);
        }
    }

    function run() external {
        assertL1ChainId(L1.ETH_CHAIN_ID);

        uint256 initialOwnerPrivateKey = _envInitialOwnerPrivateKey();
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        address lidoDaoAgent = _envLidoDaoAgent();

        L1UpgradeConfig memory cfg = defaultL1Config(initialOwner, lidoDaoAgent);

        vm.startBroadcast(initialOwnerPrivateKey);
        execute(cfg);
        vm.stopBroadcast();
    }
}
