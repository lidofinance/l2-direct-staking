// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";
import {ICustomSender} from "@csr/interfaces/ICustomSender.sol";
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

    function deploySyncTrigger(L2UpgradeConfig memory cfg) public returns (SyncTrigger syncTrigger) {
        _requireNonZeroL2(cfg.initialOwner);
        _requireNonZeroL2(cfg.customSender);
        if (cfg.destChainSelector == 0) revert L2UpgradeInvalidChainSelector();

        syncTrigger = new SyncTrigger(cfg.customSender, cfg.destChainSelector, cfg.initialOwner);
        emit L2SyncTriggerDeployed(address(syncTrigger), cfg.customSender, cfg.initialOwner);
    }

    function deployCREReceiver(address creForwarder) public returns (CREReceiver receiver) {
        _requireNonZeroL2(creForwarder);
        receiver = new CREReceiver(creForwarder);
        emit L2CREReceiverDeployed(address(receiver), creForwarder);
    }

    function transferCREReceiverOwnership(address creReceiver, address newOwner) public {
        _requireNonZeroL2(creReceiver);
        _requireNonZeroL2(newOwner);

        address previousOwner = Ownable(creReceiver).owner();
        Ownable(creReceiver).transferOwnership(newOwner);
        emit L2CREReceiverOwnershipTransferred(creReceiver, previousOwner, newOwner);
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
        address newSyncTrigger,
        address creReceiver
    ) public {
        setOraclePool(cfg.customSender, newPool);
        grantSyncRole(cfg.customSender, newSyncTrigger);
        if (cfg.oldChainlinkAutomation != address(0)) {
            revokeSyncRole(cfg.customSender, cfg.oldChainlinkAutomation);
        }
        if (cfg.oldGelatoAutomation != address(0)) {
            revokeSyncRole(cfg.customSender, cfg.oldGelatoAutomation);
        }
        configureSyncTrigger(newSyncTrigger, cfg);
        if (creReceiver != address(0)) {
            setSyncTriggerForwarder(newSyncTrigger, creReceiver);
        }
        migrateSenderAdmin(cfg);
        transferProxyAdminOwnership(cfg);
        transferSyncTriggerOwnership(newSyncTrigger, cfg.governanceExecutor);
    }

    function setSyncTriggerForwarder(address syncTrigger, address forwarder) public {
        _requireNonZeroL2(syncTrigger);
        _requireNonZeroL2(forwarder);

        ISyncTrigger(syncTrigger).setForwarder(forwarder);
        emit L2SyncTriggerForwarderSet(syncTrigger, forwarder);
    }

}
