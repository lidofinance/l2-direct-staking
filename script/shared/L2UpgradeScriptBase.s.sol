// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

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
 *     - L2_GOVERNANCE_EXECUTOR (only on opt-out networks; production networks pin it in code
 *                              via _expectedGovernanceExecutor(), so it defaults to the pinned constant)
 *     - L2_CRE_FORWARDER (only on opt-out networks; production networks pin the forwarder in
 *                         code via _expectedCREForwarder(), so it is not required there)
 *     - L2_LIQUIDITY_OWNER (optional, defaults to network LOL multisig)
 *
 *   runMigrate:
 *     - INITIAL_OWNER_PRIVATE_KEY
 *     - L2_ORACLE_POOL (output of runDeploy)
 *     - L2_SYNC_TRIGGER (output of runDeploy)
 *     - L2_CRE_RECEIVER (output of runDeploy)
 *     - L2_GOVERNANCE_EXECUTOR (only on opt-out networks; production pins it in code)
 *     - L2_CRE_FORWARDER (only on opt-out networks; production pins it in code)
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
    ///      out of the check (an opt-out network, where the executor is operator-supplied and has no
    ///      canonical value). Production networks override this to their per-chain
    ///      LIDO_L2_GOVERNANCE_EXECUTOR constant so that a wrong `L2_GOVERNANCE_EXECUTOR` env value is
    ///      rejected before any irreversible admin/ownership handover.
    ///      `pure` like `_expectedChainId` (every network returns a constant or the address(0) opt-out;
    ///      none reads state). The expected executor is a known canonical value, never derived from env.
    function _expectedGovernanceExecutor() internal pure virtual returns (address) {
        return address(0);
    }

    /// @dev Returns the fixed, Chainlink-published CRE Forwarder for this network, or address(0) to opt
    ///      out (e.g. before Chainlink has published the forwarder for a network). Mirrors
    ///      `_expectedGovernanceExecutor`, but because the forwarder is a per-network constant (not an
    ///      operator choice) pinning it here makes it fully non-env: `_creForwarder()` uses this value
    ///      directly, so `L2_CRE_FORWARDER` need not be set (and a present-but-wrong value is rejected).
    ///      Without a pin, the only post-deploy check is tautological (CREReceiver.getForwarder() == the
    ///      value just passed in), so a stale/mistyped env forwarder would be baked IMMUTABLY into
    ///      CREReceiver and every CRE-triggered sync silently rejected by the real forwarder.
    function _expectedCREForwarder() internal pure virtual returns (address) {
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

    /// @dev Resolves a per-network PINNED address that is env-OPTIONAL. When the network pins a value
    ///      (`expected != 0`) the env var DEFAULTS to that constant and a present-but-different value is
    ///      reported as a mismatch (`ok == false`) for the caller to reject with its own typed error;
    ///      when there is no pin (`expected == 0`, opt-out) the operator MUST supply it via env.
    ///      Shared by `_creForwarder` and `_envGovernanceExecutor` so the two pinned addresses — both
    ///      fixed per-network constants, both verify-constants-sync'd — impose ONE operator contract (a
    ///      value the code already knows is never made mandatory) rather than two divergent ones, and a
    ///      maintainer needn't remember which pinned address was env-optional vs env-required.
    function _resolvePinned(string memory envName, address expected)
        internal
        view
        returns (address resolved, bool ok)
    {
        if (expected == address(0)) return (vm.envAddress(envName), true); // opt-out: operator-supplied
        resolved = vm.envOr(envName, expected); // pinned: env defaults to the constant
        ok = resolved == expected; // a present-but-wrong value must not silently override the pin
    }

    error L2UpgradeWrongGovernanceExecutor(address actual, address expected);

    /// @dev Resolves `L2_GOVERNANCE_EXECUTOR` and asserts it matches this network's known-correct
    ///      executor. Like the CRE forwarder, the executor is a fixed per-network constant
    ///      (verify-constants-sync'd), so it is env-OPTIONAL via `_resolvePinned`: when pinned it
    ///      defaults to that constant and a present-but-wrong value is rejected. The per-network constant
    ///      previously lived only in tests, so a wrong-but-nonzero env value would have been baked into
    ///      the DEFAULT_ADMIN_ROLE / ProxyAdmin handover (Stage 2) with no on-chain guardrail — the same
    ///      class of bug as the historical wrong Base/Linea executor. (SyncTrigger ownership now goes to
    ///      the LOL multisig, so Stage 1 no longer assigns the executor; the guard still validates it in
    ///      both stages.) When `_expectedGovernanceExecutor()` returns address(0) (opt-out) the
    ///      operator must supply it via env, as before.
    function _envGovernanceExecutor() internal view returns (address governanceExecutor) {
        address expected = _expectedGovernanceExecutor();
        bool ok;
        (governanceExecutor, ok) = _resolvePinned("L2_GOVERNANCE_EXECUTOR", expected);
        if (!ok) revert L2UpgradeWrongGovernanceExecutor(governanceExecutor, expected);
    }

    error L2UpgradeWrongCREForwarder(address actual, address expected);

    /// @dev Resolves the Chainlink CRE Forwarder for this network. Production networks pin it via
    ///      `_expectedCREForwarder()` (a fixed, Chainlink-published per-network address), so the
    ///      forwarder is NOT operator-supplied and `L2_CRE_FORWARDER` need not be set — it defaults to
    ///      the pin (via `_resolvePinned`). If the env var IS set it must match the pin, else we revert:
    ///      a stale/mistyped value must never silently override the constant that is baked immutably into
    ///      CREReceiver. Opt-out networks (e.g. a not-yet-published forwarder) return address(0) from the hook
    ///      and supply the forwarder via `L2_CRE_FORWARDER` as before.
    function _creForwarder() internal view returns (address creForwarder) {
        address expected = _expectedCREForwarder();
        bool ok;
        (creForwarder, ok) = _resolvePinned("L2_CRE_FORWARDER", expected);
        if (!ok) revert L2UpgradeWrongCREForwarder(creForwarder, expected);
    }

    // ── Deploy helper ────────────────────────────────────────────────

    function _deployAll(L2UpgradeConfig memory cfg, address creForwarder)
        internal
        returns (address oraclePool, address syncTrigger, address creReceiverAddr)
    {
        oraclePool = address(deployPool(cfg));
        // The CRE workflow is registered under the LOL multisig (Safe) via `cre workflow deploy
        // --unsigned`, executed from the Safe — so the workflow owner recorded in
        // `metadata.workflowOwner` is the Safe (= `cfg.liquidityOwner`). We pin `_expectedAuthor` to
        // that Safe address, the same entity that owns the CREReceiver. The Lido Deployer EOA only
        // broadcasts this Stage-1 deploy (transiently owning the CREReceiver until it is handed to the
        // Safe); it is NOT the workflow owner. See ADR-0001 and DOC.md §3.2.
        (syncTrigger, creReceiverAddr) = deploySyncInfrastructure(cfg, creForwarder, cfg.liquidityOwner);
    }

    // ── Stage 1: Lido Deployer ───────────────────────────────────────

    /// @notice Deploy new OraclePool + CREReceiver + a fully-configured SyncTrigger (owned by the LOL multisig from construction). Actor: Lido Deployer.
    function runDeploy() public returns (address oraclePool, address syncTrigger, address creReceiverAddr) {
        assertL2ChainId(_expectedChainId());

        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = _envGovernanceExecutor();
        address liquidityOwner = _envLiquidityOwnerAddress();
        address creForwarder = _creForwarder();

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(lidoDeployerPrivateKey);
        (oraclePool, syncTrigger, creReceiverAddr) = _deployAll(cfg, creForwarder);
        vm.stopBroadcast();
    }

    // ── Stage 1 verification (read-only, between Stage 1 and Stage 2) ─

    /// @notice Read-only verification that Stage 1 deploy is complete, correct, and Stage 2 has NOT yet run. Actor: anyone.
    /// @dev Required env: L2_ORACLE_POOL, L2_SYNC_TRIGGER, L2_CRE_RECEIVER, L2_GOVERNANCE_EXECUTOR
    ///      (L2_CRE_FORWARDER only on opt-out networks; production networks pin it in code).
    ///      The CREReceiver.expectedAuthor pin is the LOL multisig (= liquidity owner / CRE workflow owner),
    ///      sourced from L2_LIQUIDITY_OWNER (or the network's default LOL multisig) — not the broadcasting EOA.
    function runVerifyStage1() public view {
        assertL2ChainId(_expectedChainId());

        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = _envGovernanceExecutor();
        address liquidityOwner = _envLiquidityOwnerAddress();
        address creForwarder = _creForwarder();
        // The CRE workflow owner pinned as expectedAuthor is the LOL multisig (Safe), the same
        // address that owns the CREReceiver — see ADR-0001 / DOC.md §3.2.
        address expectedAuthor = liquidityOwner;
        address oraclePool = vm.envAddress("L2_ORACLE_POOL");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");
        address creReceiverAddr = vm.envAddress("L2_CRE_RECEIVER");

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);
        verifyStage1(cfg, oraclePool, syncTrigger, creReceiverAddr, creForwarder, expectedAuthor);
    }

    // ── Config-sync helper (read-only, no chain access) ──────────────

    /// @notice Prints the encoded SyncTrigger fee blobs + derived getMaxFees for this network, computed
    ///         from the same constants the deploy uses. Consumed by `just verify-constants-sync` to assert
    ///         the `<net>.inputs.yaml` `config:` fee anchors stay in lockstep with the Solidity source of
    ///         truth, and used when authoring those anchors. Pure computation — needs no RPC or broadcast.
    ///         The actor addresses do not affect any fee field, so dummy non-zero placeholders are passed.
    /// @dev The native fee total is shared with `SyncTrigger.getMaxFees()` via the inherited `_maxFees`
    ///      mirror (byte-identical to `SyncTrigger._maxFees`), so this oracle and the contract cannot drift
    ///      on fee-denomination semantics. Mirrors `L2UpgradeActions` feeOtoD encoding.
    function runPrintFeeParams() public view {
        L2UpgradeConfig memory cfg = _buildConfig(address(0xA11CE), address(0xB0B), address(0xC0FFEE));

        bytes memory feeOtoD = _encodeFeeOtoD(cfg);
        bytes memory feeDtoO = cfg.feeDtoO;

        uint256 maxNativeFee = _maxFees(feeOtoD, feeDtoO);

        console2.log("FEE_OTO_D=%s", vm.toString(feeOtoD));
        console2.log("FEE_DTO_O=%s", vm.toString(feeDtoO));
        console2.log("MAX_NATIVE_FEE=%s", vm.toString(maxNativeFee));
        // The FeeOtoD gasLimit ceiling (SyncTrigger.getMaxGasLimit) — cross-checked vs the &maxGasLimit
        // .inputs anchor by verify-constants-sync, the same Solidity→.inputs guard as the fee blobs.
        console2.log("MAX_GAS_LIMIT=%s", vm.toString(uint256(cfg.maxGasLimit)));
        // INITIAL_FLOAT has no stable state-mate anchor (the trigger's ETH balance drifts as it fronts
        // per-sync fees), so verify-constants-sync does not read this line — it is printed for operator
        // review when authoring the .inputs.yaml fee block.
        console2.log("INITIAL_FLOAT=%s", vm.toString(uint256(cfg.syncTriggerInitialFloat)));
    }

    // ── Stage 2: Initial Owner ───────────────────────────────────────

    /// @notice Migrate admin roles on existing contracts to final owners. Actor: Initial Owner.
    function runMigrate() public virtual {
        uint256 initialOwnerPrivateKey = _envInitialOwnerPrivateKey();
        _runMigrateBody(vm.addr(initialOwnerPrivateKey), initialOwnerPrivateKey);
    }

    /// @notice Same as runMigrate but impersonates Initial Owner (anvil only).
    function runMigrateUnlocked() public virtual {
        _runMigrateBody(_envInitialOwnerAddress(), 0);
    }

    /// @dev Shared Stage-2 body for both the production broadcast (a nonzero `initialOwnerPrivateKey`
    ///      signs) and the anvil rehearsal (`initialOwnerPrivateKey == 0` impersonates `initialOwner`).
    ///      Keeping one body guarantees the rehearsal exercises exactly the env reads and preconditions
    ///      the production migrate does — they cannot drift apart.
    function _runMigrateBody(address initialOwner, uint256 initialOwnerPrivateKey) internal {
        assertL2ChainId(_expectedChainId());

        address governanceExecutor = _envGovernanceExecutor();
        address liquidityOwner = _envLiquidityOwnerAddress();
        address oraclePool = vm.envAddress("L2_ORACLE_POOL");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");
        // needed by executeMigrationSteps' Stage-1-completeness precondition.
        address creReceiver = vm.envAddress("L2_CRE_RECEIVER");
        address creForwarder = _creForwarder();

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        // A nonzero key signs the production broadcast; 0 is the anvil-rehearsal sentinel (impersonate
        // the Initial Owner address). vm.addr(0) is never a valid signer, so the paths cannot collide.
        if (initialOwnerPrivateKey != 0) {
            vm.startBroadcast(initialOwnerPrivateKey);
        } else {
            vm.startBroadcast(initialOwner);
        }
        executeMigrationSteps(cfg, oraclePool, syncTrigger, creReceiver, creForwarder);
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
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        address governanceExecutor = _envGovernanceExecutor();
        address liquidityOwner = _envLiquidityOwnerAddress();
        address creForwarder = _creForwarder();

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(lidoDeployerPrivateKey);
        (oraclePool, syncTrigger, creReceiverAddr) = _deployAll(cfg, creForwarder);
        vm.stopBroadcast();

        vm.startBroadcast(initialOwnerPrivateKey);
        executeMigrationSteps(cfg, oraclePool, syncTrigger, creReceiverAddr, creForwarder);
        vm.stopBroadcast();
    }

    /// @notice Deploy + migrate with impersonated initial owner (anvil only).
    function runWithUnlockedInitialOwner() external returns (address oraclePool, address syncTrigger, address creReceiverAddr) {
        _guardCombinedRun();

        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address initialOwner = _envInitialOwnerAddress();
        address governanceExecutor = _envGovernanceExecutor();
        address liquidityOwner = _envLiquidityOwnerAddress();
        address creForwarder = _creForwarder();

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);

        vm.startBroadcast(lidoDeployerPrivateKey);
        (oraclePool, syncTrigger, creReceiverAddr) = _deployAll(cfg, creForwarder);
        vm.stopBroadcast();

        vm.startBroadcast(initialOwner);
        executeMigrationSteps(cfg, oraclePool, syncTrigger, creReceiverAddr, creForwarder);
        vm.stopBroadcast();
    }
}
