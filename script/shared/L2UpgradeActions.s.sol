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
        transferSyncTriggerOwnership(address(st), cfg.governanceExecutor);
        transferCREReceiverOwnership(address(cr), cfg.liquidityOwner);

        syncTrigger = address(st);
        creReceiverAddr = address(cr);

        _assertSyncInfrastructure(cfg, syncTrigger, creReceiverAddr, creForwarder, expectedAuthor);
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
        _requireL2PostCondition(ISyncTrigger(syncTrigger).getForwarder() == creReceiverAddr, "syncTrigger forwarder");
        _requireL2PostCondition(Ownable(syncTrigger).owner() == cfg.governanceExecutor, "syncTrigger owner");
        _requireL2PostCondition(cr.getForwarder() == creForwarder, "creReceiver forwarder");
        _requireL2PostCondition(cr.getExpectedAuthor() == expectedAuthor, "creReceiver expectedAuthor");
        _requireL2PostCondition(
            cr.isCallAllowed(syncTrigger, ISyncTrigger.triggerSync.selector),
            "creReceiver allow-list seed"
        );
        _requireL2PostCondition(Ownable(creReceiverAddr).owner() == cfg.liquidityOwner, "creReceiver owner");
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

        // Fail-fast guardrails: surface "Stage 2 already ran" before the 16 deploy-correctness reads below,
        // since verifying a post-Stage-2 state against a pre-Stage-2 expectation is meaningless.
        _requireL2PostCondition(
            ICustomSender(cfg.customSender).getOraclePool() != oraclePool,
            "stage 2 already ran: CustomSender.getOraclePool() already points at the new pool"
        );
        _requireL2PostCondition(
            !IAccessControl(cfg.customSender).hasRole(SYNC_ROLE, syncTrigger),
            "stage 2 already ran: SYNC_ROLE already granted to the new SyncTrigger"
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

        ISyncTrigger st = ISyncTrigger(syncTrigger);
        _requireL2PostCondition(st.SENDER() == cfg.customSender, "syncTrigger SENDER");
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
    }

    function migrateSenderAdmin(L2UpgradeConfig memory cfg) public {
        _requireNonZeroL2(cfg.initialOwner);
        _requireNonZeroL2(cfg.governanceExecutor);
        _requireNonZeroL2(cfg.customSender);

        IAccessControl(cfg.customSender).grantRole(DEFAULT_ADMIN_ROLE, cfg.governanceExecutor);
        IAccessControl(cfg.customSender).revokeRole(DEFAULT_ADMIN_ROLE, cfg.initialOwner);
        emit L2SenderAdminMigrated(cfg.customSender, cfg.initialOwner, cfg.governanceExecutor);
    }

    function transferProxyAdminOwnership(L2UpgradeConfig memory cfg) public {
        _requireNonZeroL2(cfg.initialOwner);
        _requireNonZeroL2(cfg.governanceExecutor);
        _requireNonZeroL2(cfg.proxyAdmin);

        Ownable(cfg.proxyAdmin).transferOwnership(cfg.governanceExecutor);
        emit L2ProxyAdminOwnershipTransferred(cfg.proxyAdmin, cfg.initialOwner, cfg.governanceExecutor);
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
        address newSyncTrigger
    ) public {
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
