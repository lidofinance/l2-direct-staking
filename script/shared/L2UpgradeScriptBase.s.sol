// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";
import {SyncTrigger} from "src/SyncTrigger.sol";
import {L2UpgradeActions} from "script/shared/L2UpgradeActions.s.sol";
import {L1MigrationConstants as L1} from "script/shared/L1MigrationConstants.sol";

/**
 * @notice Shared broadcast script for L2 upgrade operations.
 *
 * The migration is split into stages, each executed by a distinct actor:
 *
 *   Stage 1 — runDeploy()              Actor: Lido Deployer
 *   Stage 2 — runMigrate()             Actor: Initial Owner
 *   Stage 3 — runFinalizeSyncTrigger() Actor: Lido Deployer
 *
 * Test-only (not part of migration):
 *   runSweepOldPool()  — verifies old liquidity owner can withdraw from old pool
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
 *     - L2_LIQUIDITY_OWNER (optional, defaults to network LOL multisig)
 *
 *   runMigrate:
 *     - INITIAL_OWNER_PRIVATE_KEY
 *     - L2_GOVERNANCE_EXECUTOR
 *     - L2_ORACLE_POOL (output of runDeploy)
 *     - L2_SYNC_TRIGGER (output of runDeploy)
 *     - L2_LIDO_DEPLOYER (address, interim SyncTrigger owner)
 *     - L2_LIQUIDITY_OWNER (optional, defaults to network LOL multisig)
 *
 *   runFinalizeSyncTrigger:
 *     - L2_LIDO_DEPLOYER_PRIVATE_KEY
 *     - L2_SYNC_TRIGGER
 *     - L2_CRE_FORWARDER (deployed CREReceiver address)
 *     - L2_GOVERNANCE_EXECUTOR
 *     - L2_LIQUIDITY_OWNER (optional, defaults to network LOL multisig — CREReceiver final owner)
 *
 *   runSweepOldPool (test-only):
 *     - OLD_LIQUIDITY_OWNER_PRIVATE_KEY
 *     - OLD_LIQUIDITY_RECIPIENT (optional, defaults to signer)
 */
abstract contract L2UpgradeScriptBase is Script, L2UpgradeActions {
    // ── Network hooks ────────────────────────────────────────────────

    /// @dev Returns a network-specific L2 upgrade config.
    function _buildConfig(address initialOwner, address governanceExecutor, address liquidityOwner)
        internal
        pure
        virtual
        returns (L2UpgradeConfig memory);

    /// @dev Sweeps remaining tokens from the old oracle pool.
    function _sweepOldPool(address recipient) internal virtual;

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

    // ── Stage 1: Lido Deployer ───────────────────────────────────────

    /// @notice Deploy new OraclePool and SyncTrigger. Actor: Lido Deployer.
    function runDeploy() public returns (address oraclePool, address syncTrigger) {
        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = _envLiquidityOwnerAddress();

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(lidoDeployerPrivateKey);
        PausableImmutableOraclePool pool = deployPool(cfg);
        SyncTrigger deployedSyncTrigger = deploySyncTrigger(cfg);
        vm.stopBroadcast();

        oraclePool = address(pool);
        syncTrigger = address(deployedSyncTrigger);
    }

    // ── Stage 2: Initial Owner ───────────────────────────────────────

    /// @notice Configure new contracts and migrate admin roles. Actor: Initial Owner.
    function runMigrate() public {
        uint256 initialOwnerPrivateKey = _envInitialOwnerPrivateKey();
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = _envLiquidityOwnerAddress();
        address oraclePool = vm.envAddress("L2_ORACLE_POOL");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");
        address syncTriggerInterimOwner = vm.envAddress("L2_LIDO_DEPLOYER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(initialOwnerPrivateKey);
        executeMigrationSteps(cfg, oraclePool, syncTrigger, syncTriggerInterimOwner);
        vm.stopBroadcast();
    }

    /// @notice Same as runMigrate but impersonates Initial Owner (anvil only).
    function runMigrateUnlocked() public {
        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = _envLiquidityOwnerAddress();
        address oraclePool = vm.envAddress("L2_ORACLE_POOL");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");
        address syncTriggerInterimOwner = vm.envAddress("L2_LIDO_DEPLOYER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(initialOwner);
        executeMigrationSteps(cfg, oraclePool, syncTrigger, syncTriggerInterimOwner);
        vm.stopBroadcast();
    }

    // ── Stage 3: Lido Deployer ───────────────────────────────────────

    /// @notice Set CRE forwarder, transfer SyncTrigger and CREReceiver to final owners. Actor: Lido Deployer.
    function runFinalizeSyncTrigger() external {
        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");
        address creReceiver = vm.envAddress("L2_CRE_FORWARDER");
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = _envLiquidityOwnerAddress();

        vm.startBroadcast(lidoDeployerPrivateKey);
        setSyncTriggerForwarder(syncTrigger, creReceiver);
        transferSyncTriggerOwnership(syncTrigger, governanceExecutor);
        Ownable(creReceiver).transferOwnership(liquidityOwner);
        vm.stopBroadcast();
    }

    // ── Test-only: Old Liquidity Owner ──────────────────────────────

    /// @notice Sweep remaining wstETH and WETH from the old pool (test helper, not a migration stage).
    function runSweepOldPool() external {
        uint256 oldLiquidityOwnerKey = vm.envUint("OLD_LIQUIDITY_OWNER_PRIVATE_KEY");
        address recipient = vm.envOr("OLD_LIQUIDITY_RECIPIENT", vm.addr(oldLiquidityOwnerKey));

        vm.startBroadcast(oldLiquidityOwnerKey);
        _sweepOldPool(recipient);
        vm.stopBroadcast();
    }

    // ── Convenience: Stage 1 + Stage 2 ──────────────────────────────

    /// @notice Deploy + migrate in one call (requires both deployer and initial owner keys).
    function run() external returns (address oraclePool, address syncTrigger) {
        uint256 initialOwnerPrivateKey = _envInitialOwnerPrivateKey();
        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address lidoDeployer = vm.addr(lidoDeployerPrivateKey);
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = _envLiquidityOwnerAddress();

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(lidoDeployerPrivateKey);
        PausableImmutableOraclePool pool = deployPool(cfg);
        SyncTrigger deployedSyncTrigger = deploySyncTrigger(cfg);
        vm.stopBroadcast();

        vm.startBroadcast(initialOwnerPrivateKey);
        executeMigrationSteps(cfg, address(pool), address(deployedSyncTrigger), lidoDeployer);
        vm.stopBroadcast();

        oraclePool = address(pool);
        syncTrigger = address(deployedSyncTrigger);
    }

    /// @notice Deploy + migrate with impersonated initial owner (anvil only).
    function runWithUnlockedInitialOwner() external returns (address oraclePool, address syncTrigger) {
        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address lidoDeployer = vm.addr(lidoDeployerPrivateKey);
        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = _envLiquidityOwnerAddress();

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(lidoDeployerPrivateKey);
        PausableImmutableOraclePool pool = deployPool(cfg);
        SyncTrigger deployedSyncTrigger = deploySyncTrigger(cfg);
        vm.stopBroadcast();

        vm.startBroadcast(initialOwner);
        executeMigrationSteps(cfg, address(pool), address(deployedSyncTrigger), lidoDeployer);
        vm.stopBroadcast();

        oraclePool = address(pool);
        syncTrigger = address(deployedSyncTrigger);
    }
}
