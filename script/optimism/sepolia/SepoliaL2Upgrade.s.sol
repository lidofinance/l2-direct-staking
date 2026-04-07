// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {ISyncAutomation} from "@csr/interfaces/ISyncAutomation.sol";
import {ICustomSender} from "@csr/interfaces/ICustomSender.sol";
import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";
import {SyncTrigger} from "src/SyncTrigger.sol";
import {CREReceiver} from "src/cre/CREReceiver.sol";
import {L2UpgradeActions} from "script/shared/L2UpgradeActions.s.sol";
import {SepoliaMigrationConstants as C} from "script/optimism/sepolia/SepoliaMigrationConstants.sol";

/**
 * @notice Sepolia testnet L2 upgrade script.
 * @dev Reuses L2UpgradeActions (the actual deployment logic) but builds config
 *      from SepoliaMigrationConstants + env vars for deployed infrastructure.
 *
 * Required env:
 * - L2_CUSTOM_SENDER         (deployed CustomSender proxy on OP Sepolia)
 * - L2_PROXY_ADMIN           (deployed ProxyAdmin on OP Sepolia)
 * - L2_PRICE_ORACLE          (deployed PriceOracle on OP Sepolia)
 * - L2_BOOTSTRAP_SYNC_AUTOMATION
 * - INITIAL_OWNER_PRIVATE_KEY
 * - L2_LIDO_DEPLOYER_PRIVATE_KEY
 * - L2_GOVERNANCE_EXECUTOR
 *
 * Optional env:
 * - L2_LIQUIDITY_OWNER       (defaults to L2_GOVERNANCE_EXECUTOR)
 */
contract SepoliaL2UpgradeScript is Script, L2UpgradeActions {
    error SepoliaBootstrapSyncAutomationRequired();
    error SepoliaBootstrapSyncTriggerCollision();
    error SepoliaBootstrapOraclePoolMissing();

    function sepoliaL2Config(address initialOwner, address governanceExecutor, address liquidityOwner)
        public
        view
        returns (L2UpgradeConfig memory cfg)
    {
        cfg = L2UpgradeConfig({
            initialOwner: initialOwner,
            governanceExecutor: governanceExecutor,
            liquidityOwner: liquidityOwner,
            customSender: vm.envAddress("L2_CUSTOM_SENDER"),
            proxyAdmin: vm.envAddress("L2_PROXY_ADMIN"),
            tokenIn: C.L2_WETH,
            tokenOut: C.L2_WSTETH,
            priceOracle: vm.envAddress("L2_PRICE_ORACLE"),
            fee: 0,
            destChainSelector: C.ETH_CCIP_CHAIN_SELECTOR,
            destinationMaxFee: C.L2_SYNC_DESTINATION_MAX_FEE,
            destinationPayInLink: C.L2_SYNC_DESTINATION_PAY_IN_LINK,
            destinationGasLimit: C.L2_SYNC_DESTINATION_GAS_LIMIT,
            feeDtoO: FeeCodec.encodeOptimismL1toL2(C.L2_SYNC_ORIGIN_L2_GAS),
            minSyncAmount: C.L2_SYNC_MIN_AMOUNT,
            maxSyncAmount: C.L2_SYNC_MAX_AMOUNT,
            minSyncDelay: C.L2_SYNC_DELAY,
            oldChainlinkAutomation: address(0), // Sepolia handles retirement separately via _retireBootstrapSyncAutomation
            oldGelatoAutomation: address(0)
        });
    }

    function _sweepPoolTokenIfAny(address pool, address recipient, address token) internal {
        uint256 balance = IERC20(token).balanceOf(pool);
        if (balance != 0) {
            PausableImmutableOraclePool(pool).sweep(token, recipient, balance);
        }
    }

    function _retireBootstrapPool(address bootstrapPool, address replacementPool, L2UpgradeConfig memory cfg, address governanceExecutor)
        internal
    {
        _sweepPoolTokenIfAny(bootstrapPool, replacementPool, cfg.tokenIn);
        _sweepPoolTokenIfAny(bootstrapPool, replacementPool, cfg.tokenOut);
        PausableImmutableOraclePool(bootstrapPool).pause();
        Ownable(bootstrapPool).transferOwnership(governanceExecutor);
    }

    /// @dev Retires the old bootstrap SyncAutomation (from chainlink-csr lib).
    function _retireBootstrapSyncAutomation(address customSender, address bootstrapSyncAutomation, address governanceExecutor)
        internal
    {
        IAccessControl(customSender).revokeRole(ICustomSender(customSender).SYNC_ROLE(), bootstrapSyncAutomation);
        ISyncAutomation(bootstrapSyncAutomation).setForwarder(address(0));
        ISyncAutomation(bootstrapSyncAutomation).setDelay(type(uint48).max);
        Ownable(bootstrapSyncAutomation).transferOwnership(governanceExecutor);
    }

    function run() external returns (address oraclePool, address syncTrigger, address creReceiverAddr) {
        uint256 initialOwnerPrivateKey = vm.envUint("INITIAL_OWNER_PRIVATE_KEY");
        uint256 lidoDeployerPrivateKey = vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY");
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = vm.envOr("L2_LIQUIDITY_OWNER", governanceExecutor);
        address bootstrapSyncAutomation = vm.envOr("L2_BOOTSTRAP_SYNC_AUTOMATION", address(0));
        address creForwarder = vm.envAddress("L2_CRE_FORWARDER");

        L2UpgradeConfig memory cfg = sepoliaL2Config(initialOwner, governanceExecutor, liquidityOwner);

        if (bootstrapSyncAutomation == address(0)) revert SepoliaBootstrapSyncAutomationRequired();

        vm.startBroadcast(lidoDeployerPrivateKey);
        PausableImmutableOraclePool pool = deployPool(cfg);
        SyncTrigger deployedSyncTrigger = deploySyncTrigger(cfg);
        CREReceiver deployedCREReceiver = deployCREReceiver(creForwarder);
        transferCREReceiverOwnership(address(deployedCREReceiver), liquidityOwner);
        vm.stopBroadcast();

        vm.startBroadcast(initialOwnerPrivateKey);
        {
            address bootstrapPool = ICustomSender(cfg.customSender).getOraclePool();
            if (bootstrapPool == address(0)) revert SepoliaBootstrapOraclePoolMissing();
            if (bootstrapSyncAutomation == address(deployedSyncTrigger)) {
                revert SepoliaBootstrapSyncTriggerCollision();
            }

            _retireBootstrapSyncAutomation(cfg.customSender, bootstrapSyncAutomation, governanceExecutor);

            setOraclePool(cfg.customSender, address(pool));
            grantSyncRole(cfg.customSender, address(deployedSyncTrigger));
            configureSyncTrigger(address(deployedSyncTrigger), cfg);
            setSyncTriggerForwarder(address(deployedSyncTrigger), address(deployedCREReceiver));

            if (bootstrapPool != address(pool)) {
                _retireBootstrapPool(bootstrapPool, address(pool), cfg, governanceExecutor);
            }

            migrateSenderAdmin(cfg);
            transferProxyAdminOwnership(cfg);
            transferSyncTriggerOwnership(address(deployedSyncTrigger), governanceExecutor);
        }
        vm.stopBroadcast();

        oraclePool = address(pool);
        syncTrigger = address(deployedSyncTrigger);
        creReceiverAddr = address(deployedCREReceiver);
    }
}
