// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CCIPLocalSimulatorFork, Register} from "chainlink-local/ccip/CCIPLocalSimulatorFork.sol";

import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";
import {ICustomSender} from "@csr/interfaces/ICustomSender.sol";
import {ICustomReceiver} from "@csr/interfaces/ICustomReceiver.sol";
import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {ISyncTrigger} from "src/interfaces/ISyncTrigger.sol";
import {CREReceiver} from "src/cre/CREReceiver.sol";
import {L1MigrationConstants as L1} from "script/shared/L1MigrationConstants.sol";
import {L1UpgradeActions} from "script/shared/L1UpgradeActions.s.sol";
import {L2UpgradeActions} from "script/shared/L2UpgradeActions.s.sol";

/**
 * @title UpgradeTestBase
 * @notice Network-agnostic abstract base for CSR lane migration fork tests.
 * @dev Subclasses populate state variables with network-specific constants in setUp()
 *      and implement virtual functions for config/fee encoding.
 */
abstract contract UpgradeTestBase is Test, L1UpgradeActions, L2UpgradeActions {
    // ──────────────── Constants (same for all networks) ─────────────────

    bytes4 internal constant ACCESS_CONTROL_UNAUTHORIZED_SELECTOR =
        bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));

    bytes32 internal constant EIP1967_IMPL_SLOT = L1.EIP1967_IMPL_SLOT;
    bytes32 internal constant EIP1967_ADMIN_SLOT = L1.EIP1967_ADMIN_SLOT;

    // ──────────────── Network config (set by subclass) ──────────────────

    // Owners
    address internal INITIAL_OWNER;
    address internal LIDO_DAO_AGENT;
    address internal LIDO_L2_GOVERNANCE_EXECUTOR;
    address internal lidoL2LiquidityOwner;

    // L1
    address internal L1_LIDO_CUSTOM_RECEIVER;
    address internal L1_LIDO_CUSTOM_RECEIVER_IMPL;
    address internal L1_PROXY_ADMIN;
    address internal L1_WETH;
    address internal L1_WSTETH;
    address internal L1_LINK_TOKEN;
    address internal L1_CCIP_ROUTER;
    address internal L1_ADAPTER;

    // L2
    address internal L2_CUSTOM_SENDER;
    address internal L2_CUSTOM_SENDER_IMPL;
    address internal L2_PROXY_ADMIN;
    address internal L2_OLD_ORACLE_POOL;
    address internal L2_PRICE_ORACLE;
    address internal L2_WETH;
    address internal L2_WSTETH;
    address internal L2_CCIP_ROUTER;
    address internal L2_LINK_TOKEN;

    // Chain
    uint64 internal ETH_CCIP_CHAIN_SELECTOR;
    uint64 internal L2_CCIP_CHAIN_SELECTOR;
    uint256 internal ETH_CHAIN_ID;
    uint256 internal L2_CHAIN_ID;

    // Sync defaults
    uint128 internal L2_SYNC_DESTINATION_MAX_FEE;
    bool internal L2_SYNC_DESTINATION_PAY_IN_LINK;
    uint32 internal L2_SYNC_DESTINATION_GAS_LIMIT;
    uint128 internal L2_SYNC_MIN_AMOUNT;
    uint128 internal L2_SYNC_MAX_AMOUNT;
    uint48 internal L2_SYNC_DELAY;

    // Old sync automations (to verify revocation)
    address internal L2_OLD_CHAINLINK_AUTOMATION;
    address internal L2_OLD_GELATO_AUTOMATION;

    // ──────────────── Fork state ────────────────────────────────────────

    uint256 internal l1Fork;
    uint256 internal l2Fork;
    CCIPLocalSimulatorFork internal ccipLocalSimulatorFork;

    // ──────────────── Virtual interface ─────────────────────────────────

    /// @dev Returns the L2 RPC URL env var value.
    function _l2RpcUrl() internal view virtual returns (string memory);

    /// @dev Returns the L1 RPC URL env var value.
    function _l1RpcUrl() internal view virtual returns (string memory);

    /// @dev Returns a default L2 upgrade config for the network.
    function _defaultL2Config(address initialOwner, address governanceExecutor, address liquidityOwner)
        internal
        view
        virtual
        returns (L2UpgradeConfig memory);

    /// @dev Returns a default L1 upgrade config for the network.
    function _defaultL1Config(address initialOwner, address lidoDaoAgent)
        internal
        view
        virtual
        returns (L1UpgradeConfig memory);

    /// @dev Returns the pre-encoded bridge fee (D→O) for the network.
    function _defaultFeeDtoO() internal pure virtual returns (bytes memory);

    // ──────────────── Setup ─────────────────────────────────────────────

    function setUp() public virtual {
        // Shared L1 constants (same for all networks)
        INITIAL_OWNER = L1.INITIAL_OWNER;
        LIDO_DAO_AGENT = L1.LIDO_DAO_AGENT;
        L1_LIDO_CUSTOM_RECEIVER = L1.L1_LIDO_CUSTOM_RECEIVER;
        L1_LIDO_CUSTOM_RECEIVER_IMPL = L1.L1_LIDO_CUSTOM_RECEIVER_IMPL;
        L1_PROXY_ADMIN = L1.L1_PROXY_ADMIN;
        L1_WETH = L1.L1_WETH;
        L1_WSTETH = L1.L1_WSTETH;
        L1_LINK_TOKEN = L1.L1_LINK_TOKEN;
        L1_CCIP_ROUTER = L1.L1_CCIP_ROUTER;
        ETH_CCIP_CHAIN_SELECTOR = L1.ETH_CCIP_CHAIN_SELECTOR;
        ETH_CHAIN_ID = L1.ETH_CHAIN_ID;

        lidoL2LiquidityOwner = makeAddr("l2LiquidityOwner");
        l2Fork = vm.createFork(_l2RpcUrl());
        l1Fork = vm.createFork(_l1RpcUrl());

        vm.selectFork(l1Fork);
        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        _setupChainlinkLocalForForkRouting();
    }

    function _setupChainlinkLocalForForkRouting() internal {
        Register.NetworkDetails memory l1Details = Register.NetworkDetails({
            chainSelector: ETH_CCIP_CHAIN_SELECTOR,
            routerAddress: L1_CCIP_ROUTER,
            linkAddress: L1_LINK_TOKEN,
            wrappedNativeAddress: L1_WETH,
            ccipBnMAddress: address(0),
            ccipLnMAddress: address(0),
            rmnProxyAddress: address(0),
            registryModuleOwnerCustomAddress: address(0),
            tokenAdminRegistryAddress: address(0)
        });

        Register.NetworkDetails memory l2Details = Register.NetworkDetails({
            chainSelector: L2_CCIP_CHAIN_SELECTOR,
            routerAddress: L2_CCIP_ROUTER,
            linkAddress: L2_LINK_TOKEN,
            wrappedNativeAddress: L2_WETH,
            ccipBnMAddress: address(0),
            ccipLnMAddress: address(0),
            rmnProxyAddress: address(0),
            registryModuleOwnerCustomAddress: address(0),
            tokenAdminRegistryAddress: address(0)
        });

        ccipLocalSimulatorFork.setNetworkDetails(ETH_CHAIN_ID, l1Details);
        ccipLocalSimulatorFork.setNetworkDetails(L2_CHAIN_ID, l2Details);
    }

    // ──────────────── Helpers ───────────────────────────────────────────

    function _expectAccessControlUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(ACCESS_CONTROL_UNAUTHORIZED_SELECTOR, account, role));
    }

    function _deployL2Pool(L2UpgradeConfig memory cfg)
        internal
        returns (PausableImmutableOraclePool newPool)
    {
        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        newPool = deployPool(cfg);
    }

    function _deployL2SyncTrigger(L2UpgradeConfig memory cfg)
        internal
        returns (address newSyncTrigger)
    {
        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        newSyncTrigger = address(deploySyncTrigger(cfg));
    }

    function _deployAndMigrateL2WithSyncTrigger()
        internal
        returns (PausableImmutableOraclePool newPool, address newSyncTrigger)
    {
        vm.selectFork(l2Fork);

        L2UpgradeConfig memory cfg =
            _defaultL2Config(INITIAL_OWNER, LIDO_L2_GOVERNANCE_EXECUTOR, lidoL2LiquidityOwner);

        newPool = _deployL2Pool(cfg);
        newSyncTrigger = _deployL2SyncTrigger(cfg);

        vm.startPrank(INITIAL_OWNER);
        executeMigrationSteps(cfg, address(newPool), newSyncTrigger, address(0));
        vm.stopPrank();
    }

    function _deployAndMigrateL2() internal returns (PausableImmutableOraclePool newPool) {
        (newPool,) = _deployAndMigrateL2WithSyncTrigger();
    }

    function _deployAndMigrateL2Production()
        internal
        returns (PausableImmutableOraclePool newPool, address newSyncTrigger, CREReceiver newCREReceiver)
    {
        vm.selectFork(l2Fork);

        L2UpgradeConfig memory cfg =
            _defaultL2Config(INITIAL_OWNER, LIDO_L2_GOVERNANCE_EXECUTOR, lidoL2LiquidityOwner);

        // Stage 1: Deploy (as Lido Deployer)
        newPool = _deployL2Pool(cfg);
        newSyncTrigger = _deployL2SyncTrigger(cfg);
        address creForwarderAddr = makeAddr("creForwarder");
        newCREReceiver = deployCREReceiver(creForwarderAddr);
        transferCREReceiverOwnership(address(newCREReceiver), lidoL2LiquidityOwner);

        // Stage 2: Migrate using production function (as Initial Owner)
        vm.startPrank(INITIAL_OWNER);
        executeMigrationSteps(cfg, address(newPool), newSyncTrigger, address(newCREReceiver));
        vm.stopPrank();
    }

    function _deployAndMigrateL1() internal {
        vm.selectFork(l1Fork);

        L1UpgradeConfig memory cfg = _defaultL1Config(INITIAL_OWNER, LIDO_DAO_AGENT);

        vm.startPrank(INITIAL_OWNER);
        execute(cfg);
        vm.stopPrank();
    }

    function _migrateL2ProxyAdminOnly() internal {
        vm.prank(INITIAL_OWNER);
        Ownable(L2_PROXY_ADMIN).transferOwnership(LIDO_L2_GOVERNANCE_EXECUTOR);
    }

    function _verifySyncTriggerConfig(address syncTrigger) internal {
        assertEq(ISyncTrigger(syncTrigger).SENDER(), L2_CUSTOM_SENDER, "sync trigger SENDER");
        assertEq(
            ISyncTrigger(syncTrigger).DEST_CHAIN_SELECTOR(),
            ETH_CCIP_CHAIN_SELECTOR,
            "sync trigger destination selector"
        );
        assertEq(ISyncTrigger(syncTrigger).WNATIVE(), L2_WETH, "sync trigger WNATIVE");
        assertEq(Ownable(syncTrigger).owner(), LIDO_L2_GOVERNANCE_EXECUTOR, "sync trigger owner");

        (uint128 minSyncAmount, uint128 maxSyncAmount) = ISyncTrigger(syncTrigger).getAmounts();
        assertEq(minSyncAmount, L2_SYNC_MIN_AMOUNT, "sync trigger min sync amount");
        assertEq(maxSyncAmount, L2_SYNC_MAX_AMOUNT, "sync trigger max sync amount");
        assertEq(ISyncTrigger(syncTrigger).getDelay(), L2_SYNC_DELAY, "sync trigger delay");
        (bytes memory expectedFeeOtoD, bytes memory expectedFeeDtoO) = _defaultSyncFees();
        assertEq(
            keccak256(ISyncTrigger(syncTrigger).getFeeOtoD()),
            keccak256(expectedFeeOtoD),
            "sync trigger fee O->D"
        );
        assertEq(
            keccak256(ISyncTrigger(syncTrigger).getFeeDtoO()),
            keccak256(expectedFeeDtoO),
            "sync trigger fee D->O"
        );
        assertTrue(
            IAccessControl(L2_CUSTOM_SENDER).hasRole(SYNC_ROLE, syncTrigger),
            "sync trigger should have SYNC_ROLE on custom sender"
        );
    }

    function _verifySyncTriggerConfig(address syncTrigger, address expectedForwarder) internal {
        _verifySyncTriggerConfig(syncTrigger);
        assertEq(ISyncTrigger(syncTrigger).getForwarder(), expectedForwarder, "sync trigger forwarder");
    }

    function _verifyOldAutomationsRevoked() internal {
        if (L2_OLD_CHAINLINK_AUTOMATION != address(0)) {
            assertFalse(
                IAccessControl(L2_CUSTOM_SENDER).hasRole(SYNC_ROLE, L2_OLD_CHAINLINK_AUTOMATION),
                "L2 sender: old Chainlink automation should not have SYNC_ROLE"
            );
        }
        if (L2_OLD_GELATO_AUTOMATION != address(0)) {
            assertFalse(
                IAccessControl(L2_CUSTOM_SENDER).hasRole(SYNC_ROLE, L2_OLD_GELATO_AUTOMATION),
                "L2 sender: old Gelato automation should not have SYNC_ROLE"
            );
        }
    }

    function _provisionPoolAndAccumulateWeth(PausableImmutableOraclePool newPool, uint256 stakeAmount)
        internal
        returns (uint256 poolWeth)
    {
        deal(L2_WSTETH, address(newPool), 100 ether);

        address user = makeAddr("poolWethAccumulator");
        deal(L2_WETH, user, stakeAmount);

        vm.startPrank(user);
        IERC20(L2_WETH).approve(L2_CUSTOM_SENDER, stakeAmount);
        ICustomSender(L2_CUSTOM_SENDER).fastStake(L2_WETH, stakeAmount, 0);
        vm.stopPrank();

        poolWeth = IERC20(L2_WETH).balanceOf(address(newPool));
    }

    function _defaultSyncFees() internal view returns (bytes memory feeOtoD, bytes memory feeDtoO) {
        feeOtoD = FeeCodec.encodeCCIP(
            L2_SYNC_DESTINATION_MAX_FEE, L2_SYNC_DESTINATION_PAY_IN_LINK, L2_SYNC_DESTINATION_GAS_LIMIT
        );
        feeDtoO = _defaultFeeDtoO();
    }

    function _verifyL1PostMigrationState() internal {
        address impl = address(uint160(uint256(vm.load(L1_LIDO_CUSTOM_RECEIVER, EIP1967_IMPL_SLOT))));
        assertEq(impl, L1_LIDO_CUSTOM_RECEIVER_IMPL, "L1 proxy implementation should be unchanged");

        address proxyAdmin = address(uint160(uint256(vm.load(L1_LIDO_CUSTOM_RECEIVER, EIP1967_ADMIN_SLOT))));
        assertEq(proxyAdmin, L1_PROXY_ADMIN, "L1 proxy admin slot should be unchanged");

        assertEq(ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).CCIP_ROUTER(), L1_CCIP_ROUTER, "L1 receiver CCIP_ROUTER");

        assertEq(
            ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).getAdapter(L2_CCIP_CHAIN_SELECTOR),
            L1_ADAPTER,
            "L1 receiver adapter should still be the L1 adapter"
        );

        assertEq(
            ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).getSender(L2_CCIP_CHAIN_SELECTOR),
            abi.encode(L2_CUSTOM_SENDER),
            "L1 receiver: sender mapping for L2 should be unchanged"
        );

        assertTrue(
            IAccessControl(L1_LIDO_CUSTOM_RECEIVER).hasRole(DEFAULT_ADMIN_ROLE, LIDO_DAO_AGENT),
            "L1 receiver: LIDO_DAO_AGENT should have DEFAULT_ADMIN_ROLE"
        );
        assertFalse(
            IAccessControl(L1_LIDO_CUSTOM_RECEIVER).hasRole(DEFAULT_ADMIN_ROLE, INITIAL_OWNER),
            "L1 receiver: INITIAL_OWNER should not have DEFAULT_ADMIN_ROLE"
        );

        assertEq(Ownable(L1_PROXY_ADMIN).owner(), LIDO_DAO_AGENT, "L1 ProxyAdmin owner");
    }

    function _prepareAndSyncL2(PausableImmutableOraclePool newPool)
        internal
        returns (bytes32 messageId, bytes32 feeDtoOHash)
    {
        vm.selectFork(l2Fork);
        uint256 stakeAmount = 2 ether;
        uint256 syncAmount = _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        assertEq(syncAmount, stakeAmount, "pool should hold WETH collected from fastStake");

        address rebalancer = makeAddr("ccipRebalancer");
        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        IAccessControl(L2_CUSTOM_SENDER).grantRole(SYNC_ROLE, rebalancer);

        (bytes memory feeOtoD, bytes memory feeDtoO) = _defaultSyncFees();
        feeDtoOHash = keccak256(feeDtoO);

        vm.deal(rebalancer, 1 ether);
        vm.recordLogs();

        vm.prank(rebalancer);
        messageId = ICustomSender(L2_CUSTOM_SENDER).sync{value: 0.1 ether}(
            ETH_CCIP_CHAIN_SELECTOR, syncAmount, feeOtoD, feeDtoO
        );

        assertTrue(messageId != bytes32(0), "sync should return messageId");
        assertEq(IERC20(L2_WETH).balanceOf(address(newPool)), 0, "L2 pool WETH should be pulled for CCIP");
    }

    function _assertAndGetAdapterDispatch(
        Vm.Log[] memory entries,
        address expectedRecipient,
        bytes32 expectedFeeDataHash
    ) internal returns (uint256 bridgedWstAmount) {
        bytes32 adapterInvokedSig = keccak256("AdapterInvoked(uint64,address,bytes32,uint256,uint256)");
        bool adapterCallFound;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter != L1_LIDO_CUSTOM_RECEIVER || entries[i].topics.length != 4) continue;
            if (entries[i].topics[0] != adapterInvokedSig) continue;

            assertEq(uint64(uint256(entries[i].topics[1])), L2_CCIP_CHAIN_SELECTOR, "adapter source selector");
            assertEq(
                address(uint160(uint256(entries[i].topics[2]))),
                expectedRecipient,
                "adapter recipient should be the L2 pool"
            );
            assertEq(entries[i].topics[3], expectedFeeDataHash, "adapter feeData hash");

            (uint256 amount, uint256 value) = abi.decode(entries[i].data, (uint256, uint256));
            assertEq(value, 0, "adapter call should not forward native value");

            bridgedWstAmount = amount;
            adapterCallFound = true;
            break;
        }

        assertTrue(adapterCallFound, "adapter dispatch event should be emitted");
        assertGt(bridgedWstAmount, 0, "L1 receiver should bridge non-zero wstETH amount");
    }

    function _simulateL2BridgeFinalization(address pool, uint256 bridgedWstAmount) internal {
        vm.selectFork(l2Fork);
        MockL2BridgeFinalizer mockL2BridgeFinalizer = new MockL2BridgeFinalizer();
        uint256 poolWstBeforeReplenish = IERC20(L2_WSTETH).balanceOf(pool);
        deal(L2_WSTETH, address(mockL2BridgeFinalizer), bridgedWstAmount);
        mockL2BridgeFinalizer.finalize(L2_WSTETH, pool, bridgedWstAmount);
        assertEq(
            IERC20(L2_WSTETH).balanceOf(pool),
            poolWstBeforeReplenish + bridgedWstAmount,
            "L2 pool should be replenished after bridge finalization"
        );
        assertEq(
            IERC20(L2_WSTETH).balanceOf(address(mockL2BridgeFinalizer)),
            0,
            "mock finalizer should not retain bridged wstETH"
        );
    }
}

contract MockBridgeAdapter {
    event AdapterInvoked(
        uint64 indexed sourceChainSelector,
        address indexed recipient,
        bytes32 indexed feeDataHash,
        uint256 amount,
        uint256 value
    );

    function sendToken(uint64 sourceChainSelector, address recipient, uint256 amount, bytes calldata feeData)
        external
        payable
    {
        emit AdapterInvoked(sourceChainSelector, recipient, keccak256(feeData), amount, msg.value);
    }
}

contract MockL2BridgeFinalizer {
    error MockL2BridgeFinalizerTransferFailed();

    function finalize(address token, address recipient, uint256 amount) external {
        if (!IERC20(token).transfer(recipient, amount)) revert MockL2BridgeFinalizerTransferFailed();
    }
}
