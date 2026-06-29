// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";
import {ICustomSender} from "@csr/interfaces/ICustomSender.sol";
import {IOraclePool} from "@csr/interfaces/IOraclePool.sol";
import {SyncTrigger} from "src/SyncTrigger.sol";
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
        uint32 destinationGasLimit;
        uint32 maxGasLimit; // Per-lane FeeOtoD gasLimit ceiling = the lane's CCIP maxPerMsgGasLimit (EVM2EVMOnRamp v1.5 on OP/Linea, FeeQuoter v1.6 on Base/Arb; 7M OP/Arb/Base, 3M Linea); rejects an over-cap bump at set-time (docs/audit-scope C-1)
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
    event L2SyncTriggerFunded(address indexed syncTrigger, uint256 amount);
    event L2CREReceiverOwnershipTransferred(
        address indexed creReceiver, address indexed previousOwner, address indexed newOwner
    );
    event L2OraclePoolOwnershipTransferred(
        address indexed oraclePool, address indexed previousOwner, address indexed newOwner
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
        return deployPool(cfg, cfg.liquidityOwner);
    }

    /// @dev Owner-parametrized variant. Production deploys with `cfg.liquidityOwner` (LOL multisig). The
    ///      canary test flow deploys with the Lido Deployer so it can drive the simulated CRE sync, then
    ///      transfers ownership to the LOL multisig at handoff ({handoffToLiquidityOwner}).
    function deployPool(L2UpgradeConfig memory cfg, address owner)
        public
        returns (PausableImmutableOraclePool newPool)
    {
        _requireNonZeroL2(owner);
        _requireNonZeroL2(cfg.customSender);
        _requireNonZeroL2(cfg.tokenIn);
        _requireNonZeroL2(cfg.tokenOut);
        _requireNonZeroL2(cfg.priceOracle);

        newPool = new PausableImmutableOraclePool(
            cfg.customSender, cfg.tokenIn, cfg.tokenOut, cfg.priceOracle, cfg.fee, owner
        );

        emit L2OraclePoolDeployed(address(newPool), owner);
    }

    function deploySyncTrigger(L2UpgradeConfig memory cfg, address forwarder, address initialOwner)
        public
        returns (SyncTrigger syncTrigger)
    {
        _requireNonZeroL2(initialOwner);
        _requireNonZeroL2(forwarder);
        _requireNonZeroL2(cfg.customSender);
        if (cfg.destChainSelector == 0) revert L2UpgradeInvalidChainSelector();

        // Born fully configured: the constructor validates and stores every operational parameter and
        // sets the owner, so there is no post-deploy configure/transfer step. feeOtoD is built from the
        // single-source encoder so it cannot drift from the verify-constants-sync oracle.
        syncTrigger = new SyncTrigger(
            cfg.customSender,
            cfg.destChainSelector,
            initialOwner,
            SyncTrigger.InitParams({
                forwarder: forwarder,
                delay: cfg.minSyncDelay,
                minAmount: cfg.minSyncAmount,
                maxAmount: cfg.maxSyncAmount,
                feeOtoD: _encodeFeeOtoD(cfg),
                feeDtoO: cfg.feeDtoO,
                maxGasLimit: cfg.maxGasLimit
            })
        );
        emit L2SyncTriggerDeployed(address(syncTrigger), cfg.customSender, initialOwner);
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
     * @notice Deploy CREReceiver + a fully-configured SyncTrigger, wire them together, and fund the float.
     * @dev Shared by production scripts and fork tests. Pool must be deployed separately.
     *
     *      The receiver is deployed FIRST (with an empty allow-list seed) so the SyncTrigger can be
     *      constructed with the real forwarder == receiver address; the receiver's allow-list is then
     *      seeded with the now-deployed trigger (`setAllowedCall` requires the target to have code).
     *      Because the constructor sets every parameter AND the owner, the SyncTrigger needs no
     *      post-deploy owner action — it is owned by `cfg.liquidityOwner` (the LOL multisig) from birth.
     */
    function deploySyncInfrastructure(
        L2UpgradeConfig memory cfg,
        address creForwarder,
        address expectedAuthor
    ) public returns (address syncTrigger, address creReceiverAddr) {
        return deploySyncInfrastructure(cfg, creForwarder, expectedAuthor, cfg.liquidityOwner);
    }

    /// @dev Owner-parametrized variant. `deployOwner` owns the SyncTrigger and CREReceiver on deploy.
    ///      Production passes `cfg.liquidityOwner` (LOL multisig, owned from birth). The canary test flow
    ///      passes the Lido Deployer — with `creForwarder` and `expectedAuthor` also = the deployer — so it
    ///      can stand in for the CRE forwarder + workflow author and drive `CREReceiver.onReport` directly;
    ///      the real forwarder/author and LOL ownership are restored at {handoffToLiquidityOwner}.
    function deploySyncInfrastructure(
        L2UpgradeConfig memory cfg,
        address creForwarder,
        address expectedAuthor,
        address deployOwner
    ) public returns (address syncTrigger, address creReceiverAddr) {
        _requireNonZeroL2(deployOwner);
        CREReceiver cr = deployCREReceiver(creForwarder, expectedAuthor, address(0), bytes4(0));
        SyncTrigger st = deploySyncTrigger(cfg, address(cr), deployOwner);
        // Seed the receiver's allow-list now that the trigger has code (CREReceiver's TargetHasNoCode
        // guard). Same execution frame that deployed the receiver, so msg.sender == its owner.
        cr.setAllowedCall(address(st), SyncTrigger.triggerSync.selector, true);
        // CREReceiver is constructed owned by the broadcaster; transfer only if the target differs (in the
        // canary flow the deployer keeps it, so no self-transfer).
        if (Ownable(address(cr)).owner() != deployOwner) {
            transferCREReceiverOwnership(address(cr), deployOwner);
        }
        fundSyncTrigger(address(st), cfg);

        syncTrigger = address(st);
        creReceiverAddr = address(cr);

        _assertSyncInfrastructure(cfg, syncTrigger, creReceiverAddr, creForwarder, expectedAuthor, deployOwner);
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

        (uint256 feeAmountDtoO,) = FeeCodec.decodeFeeMemory(cfg.feeDtoO);
        // floor mirrors the worst-case native value SyncTrigger.triggerSync fronts: the OtoD cap plus the
        // DtoO bridge fee (both native — LINK fee payment is not supported). NOTE: this validates
        // float >= the CONFIGURED cap, NOT float >= the LIVE CCIP router fee. Whether destinationMaxFee
        // itself sits above the live ccipReceive fee is a separate config-adequacy question, validated
        // off-chain via the fee-measurement recipe (README §Fee-denomination); a cap set below the live
        // fee would pass this floor yet revert inside CCIPSenderUpgradeable at sync time.
        uint256 floor = cfg.destinationMaxFee + feeAmountDtoO;
        if (cfg.syncTriggerInitialFloat < floor) {
            revert L2UpgradeFloatBelowFloor(cfg.syncTriggerInitialFloat, floor);
        }

        (bool ok,) = payable(syncTrigger).call{value: cfg.syncTriggerInitialFloat}("");
        _requireL2PostCondition(ok, "syncTrigger funding transfer");
        emit L2SyncTriggerFunded(syncTrigger, cfg.syncTriggerInitialFloat);
    }

    /// @dev Top the SyncTrigger's native float back up to `targetFloat` (the configured initial float) if a
    ///      test or live sync drew it down. Funded from the calling broadcaster; emits L2SyncTriggerFunded
    ///      with the delta so off-chain provenance sees the top-up the same way it sees the initial
    ///      fundSyncTrigger. No-op when the balance already meets the target.
    function _topUpFloat(address syncTrigger, uint256 targetFloat) internal {
        uint256 balance = syncTrigger.balance;
        if (balance >= targetFloat) return;
        uint256 amount = targetFloat - balance;
        (bool ok,) = payable(syncTrigger).call{value: amount}("");
        _requireL2PostCondition(ok, "float top-up");
        emit L2SyncTriggerFunded(syncTrigger, amount);
    }

    /// @dev Sanity checks the Stage 1 deploy; fails the broadcast if anything is off. The 5-arg form
    ///      asserts the SyncTrigger/CREReceiver are owned by `cfg.liquidityOwner` (production / post-handoff).
    function _assertSyncInfrastructure(
        L2UpgradeConfig memory cfg,
        address syncTrigger,
        address creReceiverAddr,
        address creForwarder,
        address expectedAuthor
    ) private view {
        _assertSyncInfrastructure(cfg, syncTrigger, creReceiverAddr, creForwarder, expectedAuthor, cfg.liquidityOwner);
    }

    /// @dev `expectedOwner` is the owner the SyncTrigger/CREReceiver must currently hold — `cfg.liquidityOwner`
    ///      in production / post-handoff, or the Lido Deployer during the canary test window.
    function _assertSyncInfrastructure(
        L2UpgradeConfig memory cfg,
        address syncTrigger,
        address creReceiverAddr,
        address creForwarder,
        address expectedAuthor,
        address expectedOwner
    ) private view {
        CREReceiver cr = CREReceiver(payable(creReceiverAddr));
        SyncTrigger st = SyncTrigger(payable(syncTrigger));
        // pin the trigger to the real CustomSender. A typo'd/wrong syncTrigger address would
        // not have SENDER pointing at this CustomSender, so this catches a mis-wired trigger before
        // it is granted SYNC_ROLE (and, via the Stage-2 precondition, before any irreversible handover).
        _requireL2PostCondition(st.SENDER() == cfg.customSender, "syncTrigger SENDER");
        _requireL2PostCondition(st.getForwarder() == creReceiverAddr, "syncTrigger forwarder");
        _requireL2PostCondition(Ownable(syncTrigger).owner() == expectedOwner, "syncTrigger owner");
        // operational parameters — verified IN-broadcast (Stage 1) and re-checked as a Stage-2
        // precondition. The constructor rejects INVALID values (out-of-range gasLimit, zero delay, wrong
        // fee length), but a wrong-but-VALID MigrationConstants typo (e.g. a gasLimit of 200_000 instead
        // of 1_000_000) is stored without reverting, so without these reads the deploy looks green and the
        // defect only surfaces if the operator separately runs verifyCanaryStage1 — or, worse, after go-live.
        _requireL2PostCondition(st.DEST_CHAIN_SELECTOR() == cfg.destChainSelector, "syncTrigger DEST_CHAIN_SELECTOR");
        _requireL2PostCondition(st.WNATIVE() == cfg.tokenIn, "syncTrigger WNATIVE");
        _requireL2PostCondition(st.getDelay() == cfg.minSyncDelay, "syncTrigger delay");
        (uint128 minAmount, uint128 maxAmount) = st.getAmounts();
        _requireL2PostCondition(minAmount == cfg.minSyncAmount, "syncTrigger minAmount");
        _requireL2PostCondition(maxAmount == cfg.maxSyncAmount, "syncTrigger maxAmount");
        _requireL2PostCondition(keccak256(st.getFeeDtoO()) == keccak256(cfg.feeDtoO), "syncTrigger feeDtoO");
        _requireL2PostCondition(
            keccak256(st.getFeeOtoD()) == keccak256(_encodeFeeOtoD(cfg)),
            "syncTrigger feeOtoD"
        );
        // the per-lane gasLimit ceiling: the SyncTrigger constructor seeds it and _setFeeOtoD enforces
        // gasLimit <= it, so a mistyped L2_SYNC_MAX_GAS_LIMIT (e.g. OP's 7M copy-pasted onto Linea's 3M
        // lane) would otherwise pass the deploy green yet silently loosen the C-1 over-cap guard — the
        // exact MigrationConstants-typo class this assertion block (see comment above) exists to catch.
        _requireL2PostCondition(st.getMaxGasLimit() == cfg.maxGasLimit, "syncTrigger maxGasLimit");
        _requireL2PostCondition(cr.getForwarder() == creForwarder, "creReceiver forwarder");
        _requireL2PostCondition(cr.getExpectedAuthor() == expectedAuthor, "creReceiver expectedAuthor");
        _requireL2PostCondition(
            cr.isCallAllowed(syncTrigger, SyncTrigger.triggerSync.selector),
            "creReceiver allow-list seed"
        );
        _requireL2PostCondition(Ownable(creReceiverAddr).owner() == expectedOwner, "creReceiver owner");
        // The float must hold at least the configured initial float. fundSyncTrigger seeds it at deploy;
        // handoffToLiquidityOwner and finalizeGovernanceSeal replenish it via _topUpFloat after any test or
        // live sync draws it down (in the canary flow SYNC_ROLE is granted early, at activateForTesting, so
        // a sync CAN run before the seal), keeping this bound true at every site that runs this assert.
        _requireL2PostCondition(syncTrigger.balance >= cfg.syncTriggerInitialFloat, "syncTrigger fee float");
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
        // transferCREReceiverOwnership — so the emitted previousOwner is
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

    /// @dev The CCIP-encoded OtoD fee blob for a config — the single source for the sites that need it
    ///      (the SyncTrigger constructor's feeOtoD arg, the _assertSyncInfrastructure post-condition, and
    ///      the runPrintFeeParams verify-constants-sync oracle), so they cannot drift on the encoding.
    function _encodeFeeOtoD(L2UpgradeConfig memory cfg) internal pure returns (bytes memory) {
        // payInLink hardcoded false — LINK fee payment is not supported (SyncTrigger rejects payInLink).
        return FeeCodec.encodeCCIP(cfg.destinationMaxFee, false, cfg.destinationGasLimit);
    }

    /// @dev Deploy-script mirror of `SyncTrigger._maxFees` — the total NATIVE fee over the OtoD/DtoO fee
    ///      blobs (every leg is native; LINK fee payment is not supported). Duplicated here (rather than
    ///      importing a shared src/ library) so the audit scope carries no standalone split file; the two
    ///      copies are pinned together by `verify-constants-sync` (this path, pre-deploy) and state-mate
    ///      (the live `SyncTrigger.getMaxFees`, post-deploy) against the same `<net>.inputs.yaml` anchors,
    ///      and by the fee-split equivalence test.
    function _maxFees(bytes memory feeOtoD, bytes memory feeDtoO)
        internal
        pure
        returns (uint256 maxNativeFee)
    {
        (uint256 maxFeeOtoD,) = FeeCodec.decodeFeeMemory(feeOtoD);
        (uint256 maxFeeDtoO,) = FeeCodec.decodeFeeMemory(feeDtoO);
        maxNativeFee = maxFeeOtoD + maxFeeDtoO;
    }

    /// @dev Reads back on-chain state after the governance seal to ensure every write landed
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

    /// @dev The irreversible governance-seal tail invoked by the canary seal (finalizeGovernanceSeal):
    ///      revoke the old automation(s) SYNC_ROLE, migrate CustomSender admin to the governance executor,
    ///      hand the L2 ProxyAdmin over, then assert the end state.
    function _sealAdminAndProxy(L2UpgradeConfig memory cfg, address newPool, address newSyncTrigger) private {
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

    // ──────────────── Canary test flow (deployer-simulated CRE) ───────────

    /// @notice Transfer OraclePool ownership (mirrors {transferCREReceiverOwnership}); reads the live owner
    ///         so the emitted previousOwner is truthful even if the pool was transferred out-of-band.
    function transferPoolOwnership(address oraclePool, address newOwner) public {
        _requireNonZeroL2(oraclePool);
        _requireNonZeroL2(newOwner);
        address previousOwner = Ownable(oraclePool).owner();
        Ownable(oraclePool).transferOwnership(newOwner);
        emit L2OraclePoolOwnershipTransferred(oraclePool, previousOwner, newOwner);
    }

    /// @notice Reversible activation for the canary test: point CustomSender at the new pool and grant the
    ///         new SyncTrigger SYNC_ROLE. Deliberately does NOT revoke the old automation and does NOT
    ///         migrate admin — the Initial Owner keeps DEFAULT_ADMIN_ROLE so {rollbackActivation} can undo
    ///         this without governance. Actor: Initial Owner.
    function activateForTesting(L2UpgradeConfig memory cfg, address newPool, address newSyncTrigger) public {
        _requireNonZeroL2(newPool);
        _requireNonZeroL2(newSyncTrigger);
        setOraclePool(cfg.customSender, newPool);
        grantSyncRole(cfg.customSender, newSyncTrigger);
        _requireL2PostCondition(ICustomSender(cfg.customSender).getOraclePool() == newPool, "activate oraclePool");
        _requireL2PostCondition(
            IAccessControl(cfg.customSender).hasRole(SYNC_ROLE, newSyncTrigger), "activate sync role"
        );
    }

    /// @notice Undo {activateForTesting}: repoint CustomSender at the old pool and revoke the new
    ///         SyncTrigger's SYNC_ROLE. The old automation was never revoked, so the predecessor system is
    ///         fully restored. Actor: Initial Owner.
    function rollbackActivation(L2UpgradeConfig memory cfg, address oldPool, address newSyncTrigger) public {
        _requireNonZeroL2(oldPool);
        _requireNonZeroL2(newSyncTrigger);
        setOraclePool(cfg.customSender, oldPool);
        revokeSyncRole(cfg.customSender, newSyncTrigger);
        _requireL2PostCondition(ICustomSender(cfg.customSender).getOraclePool() == oldPool, "rollback oraclePool");
        _requireL2PostCondition(
            !IAccessControl(cfg.customSender).hasRole(SYNC_ROLE, newSyncTrigger), "rollback sync role"
        );
    }

    /// @notice Sweep leftover test TOKEN_IN/TOKEN_OUT out of the pool before the LOL handoff, so production
    ///         starts from a clean pool and no premature real sync fires once the CRE workflow goes live.
    ///         Owner-only on the pool. Actor: Deployer (current pool owner).
    function sweepTestResidue(L2UpgradeConfig memory cfg, address newPool, address recipient) public {
        _requireNonZeroL2(newPool);
        _requireNonZeroL2(recipient);
        uint256 tokenInBal = IERC20(cfg.tokenIn).balanceOf(newPool);
        if (tokenInBal > 0) IOraclePool(newPool).sweep(cfg.tokenIn, recipient, tokenInBal);
        uint256 tokenOutBal = IERC20(cfg.tokenOut).balanceOf(newPool);
        if (tokenOutBal > 0) IOraclePool(newPool).sweep(cfg.tokenOut, recipient, tokenOutBal);
    }

    /// @notice Restore production config on the deployer-owned infra and transfer all three contracts to the
    ///         LOL multisig. Undoes the deployer-as-forwarder test wiring (restores the real CRE forwarder +
    ///         LOL author) and the production delay/min-amount, tops the float back to the configured
    ///         initial float (test syncs spend a little — the OtoD overage refunds, so it is small), then
    ///         transfers ownership. The closing {_assertSyncInfrastructure} against production values is the
    ///         guardrail: it reverts the whole handoff if ANY restore was missed. Actor: Deployer (current
    ///         owner of all three).
    function handoffToLiquidityOwner(
        L2UpgradeConfig memory cfg,
        address newPool,
        address newSyncTrigger,
        address creReceiver,
        address realForwarder
    ) public {
        _requireNonZeroL2(newPool);
        _requireNonZeroL2(newSyncTrigger);
        _requireNonZeroL2(creReceiver);
        _requireNonZeroL2(realForwarder);

        SyncTrigger st = SyncTrigger(payable(newSyncTrigger));
        st.setDelay(cfg.minSyncDelay);
        st.setAmounts(cfg.minSyncAmount, cfg.maxSyncAmount);

        CREReceiver cr = CREReceiver(payable(creReceiver));
        cr.setForwarder(realForwarder);
        cr.setExpectedAuthor(cfg.liquidityOwner);

        // Top the float back up to the configured initial float if test syncs drew it down (emits
        // L2SyncTriggerFunded for the same indexed provenance as the initial fundSyncTrigger).
        _topUpFloat(newSyncTrigger, cfg.syncTriggerInitialFloat);

        transferPoolOwnership(newPool, cfg.liquidityOwner);
        Ownable(newSyncTrigger).transferOwnership(cfg.liquidityOwner);
        transferCREReceiverOwnership(creReceiver, cfg.liquidityOwner);

        // Guardrail: production forwarder + LOL author + production delay/amounts + LOL ownership + float.
        _assertSyncInfrastructure(
            cfg, newSyncTrigger, creReceiver, realForwarder, cfg.liquidityOwner, cfg.liquidityOwner
        );
    }

    /// @notice Irreversible governance seal, run after the LOL handoff: revoke the old automation(s),
    ///         migrate CustomSender admin to the governance executor, and transfer the L2 ProxyAdmin. The
    ///         opening {_assertSyncInfrastructure} interlock refuses to seal unless the infra is already
    ///         LOL-owned and production-configured. The oracle-pool repoint + SYNC_ROLE grant happened in
    ///         {activateForTesting} and are asserted here, not re-done. Actor: Initial Owner.
    function finalizeGovernanceSeal(
        L2UpgradeConfig memory cfg,
        address newPool,
        address newSyncTrigger,
        address creReceiver,
        address realForwarder
    ) public {
        // A live production sync between handoff and finalize draws the float below the configured initial
        // float; top it back up FIRST so the float invariant inside the interlock below cannot block this
        // IRREVERSIBLE seal. No-op on the documented path (pool unfunded until after the seal); funding is
        // permissionless, so the broadcaster (Initial Owner) can replenish the now-LOL-owned trigger.
        _topUpFloat(newSyncTrigger, cfg.syncTriggerInitialFloat);
        _assertSyncInfrastructure(
            cfg, newSyncTrigger, creReceiver, realForwarder, cfg.liquidityOwner, cfg.liquidityOwner
        );
        _requireL2PostCondition(ICustomSender(cfg.customSender).getOraclePool() == newPool, "finalize oraclePool");
        _requireL2PostCondition(
            IAccessControl(cfg.customSender).hasRole(SYNC_ROLE, newSyncTrigger), "finalize sync role"
        );

        _sealAdminAndProxy(cfg, newPool, newSyncTrigger);
    }

    /// @notice Read-only verification of the canary Stage-1 state: the three contracts are deployed and
    ///         owned by `testOwner` (the Lido Deployer), the CREReceiver is wired with `testOwner` as both
    ///         forwarder and author (deployer-as-CRE), the pool is repointed and the SyncTrigger holds
    ///         SYNC_ROLE, and the governance seal has NOT run. `cfg` must carry the TEST delay/min-amount.
    ///         Intended to run right after deploy+activate, before the simulated sync draws down the float.
    function verifyCanaryStage1(
        L2UpgradeConfig memory cfg,
        address oraclePool,
        address syncTrigger,
        address creReceiverAddr,
        address testOwner
    ) public view {
        _requireNonZeroL2(oraclePool);
        _requireNonZeroL2(testOwner);
        _assertSyncInfrastructure(cfg, syncTrigger, creReceiverAddr, testOwner, testOwner, testOwner);

        IOraclePool pool = IOraclePool(oraclePool);
        _requireL2PostCondition(pool.SENDER() == cfg.customSender, "oraclePool SENDER");
        _requireL2PostCondition(pool.TOKEN_IN() == cfg.tokenIn, "oraclePool TOKEN_IN");
        _requireL2PostCondition(pool.TOKEN_OUT() == cfg.tokenOut, "oraclePool TOKEN_OUT");
        _requireL2PostCondition(Ownable(oraclePool).owner() == testOwner, "oraclePool owner");

        _requireL2PostCondition(
            ICustomSender(cfg.customSender).getOraclePool() == oraclePool, "canary pool not active"
        );
        _requireL2PostCondition(
            IAccessControl(cfg.customSender).hasRole(SYNC_ROLE, syncTrigger), "canary SYNC_ROLE not granted"
        );
        _requireL2PostCondition(
            !IAccessControl(cfg.customSender).hasRole(DEFAULT_ADMIN_ROLE, cfg.governanceExecutor),
            "seal already ran: governanceExecutor holds DEFAULT_ADMIN_ROLE"
        );
    }

    /// @notice Read-only verification of the post-handoff, pre-seal state (Stage 2): the three contracts are
    ///         LOL-owned and production-configured (real forwarder + LOL author + production delay/amounts +
    ///         float), the pool is active and the SyncTrigger holds SYNC_ROLE, and the Initial Owner still
    ///         holds CustomSender admin (the irreversible seal has NOT run).
    function verifyCanaryStage2(
        L2UpgradeConfig memory cfg,
        address oraclePool,
        address syncTrigger,
        address creReceiverAddr,
        address realForwarder
    ) public view {
        _requireNonZeroL2(oraclePool);
        _requireNonZeroL2(realForwarder);
        _assertSyncInfrastructure(
            cfg, syncTrigger, creReceiverAddr, realForwarder, cfg.liquidityOwner, cfg.liquidityOwner
        );
        _requireL2PostCondition(Ownable(oraclePool).owner() == cfg.liquidityOwner, "oraclePool owner not LOL");
        _requireL2PostCondition(
            ICustomSender(cfg.customSender).getOraclePool() == oraclePool, "oraclePool not active"
        );
        _requireL2PostCondition(
            IAccessControl(cfg.customSender).hasRole(SYNC_ROLE, syncTrigger), "SYNC_ROLE missing"
        );
        _requireL2PostCondition(
            IAccessControl(cfg.customSender).hasRole(DEFAULT_ADMIN_ROLE, cfg.initialOwner),
            "initial owner already lost admin"
        );
        _requireL2PostCondition(
            !IAccessControl(cfg.customSender).hasRole(DEFAULT_ADMIN_ROLE, cfg.governanceExecutor),
            "seal already ran: governanceExecutor holds DEFAULT_ADMIN_ROLE"
        );
    }
}
