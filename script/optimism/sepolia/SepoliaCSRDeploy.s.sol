// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {LidoCustomReceiver} from "@csr/receivers/LidoCustomReceiver.sol";
import {CustomSender} from "@csr/senders/CustomSender.sol";
import {CustomSenderReferral} from "@csr/senders/CustomSenderReferral.sol";
import {OptimismLegacyAdapterL1toL2} from "@csr/adapters/OptimismLegacyAdapterL1toL2.sol";
import {PriceOracle} from "@csr/utils/PriceOracle.sol";
import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";
import {SyncAutomation} from "@csr/automations/SyncAutomation.sol";
import {ISyncAutomation} from "@csr/interfaces/ISyncAutomation.sol";
import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {ScriptHelper} from "@csr/../script/ScriptHelper.sol";

import {MockAggregator} from "./MockAggregator.sol";
import {SepoliaMigrationConstants as C} from "script/optimism/sepolia/SepoliaMigrationConstants.sol";

/**
 * @notice Deploys the full CSR (Chainlink Staking Router) infrastructure on Sepolia testnets.
 * @dev This is the "step 0" that must run before SepoliaL2Upgrade / SepoliaL1Upgrade.
 *      On mainnet, this infra already exists. On testnet we must deploy it from scratch.
 *
 *      Deploys on Ethereum Sepolia (L1):
 *      - LidoCustomReceiver + TransparentUpgradeableProxy
 *      - OptimismLegacyAdapterL1toL2
 *
 *      Deploys on Optimism Sepolia (L2):
 *      - MockAggregator (fixed wstETH/stETH price)
 *      - PriceOracle
 *      - PausableImmutableOraclePool
 *      - CustomSenderReferral + TransparentUpgradeableProxy
 *      - SyncAutomation (bootstrap — will be replaced by SyncTrigger during migration)
 *
 *      Then wires: setAdapter, setSender, setReceiver, SYNC_ROLE, SyncAutomation config
 *
 * Required env:
 * - DEPLOYER_PRIVATE_KEY
 *
 * Required RPC aliases in foundry.toml:
 * - sepolia
 * - optimism_sepolia
 */
contract SepoliaCSRDeployScript is Script, ScriptHelper {
    /// @dev 1.2e18 — approximate wstETH/stETH exchange rate for testing
    int256 internal constant MOCK_WSTETH_STETH_PRICE = 1.2e18;
    /// @dev Heartbeat for mock aggregator (effectively infinite for testing)
    uint32 internal constant MOCK_HEARTBEAT = 365 days;

    uint256 public l1ForkId;
    uint256 public l2ForkId;

    address public deployer;

    function setUp() public {
        l1ForkId = vm.createFork(vm.rpcUrl("sepolia"));
        l2ForkId = vm.createFork(vm.rpcUrl("optimism_sepolia"));
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        // --- L1 Sepolia ---
        address receiverProxy;
        address receiverProxyAdmin;
        address receiverImpl;
        address optimismAdapter;

        vm.selectFork(l1ForkId);
        vm.startBroadcast(deployerPrivateKey);
        {
            receiverImpl = address(
                new LidoCustomReceiver(C.L1_WSTETH, C.L1_WETH, C.L1_CCIP_ROUTER, DEAD_ADDRESS)
            );

            receiverProxy = address(
                new TransparentUpgradeableProxy(
                    receiverImpl,
                    deployer,
                    abi.encodeCall(LidoCustomReceiver.initialize, (deployer))
                )
            );

            receiverProxyAdmin = _getProxyAdmin(receiverProxy);

            optimismAdapter = address(
                new OptimismLegacyAdapterL1toL2(C.L1_OPTIMISM_TOKEN_BRIDGE, receiverProxy)
            );
        }
        vm.stopBroadcast();

        console.log("=== L1 Sepolia ===");
        console.log("LidoCustomReceiver impl:", receiverImpl);
        console.log("LidoCustomReceiver proxy:", receiverProxy);
        console.log("L1 ProxyAdmin:", receiverProxyAdmin);
        console.log("OptimismAdapter:", optimismAdapter);

        // --- L2 Optimism Sepolia ---
        address mockAggregator;
        address priceOracle;
        address oraclePool;
        address senderImpl;
        address senderProxy;
        address senderProxyAdmin;
        address syncAutomation;

        vm.selectFork(l2ForkId);
        vm.startBroadcast(deployerPrivateKey);
        {
            // Deploy MockAggregator for wstETH/stETH price feed
            mockAggregator = address(new MockAggregator(MOCK_WSTETH_STETH_PRICE));

            // PriceOracle: isInverse=false (direct price), heartbeat large for testing
            priceOracle = address(new PriceOracle(mockAggregator, false, MOCK_HEARTBEAT));

            // OraclePool: the sender proxy is 2 deploys ahead of this one
            // (this pool at nonce N, sender impl at N+1, sender proxy at N+2)
            oraclePool = address(
                new PausableImmutableOraclePool(
                    _predictContractAddress(deployer, 2), // sender proxy is 2 deploys ahead
                    C.L2_WETH,
                    C.L2_WSTETH,
                    priceOracle,
                    0, // fee = 0 for testnet
                    deployer
                )
            );

            // CustomSenderReferral
            senderImpl = address(
                new CustomSenderReferral(
                    C.L2_WETH,
                    C.L2_WETH,
                    C.L2_LINK_TOKEN,
                    C.L2_CCIP_ROUTER,
                    DEAD_ADDRESS,
                    DEAD_ADDRESS
                )
            );

            senderProxy = address(
                new TransparentUpgradeableProxy(
                    senderImpl,
                    deployer,
                    abi.encodeCall(CustomSender.initialize, (oraclePool, deployer))
                )
            );

            // the pool's SENDER was nonce-predicted two deploys early; a nonce skew (e.g. an extra
            // broadcast tx sneaking in) would mis-wire the pool silently, so pin it here.
            require(
                PausableImmutableOraclePool(payable(oraclePool)).SENDER() == senderProxy,
                "OraclePool.SENDER nonce prediction mismatch"
            );

            senderProxyAdmin = _getProxyAdmin(senderProxy);

            // SyncAutomation
            syncAutomation = address(
                new SyncAutomation(senderProxy, C.ETH_CCIP_CHAIN_SELECTOR, deployer)
            );
        }
        vm.stopBroadcast();

        console.log("=== L2 Optimism Sepolia ===");
        console.log("MockAggregator:", mockAggregator);
        console.log("PriceOracle:", priceOracle);
        console.log("OraclePool:", oraclePool);
        console.log("CustomSenderReferral impl:", senderImpl);
        console.log("CustomSenderReferral proxy:", senderProxy);
        console.log("L2 ProxyAdmin:", senderProxyAdmin);
        console.log("SyncAutomation:", syncAutomation);

        // --- Wire L1: setAdapter + setSender ---
        vm.selectFork(l1ForkId);
        vm.startBroadcast(deployerPrivateKey);
        {
            LidoCustomReceiver receiver = LidoCustomReceiver(payable(receiverProxy));

            receiver.setAdapter(C.OPTIMISM_CCIP_CHAIN_SELECTOR, optimismAdapter);
            receiver.setSender(C.OPTIMISM_CCIP_CHAIN_SELECTOR, abi.encode(senderProxy));
        }
        vm.stopBroadcast();

        // --- Wire L2: setReceiver + SYNC_ROLE + SyncAutomation config ---
        vm.selectFork(l2ForkId);
        vm.startBroadcast(deployerPrivateKey);
        {
            CustomSenderReferral sender = CustomSenderReferral(senderProxy);
            ISyncAutomation automation = ISyncAutomation(syncAutomation);

            sender.setReceiver(C.ETH_CCIP_CHAIN_SELECTOR, abi.encode(receiverProxy));
            sender.grantRole(sender.SYNC_ROLE(), syncAutomation);

            automation.setFeeOtoD(
                FeeCodec.encodeCCIP(
                    C.L2_SYNC_DESTINATION_MAX_FEE,
                    C.L2_SYNC_DESTINATION_PAY_IN_LINK,
                    C.L2_SYNC_DESTINATION_GAS_LIMIT
                )
            );
            automation.setFeeDtoO(FeeCodec.encodeOptimismL1toL2(C.L2_SYNC_ORIGIN_L2_GAS));
            automation.setAmounts(C.L2_SYNC_MIN_AMOUNT, C.L2_SYNC_MAX_AMOUNT);
            automation.setDelay(C.L2_SYNC_DELAY);
        }
        vm.stopBroadcast();

        // --- Summary ---
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Set these env vars for upgrade scripts:");
        console.log("");
        console.log("# L1 (Sepolia)");
        console.log("L1_LIDO_CUSTOM_RECEIVER=", receiverProxy);
        console.log("L1_PROXY_ADMIN=", receiverProxyAdmin);
        console.log("");
        console.log("# L2 (Optimism Sepolia)");
        console.log("L2_BOOTSTRAP_ORACLE_POOL=", oraclePool);
        console.log("L2_BOOTSTRAP_SYNC_AUTOMATION=", syncAutomation);
        console.log("L2_CUSTOM_SENDER=", senderProxy);
        console.log("L2_PROXY_ADMIN=", senderProxyAdmin);
        console.log("L2_PRICE_ORACLE=", priceOracle);
    }
}
