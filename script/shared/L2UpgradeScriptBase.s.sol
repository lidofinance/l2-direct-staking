// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

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
 * Standing OUTSIDE that state machine:
 *
 *   (any stage) — runDeployAutomation()  Actor: Automation Owner  (redeploy the SyncTrigger + CREReceiver
 *                 pair alone, owned by a declared Automation Owner; pool untouched, SYNC_ROLE untouched)
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
 *   - L2_AUTOMATION_OWNER + L2_AUTOMATION_OWNER_PRIVATE_KEY (or L2_AUTOMATION_OWNER_PK) — runDeployAutomation
 *     only; the two MUST be the same account. The address is declared explicitly so the deploy carries its
 *     own intent, and the key cross-check keeps a typo from baking a wrong owner into the SyncTrigger
 *     constructor.
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

    /// @dev Automation Owner signing key, accepting either spelling (`_PK` is what `.env` carries), with
    ///      NO default — mirrors {_envInitialOwnerPrivateKey}. Only {runDeployAutomation} reads it.
    function _envAutomationOwnerPrivateKey() internal view returns (uint256) {
        try vm.envUint("L2_AUTOMATION_OWNER_PRIVATE_KEY") returns (uint256 value) {
            return value;
        } catch {
            return vm.envUint("L2_AUTOMATION_OWNER_PK");
        }
    }

    /// @dev When `L2_DEPLOY_CANARY_PARAMS=true`, {runDeployAutomation} uses the same low min-amount + delay
    ///      overrides as {runDeployTest} (`L2_SYNC_MIN_AMOUNT_TEST` / `L2_SYNC_DELAY_TEST`, defaulting to the
    ///      shared overlay values 0.0002e18 / 60s). Owner, forwarder and author stay production (Automation Owner
    ///      + real CRE forwarder) — only the SyncTrigger timing knobs differ.
    function _envDeployCanaryParams() internal view returns (bool) {
        try vm.envString("L2_DEPLOY_CANARY_PARAMS") returns (string memory value) {
            bytes32 h = keccak256(bytes(value));
            return h == keccak256("true") || h == keccak256("1");
        } catch {
            return false;
        }
    }

    /// @dev Production cfg by default; the canary overlay when {_envDeployCanaryParams} is set.
    function _deployAutomationCfg(address initialOwner, address governanceExecutor, address liquidityOwner)
        internal
        view
        returns (L2UpgradeConfig memory cfg)
    {
        if (_envDeployCanaryParams()) {
            cfg = _canaryTestCfg(initialOwner, governanceExecutor, liquidityOwner);
        } else {
            cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);
        }
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
    ///      neither env set (kept byte-equal to the overlay: 0.0002e18 / 60s). Production values are restored at
    ///      {handoffToLiquidityOwner}.
    function _canaryTestCfg(address initialOwner, address governanceExecutor, address liquidityOwner)
        internal
        view
        returns (L2UpgradeConfig memory cfg)
    {
        cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);
        cfg.minSyncAmount = uint128(vm.envOr("L2_SYNC_MIN_AMOUNT_TEST", uint256(0.0002e18)));
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

    /// @notice Stage 1→2 (Deployer): sweep the test residue back to the deployer (the pool's available
    ///         WETH/wstETH + the SyncTrigger's ENTIRE ETH float), restore production config (real forwarder +
    ///         LOL author + production delay/amounts), and transfer all three contracts to LOL. The trigger
    ///         is handed over empty; fund the production float afterwards (permissionless).
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
        sweepTestResidue(cfg, oraclePool, syncTrigger, deployer);
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

    // ── SYNC_ROLE rotation (CustomSender role admin) ────────────────

    /// @dev The SyncTrigger being RETIRED — the account whose `SYNC_ROLE` this rotation revokes. Required,
    ///      with no on-chain discovery fallback: `CustomSender` is not `AccessControlEnumerable`, so the
    ///      current holder cannot be read off the chain, and OZ `revokeRole` is a silent no-op on a wrong
    ///      address ({repointSyncRole} therefore asserts the address really holds the role).
    ///
    ///      `L2_RETIRED_SYNC_TRIGGER` is read first — that is the variable `.env.<network>` gains once a
    ///      `deploy-automation` run repoints `L2_SYNC_TRIGGER` at the NEW pair. `L2_SYNC_TRIGGER` is the
    ///      fallback, correct on a lane whose redeploy has not happened yet (there the live trigger IS the
    ///      one being retired). On a redeployed lane that carries no retired pin, both would resolve to the
    ///      new address — exactly the accident {repointSyncRole}'s `L2UpgradeSyncRoleHolderUnchanged` gate
    ///      exists to stop, rather than silently de-automating the lane.
    function _envRetiredSyncRole() internal view returns (address) {
        try vm.envAddress("L2_RETIRED_SYNC_TRIGGER") returns (address value) {
            return value;
        } catch {
            return vm.envAddress("L2_SYNC_TRIGGER");
        }
    }

    /// @dev The account that will hold `SYNC_ROLE` after the rotation. Deliberately a DISTINCT variable from
    ///      `L2_SYNC_TRIGGER` so this step never depends on the order in which an operator edits `.env`.
    function _envNextSyncRole() internal view returns (address) {
        return vm.envAddress("L2_SYNC_TRIGGER_NEW");
    }

    /// @dev Set `L2_REPOINT_ALLOW_ANY_TARGET=true` to waive the {_assertSyncRoleTarget} identity guard and
    ///      grant `SYNC_ROLE` to something that is not a lane-matched SyncTrigger. Off by default: the guard
    ///      is the only automated check standing between a mistyped address and an armed `sync()` caller.
    function _envStrictSyncRoleTarget() internal view returns (bool) {
        return !vm.envOr("L2_REPOINT_ALLOW_ANY_TARGET", false);
    }

    /// @notice Rotate `SYNC_ROLE` on this lane's CustomSender from the retired holder to
    ///         `L2_SYNC_TRIGGER_NEW`. Actor: the CustomSender's role admin — `DEFAULT_ADMIN_ROLE`, i.e. the
    ///         Initial Owner until {runFinalize} seals it to the governance executor. Standing OUTSIDE the
    ///         canary state machine: it neither reads nor writes the oracle-pool pointer, the ownership of
    ///         any deployed contract, or the predecessor automations' roles.
    ///
    ///         Two transactions, grant then revoke — see {repointSyncRole} for why that order, and use
    ///         {runPrintRepointSyncRoleCalldata} if the admin needs them batched atomically instead.
    function runRepointSyncRole() public {
        uint256 key = _envInitialOwnerPrivateKey();
        _runRepointSyncRoleBody(vm.addr(key), key);
    }

    /// @notice Same as runRepointSyncRole but impersonates the CustomSender admin (anvil dress rehearsal
    ///         only) — the twin of runActivateUnlocked / runFinalizeUnlocked.
    function runRepointSyncRoleUnlocked() public {
        _runRepointSyncRoleBody(_envInitialOwnerAddress(), 0);
    }

    function _runRepointSyncRoleBody(address admin, uint256 key) internal {
        assertL2ChainId(_expectedChainId());
        L2UpgradeConfig memory cfg =
            _buildConfig(admin, _governanceExecutor(), _envLiquidityOwnerAddress());
        address retiredHolder = _envRetiredSyncRole();
        address nextHolder = _envNextSyncRole();

        console2.log("CustomSender  %s", vm.toString(cfg.customSender));
        console2.log("role admin    %s", vm.toString(admin));
        console2.log("SYNC_ROLE     %s -> %s", vm.toString(retiredHolder), vm.toString(nextHolder));

        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast(admin);
        repointSyncRole(cfg, retiredHolder, nextHolder, admin, _envStrictSyncRoleTarget());
        vm.stopBroadcast();
    }

    /// @notice Read-only companion to {runRepointSyncRole}: run every entry gate against live state and
    ///         print the two `CustomSender` calldatas, so the rotation can be handed to a role admin that
    ///         does not broadcast from this repo — the Initial Owner is an external party today, and after
    ///         {runFinalize} the admin is a bridge executor that can only be reached by a DAO vote. Emitting
    ///         both calls lets them be batched into ONE transaction (multisend / governance action), which
    ///         is the only way to get the zero-length two-holder window the two-transaction broadcast cannot.
    /// @dev The gates are exercised by running the REAL action under `vm.startPrank` with no broadcast, so
    ///      the writes' own guards are what report here. A separate `view` re-implementation of the checks
    ///      would be a second copy, free to drift from the one that actually protects the transactions.
    function runPrintRepointSyncRoleCalldata() public {
        assertL2ChainId(_expectedChainId());
        address admin = _envInitialOwnerAddress();
        L2UpgradeConfig memory cfg =
            _buildConfig(admin, _governanceExecutor(), _envLiquidityOwnerAddress());
        address retiredHolder = _envRetiredSyncRole();
        address nextHolder = _envNextSyncRole();

        // Dry run against live state: no vm.startBroadcast here, so the writes land only in this script's
        // local EVM and no transaction is ever submitted. Every gate reports exactly as on the real run.
        vm.startPrank(admin);
        repointSyncRole(cfg, retiredHolder, nextHolder, admin, _envStrictSyncRoleTarget());
        vm.stopPrank();

        console2.log("Entry gates PASS against live state. Two calls, in this order, from %s:", vm.toString(admin));
        console2.log("TO=%s", vm.toString(cfg.customSender));
        console2.log(
            "DATA_1_GRANT=%s",
            vm.toString(abi.encodeWithSelector(IAccessControl.grantRole.selector, SYNC_ROLE, nextHolder))
        );
        console2.log(
            "DATA_2_REVOKE=%s",
            vm.toString(abi.encodeWithSelector(IAccessControl.revokeRole.selector, SYNC_ROLE, retiredHolder))
        );
        console2.log("VALUE=0");
    }

    // ── Automation-layer redeploy (dedicated Automation Owner) ──────

    error L2UpgradeAutomationOwnerKeyMismatch(address keyAddress, address declaredOwner);

    /// @notice Deploy a FRESH CREReceiver + SyncTrigger pair owned by an explicitly declared Automation
    ///         Owner. The OraclePool is NOT touched — it stays deployed and LOL-owned; this entry point
    ///         exists to move the automation layer alone onto a dedicated owner (docs/automation-owner-redeploy.md
    ///         §S3) without re-running the canary or disturbing the liquidity domain.
    ///
    ///         Actor: the Automation Owner itself — it broadcasts, so it owns the CREReceiver from
    ///         `msg.sender` and {deploySyncInfrastructure}'s transfer branch is a no-op (one owner from
    ///         birth, no in-broadcast ownership hop). It is also passed as the SyncTrigger's `initialOwner`
    ///         and as the CREReceiver's `expectedAuthor` (the CRE workflow author pin), matching the target
    ///         arrangement in DOC.md §4.2 where all three automation slots are the same address.
    ///
    ///         Config: `_buildConfig` (production: 12 h delay, 5/100 ETH min/max amounts) by default, or
    ///         `_canaryTestCfg` when `L2_DEPLOY_CANARY_PARAMS=true` (0.0002 WETH min + 60 s delay — same knobs
    ///         as {runDeployTest}, overridable via `L2_SYNC_MIN_AMOUNT_TEST` / `L2_SYNC_DELAY_TEST`). Either
    ///         way the real per-network `_creForwarder()` pin and Automation Owner ownership are unchanged.
    ///         `fundFloat = false`: the native fee float is funded by a separate, permissionless step
    ///         (`just fund-trigger`, or a bare transfer from anyone) so the deploy and the funding stay
    ///         distinct transactions, exactly as in {runDeployTest}.
    ///
    ///         This deploys ONLY. It does not grant the new trigger SYNC_ROLE and does not revoke the
    ///         predecessor's — that is a separate CustomSender-admin transaction signed by the Initial
    ///         Owner, and until it runs the newly deployed pair is inert.
    ///
    /// @dev The owner is read from `L2_AUTOMATION_OWNER` — required, with NO default and no fallback
    ///      constant, unlike the `_expectedGovernanceExecutor` / `_expectedCREForwarder` /
    ///      `_expectedOldOraclePool` pins. Those are fixed per-network facts; the Automation Owner is a
    ///      migration-time choice. To keep an env-sourced value out of an IRREVERSIBLE constructor
    ///      argument by accident, the declared address is cross-checked against the broadcasting key: a
    ///      typo in either one reverts here rather than deploying a pair owned by the wrong address.
    function runDeployAutomation() public returns (address syncTrigger, address creReceiverAddr) {
        assertL2ChainId(_expectedChainId());

        address automationOwner = vm.envAddress("L2_AUTOMATION_OWNER");
        uint256 ownerKey = _envAutomationOwnerPrivateKey();
        // The declared owner and the signing key must be the same account. Without this, a mistyped
        // L2_AUTOMATION_OWNER deploys a pair owned by an address nobody holds the key to (the SyncTrigger's
        // owner is a constructor argument — unrecoverable), while the broadcast still succeeds.
        if (vm.addr(ownerKey) != automationOwner) {
            revert L2UpgradeAutomationOwnerKeyMismatch(vm.addr(ownerKey), automationOwner);
        }

        L2UpgradeConfig memory cfg = _deployAutomationCfg(
            _envInitialOwnerAddress(), _governanceExecutor(), _envLiquidityOwnerAddress()
        );

        vm.startBroadcast(ownerKey);
        (syncTrigger, creReceiverAddr) =
            deploySyncInfrastructure(cfg, _creForwarder(), automationOwner, automationOwner, false);
        vm.stopBroadcast();

        console2.log("L2_DEPLOY_CANARY_PARAMS=%s", _envDeployCanaryParams() ? "true" : "false");
        console2.log("L2_SYNC_MIN_AMOUNT=%s", vm.toString(cfg.minSyncAmount));
        console2.log("L2_SYNC_DELAY=%s", vm.toString(cfg.minSyncDelay));
        console2.log("L2_SYNC_TRIGGER=%s", vm.toString(syncTrigger));
        console2.log("L2_CRE_RECEIVER=%s", vm.toString(creReceiverAddr));
        console2.log("L2_AUTOMATION_OWNER=%s", vm.toString(automationOwner));
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
