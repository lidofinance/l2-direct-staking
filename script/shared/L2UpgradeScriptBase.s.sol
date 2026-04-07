// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";
import {SyncTrigger} from "src/SyncTrigger.sol";
import {CREReceiver} from "src/cre/CREReceiver.sol";
import {L2UpgradeActions} from "script/shared/L2UpgradeActions.s.sol";
import {L1MigrationConstants as L1} from "script/shared/L1MigrationConstants.sol";

/**
 * @notice Shared broadcast script for L2 upgrade operations.
 *
 * The migration is split into two stages, each executed by a distinct actor:
 *
 *   Stage 1 — runDeploy()   Actor: Lido Deployer
 *   Stage 2 — runMigrate()  Actor: Initial Owner
 *
 * Convenience:
 *   run()                        — chains Stage 1 + Stage 2 (requires both keys)
 *   runWithUnlockedInitialOwner() — same, but impersonates Initial Owner on anvil
 *
 * Required env per stage:
 *
 *   runDeploy:
 *     - L2_LIDO_DEPLOYER_PRIVATE_KEY
 *     - L2_GOVERNANCE_EXECUTOR
 *     - L2_CRE_FORWARDER (Chainlink CRE Forwarder address for this network)
 *     - L2_LIQUIDITY_OWNER (optional, defaults to network LOL multisig)
 *
 *   runMigrate:
 *     - INITIAL_OWNER_PRIVATE_KEY
 *     - L2_GOVERNANCE_EXECUTOR
 *     - L2_ORACLE_POOL (output of runDeploy)
 *     - L2_SYNC_TRIGGER (output of runDeploy)
 *     - L2_CRE_RECEIVER (output of runDeploy)
 *     - L2_LIQUIDITY_OWNER (optional, defaults to network LOL multisig)
 *
 */
abstract contract L2UpgradeScriptBase is Script, L2UpgradeActions {
    // ── Network hooks ────────────────────────────────────────────────

    /// @dev Returns a network-specific L2 upgrade config.
    function _buildConfig(address initialOwner, address governanceExecutor, address liquidityOwner)
        internal
        pure
        virtual
        returns (L2UpgradeConfig memory);

    /// @dev Returns the network-specific default liquidity owner (LOL multisig).
    function _defaultLiquidityOwner() internal pure virtual returns (address);

    // ── env helpers ──────────────────────────────────────────────────

    function _envInitialOwnerPrivateKey() internal view returns (uint256) {
        try vm.envUint("INITIAL_OWNER_PRIVATE_KEY") returns (uint256 value) {
            return value;
        } catch {
            return vm.envUint("L2_INITIAL_OWNER_PRIVATE_KEY");
        }
    }

    function _envInitialOwnerAddress() internal view returns (address) {
        try vm.envAddress("INITIAL_OWNER") returns (address value) {
            return value;
        } catch {
            return vm.envOr("L2_INITIAL_OWNER", L1.INITIAL_OWNER);
        }
    }

    function _envLiquidityOwnerAddress() internal view returns (address) {
        return vm.envOr("L2_LIQUIDITY_OWNER", _defaultLiquidityOwner());
    }

    // ── Deploy helper ────────────────────────────────────────────────

    function _deployAll(L2UpgradeConfig memory cfg, address creForwarder, address liquidityOwner)
        internal
        returns (address oraclePool, address syncTrigger, address creReceiverAddr)
    {
        PausableImmutableOraclePool pool = deployPool(cfg);
        SyncTrigger deployedSyncTrigger = deploySyncTrigger(cfg);
        CREReceiver deployedCREReceiver = deployCREReceiver(creForwarder);
        transferCREReceiverOwnership(address(deployedCREReceiver), liquidityOwner);

        oraclePool = address(pool);
        syncTrigger = address(deployedSyncTrigger);
        creReceiverAddr = address(deployedCREReceiver);
    }

    // ── Stage 1: Lido Deployer ───────────────────────────────────────

    /// @notice Deploy new OraclePool, SyncTrigger, and CREReceiver; transfer CREReceiver to LOL multisig. Actor: Lido Deployer.
    function runDeploy() public returns (address oraclePool, address syncTrigger, address creReceiverAddr) {
        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = _envLiquidityOwnerAddress();
        address creForwarder = vm.envAddress("L2_CRE_FORWARDER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(lidoDeployerPrivateKey);
        (oraclePool, syncTrigger, creReceiverAddr) = _deployAll(cfg, creForwarder, liquidityOwner);
        vm.stopBroadcast();
    }

    // ── Stage 2: Initial Owner ───────────────────────────────────────

    /// @notice Configure new contracts, set CRE forwarder, and migrate admin roles to final owners. Actor: Initial Owner.
    function runMigrate() public {
        uint256 initialOwnerPrivateKey = _envInitialOwnerPrivateKey();
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = _envLiquidityOwnerAddress();
        address oraclePool = vm.envAddress("L2_ORACLE_POOL");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");
        address creReceiver = vm.envAddress("L2_CRE_RECEIVER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(initialOwnerPrivateKey);
        executeMigrationSteps(cfg, oraclePool, syncTrigger, creReceiver);
        vm.stopBroadcast();
    }

    /// @notice Same as runMigrate but impersonates Initial Owner (anvil only).
    function runMigrateUnlocked() public {
        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = _envLiquidityOwnerAddress();
        address oraclePool = vm.envAddress("L2_ORACLE_POOL");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");
        address creReceiver = vm.envAddress("L2_CRE_RECEIVER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(initialOwner);
        executeMigrationSteps(cfg, oraclePool, syncTrigger, creReceiver);
        vm.stopBroadcast();
    }

    // ── Convenience: Stage 1 + Stage 2 ──────────────────────────────

    /// @notice Deploy + migrate in one call (requires both deployer and initial owner keys).
    function run() external returns (address oraclePool, address syncTrigger, address creReceiverAddr) {
        uint256 initialOwnerPrivateKey = _envInitialOwnerPrivateKey();
        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = _envLiquidityOwnerAddress();
        address creForwarder = vm.envAddress("L2_CRE_FORWARDER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(lidoDeployerPrivateKey);
        (oraclePool, syncTrigger, creReceiverAddr) = _deployAll(cfg, creForwarder, liquidityOwner);
        vm.stopBroadcast();

        vm.startBroadcast(initialOwnerPrivateKey);
        executeMigrationSteps(cfg, oraclePool, syncTrigger, creReceiverAddr);
        vm.stopBroadcast();
    }

    /// @notice Deploy + migrate with impersonated initial owner (anvil only).
    function runWithUnlockedInitialOwner() external returns (address oraclePool, address syncTrigger, address creReceiverAddr) {
        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = _envLiquidityOwnerAddress();
        address creForwarder = vm.envAddress("L2_CRE_FORWARDER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(lidoDeployerPrivateKey);
        (oraclePool, syncTrigger, creReceiverAddr) = _deployAll(cfg, creForwarder, liquidityOwner);
        vm.stopBroadcast();

        vm.startBroadcast(initialOwner);
        executeMigrationSteps(cfg, oraclePool, syncTrigger, creReceiverAddr);
        vm.stopBroadcast();
    }
}
