// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {L2UpgradeActions} from "script/shared/L2UpgradeActions.s.sol";
import {L1MigrationConstants as L1} from "script/l1/L1MigrationConstants.sol";

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
 *     - L2_LIQUIDITY_OWNER (optional, defaults to network LOL multisig)
 *
 */
abstract contract L2UpgradeScriptBase is Script, L2UpgradeActions {
    // ── Network hooks ────────────────────────────────────────────────

    /// @dev Returns a network-specific L2 upgrade config.
    function _buildConfig(address initialOwner, address governanceExecutor, address liquidityOwner)
        internal
        view
        virtual
        returns (L2UpgradeConfig memory);

    /// @dev Returns the network-specific default liquidity owner (LOL multisig).
    function _defaultLiquidityOwner() internal view virtual returns (address);

    /// @dev Returns the expected L2 chain ID. Scripts revert if `block.chainid` doesn't match.
    function _expectedChainId() internal pure virtual returns (uint256);

    /// @dev Returns the known-correct L2 governance executor for this network, or address(0) to opt
    ///      out of the check (e.g. Sepolia, where the executor is operator-supplied and has no
    ///      canonical value). Production networks override this to their per-chain
    ///      LIDO_L2_GOVERNANCE_EXECUTOR constant so that a wrong `L2_GOVERNANCE_EXECUTOR` env value is
    ///      rejected before any irreversible admin/ownership handover (FINDINGS.md F-4).
    ///      `pure` like `_expectedChainId` (every network returns a constant or the address(0) opt-out;
    ///      none reads state). The expected executor is a known canonical value, never derived from env.
    function _expectedGovernanceExecutor() internal pure virtual returns (address) {
        return address(0);
    }

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

    error L2UpgradeWrongGovernanceExecutor(address actual, address expected);

    /// @dev Reads `L2_GOVERNANCE_EXECUTOR` and asserts it matches this network's known-correct executor
    ///      (FINDINGS.md F-4). The per-network constant previously lived only in tests, so a wrong-but-
    ///      nonzero env value would have been baked into SyncTrigger ownership (Stage 1) and the
    ///      DEFAULT_ADMIN_ROLE / ProxyAdmin handover (Stage 2) with no on-chain guardrail — the same class
    ///      of bug as the historical wrong Base/Linea executor. No-op when `_expectedGovernanceExecutor()`
    ///      returns address(0) (testnet opt-out).
    function _envGovernanceExecutor() internal view returns (address governanceExecutor) {
        governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address expected = _expectedGovernanceExecutor();
        if (expected != address(0) && governanceExecutor != expected) {
            revert L2UpgradeWrongGovernanceExecutor(governanceExecutor, expected);
        }
    }

    // ── Deploy helper ────────────────────────────────────────────────

    function _deployAll(L2UpgradeConfig memory cfg, address creForwarder, address deployer)
        internal
        returns (address oraclePool, address syncTrigger, address creReceiverAddr)
    {
        oraclePool = address(deployPool(cfg));
        // The CRE workflow is registered under the LOL multisig (Safe) via `cre workflow deploy
        // --unsigned`, executed from the Safe — so the workflow owner recorded in
        // `metadata.workflowOwner` is the Safe (= `cfg.liquidityOwner`). We pin `_expectedAuthor` to
        // that Safe address, the same entity that owns the CREReceiver. The Lido Deployer EOA only
        // broadcasts this Stage-1 deploy; it is NOT the workflow owner. See ADR-0001 and DOC.md §3.2.
        (syncTrigger, creReceiverAddr) = deploySyncInfrastructure(cfg, deployer, creForwarder, cfg.liquidityOwner);
    }

    // ── Stage 1: Lido Deployer ───────────────────────────────────────

    /// @notice Deploy new OraclePool, SyncTrigger, and CREReceiver; configure SyncTrigger and transfer ownership. Actor: Lido Deployer.
    function runDeploy() public returns (address oraclePool, address syncTrigger, address creReceiverAddr) {
        assertL2ChainId(_expectedChainId());

        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(lidoDeployerPrivateKey);
        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = _envGovernanceExecutor();
        address liquidityOwner = _envLiquidityOwnerAddress();
        address creForwarder = vm.envAddress("L2_CRE_FORWARDER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(lidoDeployerPrivateKey);
        (oraclePool, syncTrigger, creReceiverAddr) = _deployAll(cfg, creForwarder, deployer);
        vm.stopBroadcast();
    }

    // ── Stage 1 verification (read-only, between Stage 1 and Stage 2) ─

    /// @notice Read-only verification that Stage 1 deploy is complete, correct, and Stage 2 has NOT yet run. Actor: anyone.
    /// @dev Required env: L2_ORACLE_POOL, L2_SYNC_TRIGGER, L2_CRE_RECEIVER, L2_GOVERNANCE_EXECUTOR, L2_CRE_FORWARDER.
    ///      The CREReceiver.expectedAuthor pin is the LOL multisig (= liquidity owner / CRE workflow owner),
    ///      sourced from L2_LIQUIDITY_OWNER (or the network's default LOL multisig) — not the broadcasting EOA.
    function runVerifyStage1() public view {
        assertL2ChainId(_expectedChainId());

        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = _envGovernanceExecutor();
        address liquidityOwner = _envLiquidityOwnerAddress();
        address creForwarder = vm.envAddress("L2_CRE_FORWARDER");
        // The CRE workflow owner pinned as expectedAuthor is the LOL multisig (Safe), the same
        // address that owns the CREReceiver — see ADR-0001 / DOC.md §3.2.
        address expectedAuthor = liquidityOwner;
        address oraclePool = vm.envAddress("L2_ORACLE_POOL");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");
        address creReceiverAddr = vm.envAddress("L2_CRE_RECEIVER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);
        verifyStage1(cfg, oraclePool, syncTrigger, creReceiverAddr, creForwarder, expectedAuthor);
    }

    // ── Stage 2: Initial Owner ───────────────────────────────────────

    /// @notice Migrate admin roles on existing contracts to final owners. Actor: Initial Owner.
    function runMigrate() public virtual {
        assertL2ChainId(_expectedChainId());

        uint256 initialOwnerPrivateKey = _envInitialOwnerPrivateKey();
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        address governanceExecutor = _envGovernanceExecutor();
        address liquidityOwner = _envLiquidityOwnerAddress();
        address oraclePool = vm.envAddress("L2_ORACLE_POOL");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(initialOwnerPrivateKey);
        executeMigrationSteps(cfg, oraclePool, syncTrigger);
        vm.stopBroadcast();
    }

    /// @notice Same as runMigrate but impersonates Initial Owner (anvil only).
    function runMigrateUnlocked() public virtual {
        assertL2ChainId(_expectedChainId());

        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = _envGovernanceExecutor();
        address liquidityOwner = _envLiquidityOwnerAddress();
        address oraclePool = vm.envAddress("L2_ORACLE_POOL");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(initialOwner);
        executeMigrationSteps(cfg, oraclePool, syncTrigger);
        vm.stopBroadcast();
    }

    // ── Convenience: Stage 1 + Stage 2 ──────────────────────────────

    error L2UpgradeSingleRunUnsafe(uint256 chainId);

    /// @dev L2 mainnet chain-IDs: Optimism (10), Arbitrum (42161), Base (8453), Linea (59144).
    ///      Stages 1 and 2 are run by different actors in production; chaining them in one broadcast
    ///      requires both keys co-located, which defeats the separation. Override with
    ///      `ALLOW_UNSAFE_COMBINED_RUN=1` (acceptable only for fork / testnet).
    function _isProductionL2ChainId(uint256 id) private pure returns (bool) {
        return id == 10 || id == 42161 || id == 8453 || id == 59144;
    }

    function _guardCombinedRun() internal view {
        assertL2ChainId(_expectedChainId());
        if (!_isProductionL2ChainId(block.chainid)) return;
        if (vm.envOr("ALLOW_UNSAFE_COMBINED_RUN", uint256(0)) == 1) return;
        revert L2UpgradeSingleRunUnsafe(block.chainid);
    }

    /// @notice Deploy + migrate in one call (requires both deployer and initial owner keys).
    /// @dev Blocked on mainnet unless `ALLOW_UNSAFE_COMBINED_RUN=1` is explicitly set. Stages 1 and 2
    ///      are run by different actors (Lido Deployer vs Initial Owner) in production; chaining them
    ///      in one broadcast requires both keys to be co-located, which defeats the separation.
    function run() external returns (address oraclePool, address syncTrigger, address creReceiverAddr) {
        _guardCombinedRun();

        uint256 initialOwnerPrivateKey = _envInitialOwnerPrivateKey();
        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(lidoDeployerPrivateKey);
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        address governanceExecutor = _envGovernanceExecutor();
        address liquidityOwner = _envLiquidityOwnerAddress();
        address creForwarder = vm.envAddress("L2_CRE_FORWARDER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(lidoDeployerPrivateKey);
        (oraclePool, syncTrigger, creReceiverAddr) = _deployAll(cfg, creForwarder, deployer);
        vm.stopBroadcast();

        vm.startBroadcast(initialOwnerPrivateKey);
        executeMigrationSteps(cfg, oraclePool, syncTrigger);
        vm.stopBroadcast();
    }

    /// @notice Deploy + migrate with impersonated initial owner (anvil only).
    function runWithUnlockedInitialOwner() external returns (address oraclePool, address syncTrigger, address creReceiverAddr) {
        _guardCombinedRun();

        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(lidoDeployerPrivateKey);
        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = _envGovernanceExecutor();
        address liquidityOwner = _envLiquidityOwnerAddress();
        address creForwarder = vm.envAddress("L2_CRE_FORWARDER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(lidoDeployerPrivateKey);
        (oraclePool, syncTrigger, creReceiverAddr) = _deployAll(cfg, creForwarder, deployer);
        vm.stopBroadcast();

        vm.startBroadcast(initialOwner);
        executeMigrationSteps(cfg, oraclePool, syncTrigger);
        vm.stopBroadcast();
    }
}
