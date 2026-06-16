// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";
import {ICustomSender} from "@csr/interfaces/ICustomSender.sol";
import {IOraclePool} from "@csr/interfaces/IOraclePool.sol";
import {SyncTrigger} from "src/SyncTrigger.sol";
import {ISyncTrigger} from "src/interfaces/ISyncTrigger.sol";
import {CREReceiver} from "src/cre/CREReceiver.sol";

/**
 * @notice Network-agnostic L2 upgrade actions for CSR lane migration.
 * @dev Shared logic imported by network-specific scripts and tests.
 *      Each network provides its own config (constants + pre-encoded bridge fees).
 */
contract L2UpgradeActions {
    // Roles — identical across all networks.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant SYNC_ROLE = keccak256("SYNC_ROLE");

    error L2UpgradeInvalidAddress();
    error L2UpgradeInvalidChainSelector();
    error L2UpgradeWrongChain(uint256 actualChainId, uint256 expectedChainId);
    error L2UpgradePostConditionFailed(string what);
    error L2UpgradeFloatBelowFloor(uint256 initialFloat, uint256 floor);

    struct L2UpgradeConfig {
        address initialOwner;
        address governanceExecutor;
        address liquidityOwner;
        address customSender;
        address proxyAdmin;
        address tokenIn;
        address tokenOut;
        address priceOracle;
        uint96 fee;
        uint64 destChainSelector;
        uint128 destinationMaxFee;
        bool destinationPayInLink;
        uint32 destinationGasLimit;
        bytes feeDtoO; // Pre-encoded bridge fee (Optimism, Arbitrum, etc.)
        uint128 minSyncAmount;
        uint128 maxSyncAmount;
        uint48 minSyncDelay;
        uint128 syncTriggerInitialFloat; // Native ETH funded into the SyncTrigger at deploy — it fronts maxFee+feeDtoO per sync from its own balance (README §Funding the float)
        address oldChainlinkAutomation; // Old Chainlink Automation to revoke SYNC_ROLE from (address(0) to skip)
        address oldGelatoAutomation; // Old Gelato automation, Linea only (address(0) to skip)
    }

    event L2OraclePoolDeployed(address indexed oraclePool, address indexed owner);
    event L2SenderAdminMigrated(address indexed customSender, address indexed previousAdmin, address indexed newAdmin);
    event L2ProxyAdminOwnershipTransferred(
        address indexed proxyAdmin, address indexed previousOwner, address indexed newOwner
    );
    event L2OraclePoolSet(address indexed customSender, address indexed oraclePool);
    event L2SyncTriggerDeployed(address indexed syncTrigger, address indexed customSender, address indexed owner);
    event L2CREReceiverDeployed(address indexed creReceiver, address indexed creForwarder);
    event L2SyncRoleGranted(address indexed customSender, address indexed syncTrigger);
    event L2SyncRoleRevoked(address indexed customSender, address indexed oldAutomation);
    event L2SyncTriggerConfigured(
        address indexed syncTrigger, uint128 minSyncAmount, uint128 maxSyncAmount, uint48 minSyncDelay
    );
    event L2SyncTriggerOwnershipTransferred(
        address indexed syncTrigger, address indexed previousOwner, address indexed newOwner
    );
    event L2SyncTriggerForwarderSet(address indexed syncTrigger, address indexed forwarder);
    event L2SyncTriggerFunded(address indexed syncTrigger, uint256 amount);
    event L2CREReceiverOwnershipTransferred(
        address indexed creReceiver, address indexed previousOwner, address indexed newOwner
    );

    function _requireNonZeroL2(address value) private pure {
        if (value == address(0)) revert L2UpgradeInvalidAddress();
    }

    function _requireL2PostCondition(bool ok, string memory key) private pure {
        if (!ok) revert L2UpgradePostConditionFailed(key);
    }

    /// @dev Asserts the script is broadcasting to the intended L2 chain. Guards against `L2_RPC_URL`
    ///      pointing at the wrong network (dangerous because L2 proxy addresses often match across OP-stack chains).
    function assertL2ChainId(uint256 expectedChainId) public view {
        if (block.chainid != expectedChainId) {
            revert L2UpgradeWrongChain(block.chainid, expectedChainId);
        }
    }

    function deployPool(L2UpgradeConfig memory cfg) public returns (PausableImmutableOraclePool newPool) {
        _requireNonZeroL2(cfg.liquidityOwner);
        _requireNonZeroL2(cfg.customSender);
        _requireNonZeroL2(cfg.tokenIn);
        _requireNonZeroL2(cfg.tokenOut);
        _requireNonZeroL2(cfg.priceOracle);

        newPool = new PausableImmutableOraclePool(
            cfg.customSender, cfg.tokenIn, cfg.tokenOut, cfg.priceOracle, cfg.fee, cfg.liquidityOwner
        );

        emit L2OraclePoolDeployed(address(newPool), cfg.liquidityOwner);
    }

    function deploySyncTrigger(L2UpgradeConfig memory cfg, address syncTriggerOwner)
        public
        returns (SyncTrigger syncTrigger)
    {
        _requireNonZeroL2(syncTriggerOwner);
        _requireNonZeroL2(cfg.customSender);
        if (cfg.destChainSelector == 0) revert L2UpgradeInvalidChainSelector();

        syncTrigger = new SyncTrigger(cfg.customSender, cfg.destChainSelector, syncTriggerOwner);
        emit L2SyncTriggerDeployed(address(syncTrigger), cfg.customSender, syncTriggerOwner);
    }

    function deployCREReceiver(
        address creForwarder,
        address expectedAuthor,
        address allowedTarget,
        bytes4 allowedSelector
    ) public returns (CREReceiver receiver) {
        _requireNonZeroL2(creForwarder);
        _requireNonZeroL2(expectedAuthor);
        receiver = new CREReceiver(creForwarder, expectedAuthor, allowedTarget, allowedSelector);
        emit L2CREReceiverDeployed(address(receiver), creForwarder);
    }

    function transferCREReceiverOwnership(address creReceiver, address newOwner) public {
        _requireNonZeroL2(creReceiver);
        _requireNonZeroL2(newOwner);

        address previousOwner = Ownable(creReceiver).owner();
        Ownable(creReceiver).transferOwnership(newOwner);
        emit L2CREReceiverOwnershipTransferred(creReceiver, previousOwner, newOwner);
    }

    /**
     * @notice Deploy SyncTrigger + CREReceiver, configure, wire forwarder, and transfer ownership.
     * @dev Shared by production scripts, Sepolia script, and fork tests. Pool must be deployed separately.
     */
    function deploySyncInfrastructure(
        L2UpgradeConfig memory cfg,
        address syncTriggerOwner,
        address creForwarder,
        address expectedAuthor
    ) public returns (address syncTrigger, address creReceiverAddr) {
        SyncTrigger st = deploySyncTrigger(cfg, syncTriggerOwner);
        configureSyncTrigger(address(st), cfg);
        CREReceiver cr = deployCREReceiver(
            creForwarder,
            expectedAuthor,
            address(st),
            ISyncTrigger.triggerSync.selector
        );
        setSyncTriggerForwarder(address(st), address(cr));
        transferSyncTriggerOwnership(address(st), cfg.liquidityOwner);
        transferCREReceiverOwnership(address(cr), cfg.liquidityOwner);
        fundSyncTrigger(address(st), cfg);

        syncTrigger = address(st);
        creReceiverAddr = address(cr);

        _assertSyncInfrastructure(cfg, syncTrigger, creReceiverAddr, creForwarder, expectedAuthor);
    }

    /**
     * @notice Fund the SyncTrigger's initial native-ETH fee float from the calling broadcaster.
     * @dev The trigger fronts `maxFee + feeDtoO` per sync FROM ITS OWN BALANCE (the CRE forwarder
     *      call carries no value), so an unfunded trigger reverts its first sync with a bare EVM
     *      balance failure — see README §Funding the float. The configured float must cover at
     *      least one worst-case sync; the floor mirrors `SyncTrigger.triggerSync`'s value math.
     *      Funding is permissionless, but recovering excess is `sweep()` = owner-only, so the
     *      constant should stay floor + bounded runway, not "generous".
     */
    function fundSyncTrigger(address syncTrigger, L2UpgradeConfig memory cfg) public {
        _requireNonZeroL2(syncTrigger);

        (uint256 feeAmountDtoO, bool payInLinkDtoO) = FeeCodec.decodeFeeMemory(cfg.feeDtoO);
        // floor mirrors the worst-case native value SyncTrigger.triggerSync fronts: the OtoD cap plus the
        // DtoO bridge fee, each counted only when paid in native (not LINK). NOTE: this validates
        // float >= the CONFIGURED cap, NOT float >= the LIVE CCIP router fee. Whether destinationMaxFee
        // itself sits above the live ccipReceive fee is a separate config-adequacy question, validated
        // off-chain via the fee-measurement recipe (README §Fee-denomination); a cap set below the live
        // fee would pass this floor yet revert inside CCIPSenderUpgradeable at sync time.
        uint256 floor = (cfg.destinationPayInLink ? 0 : cfg.destinationMaxFee) + (payInLinkDtoO ? 0 : feeAmountDtoO);
        if (cfg.syncTriggerInitialFloat < floor) {
            revert L2UpgradeFloatBelowFloor(cfg.syncTriggerInitialFloat, floor);
        }

        (bool ok,) = payable(syncTrigger).call{value: cfg.syncTriggerInitialFloat}("");
        _requireL2PostCondition(ok, "syncTrigger funding transfer");
        emit L2SyncTriggerFunded(syncTrigger, cfg.syncTriggerInitialFloat);
    }

    /// @dev Sanity checks the Stage 1 deploy; fails the broadcast if anything is off.
    function _assertSyncInfrastructure(
        L2UpgradeConfig memory cfg,
        address syncTrigger,
        address creReceiverAddr,
        address creForwarder,
        address expectedAuthor
    ) private view {
        CREReceiver cr = CREReceiver(payable(creReceiverAddr));
        ISyncTrigger st = ISyncTrigger(syncTrigger);
        // pin the trigger to the real CustomSender. A typo'd/wrong syncTrigger address would
        // not have SENDER pointing at this CustomSender, so this catches a mis-wired trigger before
        // it is granted SYNC_ROLE (and, via the Stage-2 precondition, before any irreversible handover).
        _requireL2PostCondition(st.SENDER() == cfg.customSender, "syncTrigger SENDER");
        _requireL2PostCondition(st.getForwarder() == creReceiverAddr, "syncTrigger forwarder");
        _requireL2PostCondition(Ownable(syncTrigger).owner() == cfg.liquidityOwner, "syncTrigger owner");
        // operational parameters — verified IN-broadcast (Stage 1) and re-checked as a Stage-2
        // precondition. A typo in a MigrationConstants value (e.g. a gas-limit of 100 instead of
        // 1_000_000, a wrong selector, or a mis-encoded fee) is written by configureSyncTrigger without
        // reverting, so without these reads the deploy looks green and the defect only surfaces if the
        // operator separately runs verifyStage1 — or, worse, after go-live when sync() OOGs/reverts.
        _requireL2PostCondition(st.DEST_CHAIN_SELECTOR() == cfg.destChainSelector, "syncTrigger DEST_CHAIN_SELECTOR");
        _requireL2PostCondition(st.WNATIVE() == cfg.tokenIn, "syncTrigger WNATIVE");
        _requireL2PostCondition(st.getDelay() == cfg.minSyncDelay, "syncTrigger delay");
        (uint128 minAmount, uint128 maxAmount) = st.getAmounts();
        _requireL2PostCondition(minAmount == cfg.minSyncAmount, "syncTrigger minAmount");
        _requireL2PostCondition(maxAmount == cfg.maxSyncAmount, "syncTrigger maxAmount");
        _requireL2PostCondition(keccak256(st.getFeeDtoO()) == keccak256(cfg.feeDtoO), "syncTrigger feeDtoO");
        _requireL2PostCondition(
            keccak256(st.getFeeOtoD())
                == keccak256(FeeCodec.encodeCCIP(cfg.destinationMaxFee, cfg.destinationPayInLink, cfg.destinationGasLimit)),
            "syncTrigger feeOtoD"
        );
        _requireL2PostCondition(cr.getForwarder() == creForwarder, "creReceiver forwarder");
        _requireL2PostCondition(cr.getExpectedAuthor() == expectedAuthor, "creReceiver expectedAuthor");
        _requireL2PostCondition(
            cr.isCallAllowed(syncTrigger, ISyncTrigger.triggerSync.selector),
            "creReceiver allow-list seed"
        );
        _requireL2PostCondition(Ownable(creReceiverAddr).owner() == cfg.liquidityOwner, "creReceiver owner");
        // The float can only be drained by syncs, and no sync can run before Stage 2 grants
        // SYNC_ROLE — so between deploy and Stage 2 the balance must still hold the full float.
        _requireL2PostCondition(syncTrigger.balance >= cfg.syncTriggerInitialFloat, "syncTrigger fee float");
    }

    /**
     * @notice Read-only verification that Stage 1 deploy is complete and correct, and Stage 2 has NOT yet run.
     * @dev Reverts with a descriptive key on any mismatch. Callable by anyone after `runDeploy` and before `runMigrate`.
     *      Broader than `_assertSyncInfrastructure` (which is enforced inside the deploy broadcast):
     *      also checks OraclePool immutables, SyncTrigger configuration, and Stage-2-hasn't-run guards.
     */
    function verifyStage1(
        L2UpgradeConfig memory cfg,
        address oraclePool,
        address syncTrigger,
        address creReceiverAddr,
        address creForwarder,
        address expectedAuthor
    ) public view {
        _requireNonZeroL2(oraclePool);
        _requireNonZeroL2(syncTrigger);
        _requireNonZeroL2(creReceiverAddr);

        // Fail-fast guardrails: surface "Stage 2 already ran" before the deploy-correctness reads below,
        // since verifying a post-Stage-2 state against a pre-Stage-2 expectation is meaningless.
        _requireL2PostCondition(
            ICustomSender(cfg.customSender).getOraclePool() != oraclePool,
            "stage 2 already ran: CustomSender.getOraclePool() already points at the new pool"
        );
        _requireL2PostCondition(
            !IAccessControl(cfg.customSender).hasRole(SYNC_ROLE, syncTrigger),
            "stage 2 already ran: SYNC_ROLE already granted to the new SyncTrigger"
        );
        // Pool/trigger-INDEPENDENT tripwire: the two guards above key on the specific (pool, trigger)
        // passed in, so if runDeploy ran twice and Stage 2 completed against a DIFFERENT pair, verifying
        // the orphaned first deployment would slip past them. The DEFAULT_ADMIN_ROLE handover is global
        // to the CustomSender — pre-Stage-2 the executor does NOT yet hold it — so this catches a
        // completed Stage 2 regardless of which pool/trigger it targeted. (initialOwner != executor by
        // construction, so the executor cannot already hold admin pre-migration.)
        _requireL2PostCondition(
            !IAccessControl(cfg.customSender).hasRole(DEFAULT_ADMIN_ROLE, cfg.governanceExecutor),
            "stage 2 already ran: governanceExecutor already holds DEFAULT_ADMIN_ROLE"
        );

        _assertSyncInfrastructure(cfg, syncTrigger, creReceiverAddr, creForwarder, expectedAuthor);

        IOraclePool pool = IOraclePool(oraclePool);
        _requireL2PostCondition(pool.SENDER() == cfg.customSender, "oraclePool SENDER");
        _requireL2PostCondition(pool.TOKEN_IN() == cfg.tokenIn, "oraclePool TOKEN_IN");
        _requireL2PostCondition(pool.TOKEN_OUT() == cfg.tokenOut, "oraclePool TOKEN_OUT");
        _requireL2PostCondition(pool.getOracle() == cfg.priceOracle, "oraclePool oracle");
        _requireL2PostCondition(pool.getFee() == cfg.fee, "oraclePool fee");
        _requireL2PostCondition(Ownable(oraclePool).owner() == cfg.liquidityOwner, "oraclePool owner");
        _requireL2PostCondition(!PausableImmutableOraclePool(oraclePool).paused(), "oraclePool paused");

        // SyncTrigger wiring + operational params (SENDER/forwarder/owner, DEST_CHAIN_SELECTOR, WNATIVE,
        // delay, amounts, feeDtoO, feeOtoD) and the CREReceiver checks are asserted inside
        // _assertSyncInfrastructure above, so they are not repeated here.
    }

    function migrateSenderAdmin(L2UpgradeConfig memory cfg) public {
        _requireNonZeroL2(cfg.initialOwner);
        _requireNonZeroL2(cfg.governanceExecutor);
        _requireNonZeroL2(cfg.customSender);

        IAccessControl sender = IAccessControl(cfg.customSender);
        // Precondition: cfg.initialOwner must actually hold DEFAULT_ADMIN_ROLE before we revoke it.
        // OZ `revokeRole` is a SILENT no-op when the account lacks the role, so a wrong cfg.initialOwner
        // (env typo, wrong key, or silent fallback to L1.INITIAL_OWNER) would revoke nothing while the
        // `!hasRole(initialOwner)` postcondition (in _assertMigrationSteps) passes trivially — leaving
        // the REAL admin in place and the migration falsely declared complete. Assert the hold up-front
        // so a mis-set initialOwner fails loudly here rather than handing over a phantom revoke.
        _requireL2PostCondition(
            sender.hasRole(DEFAULT_ADMIN_ROLE, cfg.initialOwner), "initial owner is not the current admin"
        );

        sender.grantRole(DEFAULT_ADMIN_ROLE, cfg.governanceExecutor);
        sender.revokeRole(DEFAULT_ADMIN_ROLE, cfg.initialOwner);
        emit L2SenderAdminMigrated(cfg.customSender, cfg.initialOwner, cfg.governanceExecutor);
    }

    function transferProxyAdminOwnership(L2UpgradeConfig memory cfg) public {
        _requireNonZeroL2(cfg.initialOwner);
        _requireNonZeroL2(cfg.governanceExecutor);
        _requireNonZeroL2(cfg.proxyAdmin);

        // read the actual on-chain owner rather than assuming cfg.initialOwner, mirroring
        // transferSyncTriggerOwnership / transferCREReceiverOwnership — so the emitted previousOwner is
        // truthful for off-chain provenance even if the ProxyAdmin was transferred out-of-band beforehand.
        address previousOwner = Ownable(cfg.proxyAdmin).owner();
        Ownable(cfg.proxyAdmin).transferOwnership(cfg.governanceExecutor);
        emit L2ProxyAdminOwnershipTransferred(cfg.proxyAdmin, previousOwner, cfg.governanceExecutor);
    }

    function setOraclePool(address customSender, address oraclePool) public {
        _requireNonZeroL2(customSender);
        _requireNonZeroL2(oraclePool);

        ICustomSender(customSender).setOraclePool(oraclePool);
        emit L2OraclePoolSet(customSender, oraclePool);
    }

    function grantSyncRole(address customSender, address syncTrigger) public {
        _requireNonZeroL2(customSender);
        _requireNonZeroL2(syncTrigger);

        IAccessControl(customSender).grantRole(SYNC_ROLE, syncTrigger);
        emit L2SyncRoleGranted(customSender, syncTrigger);
    }

    function revokeSyncRole(address customSender, address oldAutomation) public {
        _requireNonZeroL2(customSender);
        _requireNonZeroL2(oldAutomation);

        IAccessControl(customSender).revokeRole(SYNC_ROLE, oldAutomation);
        emit L2SyncRoleRevoked(customSender, oldAutomation);
    }

    function configureSyncTrigger(address syncTrigger, L2UpgradeConfig memory cfg) public {
        _requireNonZeroL2(syncTrigger);

        ISyncTrigger trigger = ISyncTrigger(syncTrigger);
        trigger.setFeeOtoD(
            FeeCodec.encodeCCIP(cfg.destinationMaxFee, cfg.destinationPayInLink, cfg.destinationGasLimit)
        );
        trigger.setFeeDtoO(cfg.feeDtoO);
        trigger.setAmounts(cfg.minSyncAmount, cfg.maxSyncAmount);
        trigger.setDelay(cfg.minSyncDelay);
        emit L2SyncTriggerConfigured(syncTrigger, cfg.minSyncAmount, cfg.maxSyncAmount, cfg.minSyncDelay);
    }

    function transferSyncTriggerOwnership(address syncTrigger, address newOwner) public {
        _requireNonZeroL2(syncTrigger);
        _requireNonZeroL2(newOwner);

        address previousOwner = Ownable(syncTrigger).owner();
        Ownable(syncTrigger).transferOwnership(newOwner);
        emit L2SyncTriggerOwnershipTransferred(syncTrigger, previousOwner, newOwner);
    }

    function executeMigrationSteps(
        L2UpgradeConfig memory cfg,
        address newPool,
        address newSyncTrigger,
        address creReceiver,
        address creForwarder
    ) public {
        // refuse to run Stage 2 against a half-configured or mis-wired Stage 1. This re-asserts
        // the full sync-infrastructure wiring (SyncTrigger SENDER/forwarder/owner, CREReceiver
        // forwarder/expectedAuthor/allow-list/owner, fee float) BEFORE any irreversible write below
        // (oracle-pool repoint, SYNC_ROLE grant, admin revoke, ProxyAdmin handover). It reads only
        // SyncTrigger/CREReceiver state that Stage 2 never mutates, so it is safe as a precondition.
        // Also subsumes the SENDER/forwarder wiring check before SYNC_ROLE is granted.
        //
        // expectedAuthor is pinned to cfg.liquidityOwner here, matching Stage 1: _deployAll always
        // constructs the CREReceiver with expectedAuthor == cfg.liquidityOwner (the LOL Safe / CRE
        // workflow owner — ADR-0001, DOC.md §3.2). If a future caller deploys Stage 1 with a DIFFERENT
        // expectedAuthor, this precondition reverts ("creReceiver expectedAuthor") — a loud, safe block,
        // not a silent mismatch — so the two must be kept consistent.
        _assertSyncInfrastructure(cfg, newSyncTrigger, creReceiver, creForwarder, cfg.liquidityOwner);

        setOraclePool(cfg.customSender, newPool);
        grantSyncRole(cfg.customSender, newSyncTrigger);
        if (cfg.oldChainlinkAutomation != address(0)) {
            revokeSyncRole(cfg.customSender, cfg.oldChainlinkAutomation);
        }
        if (cfg.oldGelatoAutomation != address(0)) {
            revokeSyncRole(cfg.customSender, cfg.oldGelatoAutomation);
        }
        migrateSenderAdmin(cfg);
        transferProxyAdminOwnership(cfg);

        _assertMigrationSteps(cfg, newPool, newSyncTrigger);
    }

    /// @dev Reads back on-chain state after `executeMigrationSteps` to ensure every write landed
    ///      and every revoke took effect. A partial success from a prior step will cause the
    ///      broadcast itself to revert rather than silently leaving the system half-migrated.
    function _assertMigrationSteps(
        L2UpgradeConfig memory cfg,
        address newPool,
        address newSyncTrigger
    ) private view {
        IAccessControl sender = IAccessControl(cfg.customSender);
        _requireL2PostCondition(ICustomSender(cfg.customSender).getOraclePool() == newPool, "oraclePool");
        _requireL2PostCondition(sender.hasRole(SYNC_ROLE, newSyncTrigger), "sync role grant");
        _requireL2PostCondition(
            cfg.oldChainlinkAutomation == address(0) || !sender.hasRole(SYNC_ROLE, cfg.oldChainlinkAutomation),
            "old chainlink sync revoke"
        );
        _requireL2PostCondition(
            cfg.oldGelatoAutomation == address(0) || !sender.hasRole(SYNC_ROLE, cfg.oldGelatoAutomation),
            "old gelato sync revoke"
        );
        _requireL2PostCondition(sender.hasRole(DEFAULT_ADMIN_ROLE, cfg.governanceExecutor), "governance admin grant");
        // NOTE: AccessControlUpgradeable permits unlimited simultaneous DEFAULT_ADMIN_ROLE holders and
        // CustomSender is NOT AccessControlEnumerable, so there is no on-chain way to prove the executor
        // is the SOLE admin. We assert only the two addresses this migration touches (executor gained it,
        // initialOwner — verified to have held it, see migrateSenderAdmin — lost it). A pre-existing or
        // emergency-granted third admin would survive undetected; out-of-band grants must be audited
        // off-chain before migration. The migrateSenderAdmin precondition guarantees this revoke was real.
        _requireL2PostCondition(!sender.hasRole(DEFAULT_ADMIN_ROLE, cfg.initialOwner), "initial owner admin revoke");
        _requireL2PostCondition(Ownable(cfg.proxyAdmin).owner() == cfg.governanceExecutor, "proxyAdmin owner");
    }

    function setSyncTriggerForwarder(address syncTrigger, address forwarder) public {
        _requireNonZeroL2(syncTrigger);
        _requireNonZeroL2(forwarder);

        ISyncTrigger(syncTrigger).setForwarder(forwarder);
        emit L2SyncTriggerForwarderSet(syncTrigger, forwarder);
    }

}
