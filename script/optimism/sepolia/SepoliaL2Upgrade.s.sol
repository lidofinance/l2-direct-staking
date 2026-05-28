// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {ICustomSender} from "@csr/interfaces/ICustomSender.sol";
import {ISyncAutomation} from "@csr/interfaces/ISyncAutomation.sol";
import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";

import {L2UpgradeActions} from "script/shared/L2UpgradeActions.s.sol";
import {L2UpgradeScriptBase} from "script/shared/L2UpgradeScriptBase.s.sol";
import {SepoliaMigrationConstants as C} from "script/optimism/sepolia/SepoliaMigrationConstants.sol";

/**
 * @notice Sepolia-specific defaults for L2 upgrade.
 * @dev Unlike the four mainnet networks, deploy-time addresses (`L2_CUSTOM_SENDER`, `L2_PROXY_ADMIN`,
 *      `L2_PRICE_ORACLE`, `L2_BOOTSTRAP_SYNC_AUTOMATION`) are outputs of `SepoliaCSRDeploy` rather than
 *      Solidity constants, so this contract reads them from env. The bootstrap `SyncAutomation` is
 *      threaded into `cfg.oldChainlinkAutomation` so the standard `executeMigrationSteps` revoke path
 *      treats it identically to a mainnet legacy automation.
 */
contract SepoliaL2Defaults is Script, L2UpgradeActions {
    function defaultL2Config(address initialOwner, address governanceExecutor, address liquidityOwner)
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
            oldChainlinkAutomation: vm.envOr("L2_BOOTSTRAP_SYNC_AUTOMATION", address(0)),
            oldGelatoAutomation: address(0)
        });
    }
}

/**
 * @notice Production broadcast script for Optimism-Sepolia L2 upgrade operations.
 * @dev Inherits the same `runDeploy` / `runVerifyStage1` / `runMigrate` / `run` shape as the four
 *      mainnet scripts. The Sepolia path adds two testnet-only steps around `executeMigrationSteps`:
 *      bootstrap-automation neutralization (forwarder→0, delay→max, ownership→governance) and
 *      bootstrap-pool retirement (sweep WETH+wstETH into the new pool, pause, transfer ownership).
 *      The standard `SYNC_ROLE` revoke happens inside `executeMigrationSteps` via
 *      `cfg.oldChainlinkAutomation = $L2_BOOTSTRAP_SYNC_AUTOMATION`.
 */
contract SepoliaL2UpgradeScript is L2UpgradeScriptBase, SepoliaL2Defaults {
    error SepoliaBootstrapSyncAutomationRequired();
    error SepoliaBootstrapSyncTriggerCollision();
    error SepoliaBootstrapOraclePoolMissing();

    function _buildConfig(address initialOwner, address governanceExecutor, address liquidityOwner)
        internal
        view
        override
        returns (L2UpgradeConfig memory)
    {
        return defaultL2Config(initialOwner, governanceExecutor, liquidityOwner);
    }

    /// @dev Sepolia has no LOL multisig; default to the governance executor (the operator can override
    ///      via `L2_LIQUIDITY_OWNER` if they want to test a separate owner).
    function _defaultLiquidityOwner() internal view override returns (address) {
        return vm.envAddress("L2_GOVERNANCE_EXECUTOR");
    }

    function _expectedChainId() internal pure override returns (uint256) {
        return C.OPTIMISM_CHAIN_ID;
    }

    /// @notice Sepolia override: wraps `executeMigrationSteps` with bootstrap-automation neutralization
    /// (forwarder/delay/ownership extras beyond the role revoke handled by executeMigrationSteps) and
    /// bootstrap-pool retirement (sweep + pause + transfer; mainnet has no analog because the old pool
    /// is left intact for the Initial Liquidity Owner).
    function runMigrate() public override {
        assertL2ChainId(_expectedChainId());
        uint256 initialOwnerPrivateKey = _envInitialOwnerPrivateKey();
        address initialOwner = vm.addr(initialOwnerPrivateKey);
        vm.startBroadcast(initialOwnerPrivateKey);
        _runMigrateBody(initialOwner);
        vm.stopBroadcast();
    }

    /// @notice Sepolia override that impersonates Initial Owner (anvil unlocked-account workflows).
    function runMigrateUnlocked() public override {
        assertL2ChainId(_expectedChainId());
        address initialOwner = _envInitialOwnerAddress();
        vm.startBroadcast(initialOwner);
        _runMigrateBody(initialOwner);
        vm.stopBroadcast();
    }

    function _runMigrateBody(address initialOwner) internal {
        address governanceExecutor = vm.envAddress("L2_GOVERNANCE_EXECUTOR");
        address liquidityOwner = _envLiquidityOwnerAddress();
        address oraclePool = vm.envAddress("L2_ORACLE_POOL");
        address syncTrigger = vm.envAddress("L2_SYNC_TRIGGER");
        address bootstrapSyncAutomation = vm.envOr("L2_BOOTSTRAP_SYNC_AUTOMATION", address(0));
        if (bootstrapSyncAutomation == address(0)) revert SepoliaBootstrapSyncAutomationRequired();
        if (bootstrapSyncAutomation == syncTrigger) revert SepoliaBootstrapSyncTriggerCollision();

        L2UpgradeConfig memory cfg = _buildConfig(initialOwner, governanceExecutor, liquidityOwner);
        address bootstrapPool = ICustomSender(cfg.customSender).getOraclePool();
        if (bootstrapPool == address(0)) revert SepoliaBootstrapOraclePoolMissing();

        ISyncAutomation(bootstrapSyncAutomation).setForwarder(address(0));
        ISyncAutomation(bootstrapSyncAutomation).setDelay(type(uint48).max);
        Ownable(bootstrapSyncAutomation).transferOwnership(governanceExecutor);

        executeMigrationSteps(cfg, oraclePool, syncTrigger);

        if (bootstrapPool != oraclePool) {
            _retireBootstrapPool(bootstrapPool, oraclePool, cfg.tokenIn, cfg.tokenOut, governanceExecutor);
        }
    }

    function _retireBootstrapPool(
        address bootstrapPool,
        address replacementPool,
        address tokenIn,
        address tokenOut,
        address newOwner
    ) internal {
        _sweepPoolTokenIfAny(bootstrapPool, replacementPool, tokenIn);
        _sweepPoolTokenIfAny(bootstrapPool, replacementPool, tokenOut);
        PausableImmutableOraclePool(bootstrapPool).pause();
        Ownable(bootstrapPool).transferOwnership(newOwner);
    }

    function _sweepPoolTokenIfAny(address pool, address recipient, address token) internal {
        uint256 balance = IERC20(token).balanceOf(pool);
        if (balance != 0) {
            PausableImmutableOraclePool(pool).sweep(token, recipient, balance);
        }
    }
}
