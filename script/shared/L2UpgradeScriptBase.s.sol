// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {L2UpgradeActions} from "script/shared/L2UpgradeActions.s.sol";
import {L1MigrationConstants as L1} from "script/l1/L1MigrationConstants.sol";
import {SyncTrigger} from "src/SyncTrigger.sol";
import {CREReceiver} from "src/cre/CREReceiver.sol";

/**
 * @notice Shared broadcast script for L2 upgrade operations.
 *
 * The migration runs as a canary state machine — the three contracts are deployed owned by the Lido
 * Deployer (with the deployer wired as the CREReceiver forwarder + author so a real sync can be driven),
 * proven end-to-end, then handed to the LOL multisig and sealed to governance:
 *
 *   Stage 0→1 — runDeployTest()  Actor: Lido Deployer  (deploy deployer-owned, test delay/min-amount)
 *   Stage 0→1 — runActivate()    Actor: Initial Owner  (reversible: repoint pool + grant SYNC_ROLE)
 *   Stage  1  — runSimulateSync() Actor: Lido Deployer  (drive CREReceiver.onReport directly)
 *   Stage 1→0 — runRollback()    Actor: Initial Owner  (undo activate — repoint old pool + revoke role)
 *   Stage 1→2 — runHandoff()     Actor: Lido Deployer  (restore production config, transfer to LOL)
 *   Stage 2→3 — runFinalize()    Actor: Initial Owner  (irreversible: revoke old automation, seal admin)
 *
 * Each broadcast step has a read-only verifier (runVerifyTest / runVerifyStage2) and an anvil-rehearsal
 * `*Unlocked` twin that impersonates the Initial Owner.
 *
 * The governance executor, predecessor OraclePool, and CRE forwarder are sourced ONLY from the per-network
 * constants (_expectedGovernanceExecutor / _expectedOldOraclePool / _expectedCREForwarder, cross-checked to
 * the .inputs.yaml anchors by verify-constants-sync) — never from env.
 *
 * Required env:
 *   - L2_LIDO_DEPLOYER_PRIVATE_KEY (deployer-actor steps)
 *   - INITIAL_OWNER_PRIVATE_KEY (initial-owner-actor steps; *Unlocked twins impersonate instead)
 *   - L2_ORACLE_POOL / L2_SYNC_TRIGGER / L2_CRE_RECEIVER (output of runDeployTest; consumed by later steps)
 *   - L2_LIQUIDITY_OWNER (optional, defaults to network LOL multisig)
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
    ///      out (a network with no canonical executor). Production networks override this to their per-chain
    ///      LIDO_L2_GOVERNANCE_EXECUTOR constant; `_governanceExecutor()` reads it directly, so the executor
    ///      is sourced ONLY from the constant (cross-checked to the .inputs.yaml anchor by
    ///      verify-constants-sync), never from env — a wrong env value can no longer be baked into an
    ///      irreversible admin/ownership handover. `pure` like `_expectedChainId` (every network returns a
    ///      constant or the address(0) opt-out; none reads state); an opt-out network makes
    ///      `_governanceExecutor()` revert rather than deploy a zero admin.
    function _expectedGovernanceExecutor() internal pure virtual returns (address) {
        return address(0);
    }

    /// @dev Returns the fixed, Chainlink-published CRE Forwarder for this network, or address(0) to opt
    ///      out (e.g. before Chainlink has published the forwarder for a network). Mirrors
    ///      `_expectedGovernanceExecutor`: the forwarder is a per-network constant (not an operator choice),
    ///      so `_creForwarder()` reads this value directly — `L2_CRE_FORWARDER` is never consulted. The
    ///      forwarder is baked IMMUTABLY into CREReceiver, so a stale/mistyped value would make every
    ///      CRE-triggered sync silently rejected by the real forwarder; sourcing it from the constant
    ///      (cross-checked by verify-constants-sync) removes that footgun. An opt-out network (address(0))
    ///      makes `_creForwarder()` revert rather than deploy a CREReceiver bound to the zero forwarder.
    function _expectedCREForwarder() internal pure virtual returns (address) {
        return address(0);
    }

    /// @dev Returns the known predecessor OraclePool for this network — the pool `rollback` repoints
    ///      CustomSender back to — or address(0) to opt out. Production networks override this to their
    ///      per-chain L2_OLD_ORACLE_POOL constant (the same value verify-constants-sync pins to the
    ///      l2OldOraclePool state-mate anchor); `_oldOraclePool()` reads it directly, so the pool to restore
    ///      is sourced ONLY from the constant, never env — a wrong value can no longer repoint the sender at
    ///      an arbitrary pool during the (Initial-Owner-only) rollback. Mirrors `_expectedGovernanceExecutor`.
    function _expectedOldOraclePool() internal pure virtual returns (address) {
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

    error L2UpgradeGovernanceExecutorNotPinned();

    /// @dev Returns this network's governance executor — the per-network LIDO_L2_GOVERNANCE_EXECUTOR
    ///      constant pinned via `_expectedGovernanceExecutor()` (cross-checked to the l2GovernanceExecutor
    ///      .inputs.yaml anchor by verify-constants-sync). It is NEVER read from env: the executor is a
    ///      fixed per-network address, so sourcing it from the constant removes the class of bug where a
    ///      wrong env value is baked into the irreversible admin / ProxyAdmin handover (the historical
    ///      wrong Base/Linea executor). A network that has not pinned it (address(0)) reverts rather than
    ///      hand ownership to the zero address.
    function _governanceExecutor() internal pure returns (address governanceExecutor) {
        governanceExecutor = _expectedGovernanceExecutor();
        if (governanceExecutor == address(0)) revert L2UpgradeGovernanceExecutorNotPinned();
    }

    error L2UpgradeCREForwarderNotPinned();

    /// @dev Returns the Chainlink CRE Forwarder for this network — the per-network CRE_FORWARDER constant
    ///      pinned via `_expectedCREForwarder()` (a fixed, Chainlink-published address, cross-checked to the
    ///      l2CreForwarder .inputs.yaml anchor by verify-constants-sync). NEVER read from env: the forwarder
    ///      is baked IMMUTABLY into CREReceiver, and a stale/mistyped value would make the real forwarder
    ///      silently reject every CRE-triggered sync. Reverts if the network left it unpinned. Same
    ///      source-of-truth discipline as `_governanceExecutor`.
    function _creForwarder() internal pure returns (address creForwarder) {
        creForwarder = _expectedCREForwarder();
        if (creForwarder == address(0)) revert L2UpgradeCREForwarderNotPinned();
    }

    error L2UpgradeOldOraclePoolNotPinned();

    /// @dev Returns the predecessor OraclePool `rollback` restores — the per-network L2_OLD_ORACLE_POOL
    ///      constant pinned via `_expectedOldOraclePool()` (cross-checked to the l2OldOraclePool .inputs.yaml
    ///      anchor by verify-constants-sync). NEVER read from env, so a wrong value can't repoint the sender
    ///      at an arbitrary pool during the (Initial-Owner-only) rollback. Reverts if the network left it
    ///      unpinned. Same source-of-truth discipline as `_governanceExecutor`.
    function _oldOraclePool() internal pure returns (address oldOraclePool) {
        oldOraclePool = _expectedOldOraclePool();
        if (oldOraclePool == address(0)) revert L2UpgradeOldOraclePoolNotPinned();
    }

    // ── Canary test flow (deployer-simulated CRE) ────────────────────

    /// @dev Canary cfg = production cfg with the test min-amount + delay overrides applied (low values so a
    ///      small WETH seed triggers a sync promptly). The override values are the `syncMinAmount` /
    ///      `syncDelay` anchors in the shared state-mate overlay `config/state/l2.inputs.test-stage.yaml`,
    ///      supplied via `L2_SYNC_MIN_AMOUNT_TEST` / `L2_SYNC_DELAY_TEST` by the canary recipes (deploy-test /
    ///      verify-test). The inline literals here are only a fallback for a direct `forge` invocation with
    ///      neither env set (kept byte-equal to the overlay: 0.05e18 / 60s). Production values are restored at
    ///      {handoffToLiquidityOwner}.
    function _canaryTestCfg(address initialOwner, address governanceExecutor, address liquidityOwner)
        internal
        view
        returns (L2UpgradeConfig memory cfg)
    {
        cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);
        cfg.minSyncAmount = uint128(vm.envOr("L2_SYNC_MIN_AMOUNT_TEST", uint256(0.05e18)));
        cfg.minSyncDelay = uint48(vm.envOr("L2_SYNC_DELAY_TEST", uint256(1 minutes)));
    }

    /// @notice Stage 0→1 (Deployer): deploy pool + SyncTrigger + CREReceiver owned by the Lido Deployer,
    ///         with the deployer as the CREReceiver forwarder AND author so it can drive onReport directly.
    function runDeployTest() public returns (address oraclePool, address syncTrigger, address creReceiverAddr) {
        assertL2ChainId(_expectedChainId());

        uint256 deployerKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        L2UpgradeConfig memory cfg =
            _canaryTestCfg(_envInitialOwnerAddress(), _governanceExecutor(), _envLiquidityOwnerAddress());

        // fundFloat = false: the SyncTrigger's native fee float is funded by a SEPARATE operator step
        // (`just fund-trigger` → runFundTrigger), keeping deploy and funding as distinct transactions.
        vm.startBroadcast(deployerKey);
        oraclePool = address(deployPool(cfg, deployer));
        (syncTrigger, creReceiverAddr) = deploySyncInfrastructure(cfg, deployer, deployer, deployer, false);
        vm.stopBroadcast();

        console2.log("L2_ORACLE_POOL=%s", vm.toString(oraclePool));
        console2.log("L2_SYNC_TRIGGER=%s", vm.toString(syncTrigger));
        console2.log("L2_CRE_RECEIVER=%s", vm.toString(creReceiverAddr));
        console2.log("L2_TEST_DEPLOYER=%s", vm.toString(deployer));
    }

    /// @notice Stage 0→1 (Deployer): fund the deployed SyncTrigger's native fee float from the Lido Deployer.
    ///         Split out of {runDeployTest} so the deploy and the float funding are distinct transactions; run
    ///         it ONCE before `verify-test`/`simulate-sync` (both require the funded float). Funding is
    ///         permissionless; {fundSyncTrigger} sends the FULL `syncTriggerInitialFloat` (not a top-up — a
    ///         re-run over-funds, excess being owner-only `sweep`-recoverable) and reverts only if that
    ///         configured float is below the worst-case floor.
    function runFundTrigger() public {
        assertL2ChainId(_expectedChainId());
        uint256 deployerKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");
        L2UpgradeConfig memory cfg =
            _canaryTestCfg(_envInitialOwnerAddress(), _governanceExecutor(), _envLiquidityOwnerAddress());

        vm.startBroadcast(deployerKey);
        fundSyncTrigger(syncTrigger, cfg);
        vm.stopBroadcast();

        console2.log("Funded SyncTrigger %s float to %s wei", vm.toString(syncTrigger), uint256(cfg.syncTriggerInitialFloat));
    }

    /// @notice Stage 0→1 verify (read-only): canary infra deployed + owned by the deployer, pool repointed,
    ///         SYNC_ROLE granted, seal not run. Run before the simulated sync (it asserts the full float).
    function runVerifyTest() public view {
        assertL2ChainId(_expectedChainId());
        L2UpgradeConfig memory cfg =
            _canaryTestCfg(_envInitialOwnerAddress(), _governanceExecutor(), _envLiquidityOwnerAddress());
        verifyCanaryStage1(
            cfg,
            vm.envAddress("L2_ORACLE_POOL"),
            vm.envAddress("L2_SYNC_TRIGGER"),
            vm.envAddress("L2_CRE_RECEIVER"),
            vm.envAddress("L2_TEST_DEPLOYER")
        );
    }

    /// @notice Stage 0→1 (Initial Owner): reversible activation — repoint CustomSender at the new pool and
    ///         grant the new SyncTrigger SYNC_ROLE; admin + old automation untouched (so 1→0 is clean).
    function runActivate() public {
        uint256 key = _envInitialOwnerPrivateKey();
        _runActivateBody(vm.addr(key), key);
    }

    /// @notice Same as runActivate but impersonates the Initial Owner (anvil dress rehearsal only).
    function runActivateUnlocked() public {
        _runActivateBody(_envInitialOwnerAddress(), 0);
    }

    function _runActivateBody(address initialOwner, uint256 key) internal {
        assertL2ChainId(_expectedChainId());
        L2UpgradeConfig memory cfg =
            _buildConfig(initialOwner, _governanceExecutor(), _envLiquidityOwnerAddress());
        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast(initialOwner);
        activateForTesting(cfg, vm.envAddress("L2_ORACLE_POOL"), vm.envAddress("L2_SYNC_TRIGGER"));
        vm.stopBroadcast();
    }

    /// @notice Stage 1 (Deployer): simulate a CRE sync by calling CREReceiver.onReport directly — the
    ///         deployer is the configured forwarder + author, so the report passes both gates and runs
    ///         onReport → triggerSync → CustomSender.sync. Seed the pool with WETH (and wait the delay) first.
    function runSimulateSync() public {
        assertL2ChainId(_expectedChainId());
        uint256 deployerKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");
        address creReceiver = vm.envAddress("L2_CRE_RECEIVER");

        // Keystone metadata layout: bytes32 workflowId | bytes10 workflowName | address workflowOwner.
        // workflowOwner must equal CREReceiver.expectedAuthor (= the deployer during the test).
        bytes memory metadata = abi.encodePacked(bytes32(0), bytes10(0), deployer);
        // report = abi.encode(target, data); data must be EXACTLY the 4-byte nullary triggerSync selector.
        bytes memory report = abi.encode(syncTrigger, abi.encodePacked(SyncTrigger.triggerSync.selector));

        vm.startBroadcast(deployerKey);
        CREReceiver(payable(creReceiver)).onReport(metadata, report);
        vm.stopBroadcast();
    }

    /// @notice Stage 1→0 (Initial Owner): roll back the activation — repoint CustomSender at the old pool
    ///         and revoke the new SyncTrigger's SYNC_ROLE. The pool to restore is the per-network
    ///         `_expectedOldOraclePool()` pin (the per-network L2_OLD_ORACLE_POOL constant, not env).
    function runRollback() public {
        uint256 key = _envInitialOwnerPrivateKey();
        _runRollbackBody(vm.addr(key), key);
    }

    /// @notice Same as runRollback but impersonates the Initial Owner (anvil dress rehearsal only).
    function runRollbackUnlocked() public {
        _runRollbackBody(_envInitialOwnerAddress(), 0);
    }

    function _runRollbackBody(address initialOwner, uint256 key) internal {
        assertL2ChainId(_expectedChainId());
        L2UpgradeConfig memory cfg =
            _buildConfig(initialOwner, _governanceExecutor(), _envLiquidityOwnerAddress());
        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast(initialOwner);
        rollbackActivation(cfg, _oldOraclePool(), vm.envAddress("L2_SYNC_TRIGGER"));
        vm.stopBroadcast();
    }

    /// @notice Stage 1→2 (Deployer): sweep test residue, restore production config (real forwarder + LOL
    ///         author + production delay/amounts), top up the float, and transfer all three contracts to LOL.
    function runHandoff() public {
        assertL2ChainId(_expectedChainId());
        uint256 deployerKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        L2UpgradeConfig memory cfg =
            _buildConfig(_envInitialOwnerAddress(), _governanceExecutor(), _envLiquidityOwnerAddress());
        address oraclePool = vm.envAddress("L2_ORACLE_POOL");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");
        address creReceiver = vm.envAddress("L2_CRE_RECEIVER");

        vm.startBroadcast(deployerKey);
        sweepTestResidue(cfg, oraclePool, deployer);
        handoffToLiquidityOwner(cfg, oraclePool, syncTrigger, creReceiver, _creForwarder());
        vm.stopBroadcast();
    }

    /// @notice Stage 2 verify (read-only): post-handoff, pre-seal — infra LOL-owned + production-configured,
    ///         pool active, SYNC_ROLE held, Initial Owner still admin.
    function runVerifyStage2() public view {
        assertL2ChainId(_expectedChainId());
        L2UpgradeConfig memory cfg =
            _buildConfig(_envInitialOwnerAddress(), _governanceExecutor(), _envLiquidityOwnerAddress());
        verifyCanaryStage2(
            cfg,
            vm.envAddress("L2_ORACLE_POOL"),
            vm.envAddress("L2_SYNC_TRIGGER"),
            vm.envAddress("L2_CRE_RECEIVER"),
            _creForwarder()
        );
    }

    /// @notice Stage 2→3 (Initial Owner): the irreversible governance seal — revoke old automation(s),
    ///         migrate CustomSender admin + L2 ProxyAdmin to the governance executor.
    function runFinalize() public {
        uint256 key = _envInitialOwnerPrivateKey();
        _runFinalizeBody(vm.addr(key), key);
    }

    /// @notice Same as runFinalize but impersonates the Initial Owner (anvil dress rehearsal only).
    function runFinalizeUnlocked() public {
        _runFinalizeBody(_envInitialOwnerAddress(), 0);
    }

    function _runFinalizeBody(address initialOwner, uint256 key) internal {
        assertL2ChainId(_expectedChainId());
        L2UpgradeConfig memory cfg =
            _buildConfig(initialOwner, _governanceExecutor(), _envLiquidityOwnerAddress());
        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast(initialOwner);
        finalizeGovernanceSeal(
            cfg,
            vm.envAddress("L2_ORACLE_POOL"),
            vm.envAddress("L2_SYNC_TRIGGER"),
            vm.envAddress("L2_CRE_RECEIVER"),
            _creForwarder()
        );
        vm.stopBroadcast();
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

}
