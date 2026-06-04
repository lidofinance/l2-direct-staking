// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SyncTrigger} from "src/SyncTrigger.sol";
import {ISyncTrigger} from "src/interfaces/ISyncTrigger.sol";
import {FeeCodec} from "@csr/libraries/FeeCodec.sol";

/// @notice Minimal mock for ICustomSender — just enough for SyncTrigger constructor + sync
contract MockCustomSender {
    address public immutable WNATIVE;
    address public immutable LINK_TOKEN;
    address public oraclePool;

    bool public shouldRevertSync;
    uint256 public lastSyncAmount;
    uint256 public lastSyncValue;

    constructor(address wnative_, address linkToken_) {
        WNATIVE = wnative_;
        LINK_TOKEN = linkToken_;
    }

    function getOraclePool() external view returns (address) {
        return oraclePool;
    }

    function setOraclePool(address pool) external {
        oraclePool = pool;
    }

    function setShouldRevertSync(bool v) external {
        shouldRevertSync = v;
    }

    function sync(uint64, uint256 amount, bytes calldata, bytes calldata) external payable returns (bytes32) {
        if (shouldRevertSync) revert("sync failed");
        lastSyncAmount = amount;
        lastSyncValue = msg.value;
        return keccak256(abi.encode(amount));
    }
}

/// @notice Minimal ERC20 mock
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function forceApprove(address, uint256) external {}
}

/**
 * @title SyncTriggerTest
 * @notice Unit tests for SyncTrigger contract covering:
 *   - Construction & initial state
 *   - Admin setters (setForwarder, setDelay, setAmounts, setFeeOtoD, setFeeDtoO, sweep)
 *   - Access control on all admin functions
 *   - shouldSync view logic
 *   - triggerSync execution + edge cases
 */
contract SyncTriggerTest is Test {
    event ForwarderSet(address forwarder);
    event DelaySet(uint48 delay);
    event AmountsSet(uint128 minAmount, uint128 maxAmount);

    SyncTrigger internal trigger;
    MockCustomSender internal sender;
    MockERC20 internal weth;
    MockERC20 internal link;
    address internal oraclePool;
    address internal forwarder = makeAddr("forwarder");
    address internal owner;
    uint64 internal constant DEST_CHAIN = 1;

    function setUp() public {
        owner = address(this);
        weth = new MockERC20();
        link = new MockERC20();
        sender = new MockCustomSender(address(weth), address(link));
        oraclePool = makeAddr("oraclePool");
        sender.setOraclePool(oraclePool);
        trigger = new SyncTrigger(address(sender), DEST_CHAIN, owner);
    }

    // ─── Construction ──────────────────────────────────────────────────

    function test_constructor_setsImmutables() public {
        assertEq(trigger.SENDER(), address(sender));
        assertEq(trigger.DEST_CHAIN_SELECTOR(), DEST_CHAIN);
        assertEq(trigger.WNATIVE(), address(weth));
        assertEq(trigger.owner(), owner);
    }

    function test_constructor_initializesDeactivated() public {
        assertEq(trigger.getDelay(), type(uint48).max);
        assertEq(trigger.getLastExecution(), uint48(block.timestamp));
        assertEq(trigger.getForwarder(), address(0));
        (uint128 min, uint128 max) = trigger.getAmounts();
        assertEq(min, 0);
        assertEq(max, 0);
    }

    function test_constructor_revertsOnZeroSender() public {
        vm.expectRevert(ISyncTrigger.SyncTriggerInvalidParameters.selector);
        new SyncTrigger(address(0), DEST_CHAIN, owner);
    }

    function test_constructor_revertsOnZeroChainSelector() public {
        vm.expectRevert(ISyncTrigger.SyncTriggerInvalidParameters.selector);
        new SyncTrigger(address(sender), 0, owner);
    }

    // ─── setForwarder ──────────────────────────────────────────────────

    function test_setForwarder_updatesForwarder() public {
        trigger.setForwarder(forwarder);
        assertEq(trigger.getForwarder(), forwarder);
    }

    function test_setForwarder_canSetToZero() public {
        trigger.setForwarder(forwarder);
        trigger.setForwarder(address(0));
        assertEq(trigger.getForwarder(), address(0));
    }

    function test_setForwarder_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit ForwarderSet(forwarder);
        trigger.setForwarder(forwarder);
    }

    function test_setForwarder_revertsIfNotOwner() public {
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        trigger.setForwarder(forwarder);
    }

    // ─── setDelay ──────────────────────────────────────────────────────

    function test_setDelay_updatesDelay() public {
        trigger.setDelay(1 hours);
        assertEq(trigger.getDelay(), 1 hours);
    }

    function test_setDelay_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit DelaySet(1 hours);
        trigger.setDelay(1 hours);
    }

    function test_setDelay_revertsIfNotOwner() public {
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        trigger.setDelay(1 hours);
    }

    // ─── setAmounts ────────────────────────────────────────────────────

    function test_setAmounts_updatesAmounts() public {
        trigger.setAmounts(1 ether, 10 ether);
        (uint128 min, uint128 max) = trigger.getAmounts();
        assertEq(min, 1 ether);
        assertEq(max, 10 ether);
    }

    function test_setAmounts_revertsOnZeroMin() public {
        vm.expectRevert(abi.encodeWithSelector(ISyncTrigger.SyncTriggerInvalidAmounts.selector, 0, 10 ether));
        trigger.setAmounts(0, 10 ether);
    }

    function test_setAmounts_revertsWhenMinGtMax() public {
        vm.expectRevert(abi.encodeWithSelector(ISyncTrigger.SyncTriggerInvalidAmounts.selector, 10 ether, 1 ether));
        trigger.setAmounts(10 ether, 1 ether);
    }

    function test_setAmounts_allowsMinEqMax() public {
        trigger.setAmounts(5 ether, 5 ether);
        (uint128 min, uint128 max) = trigger.getAmounts();
        assertEq(min, 5 ether);
        assertEq(max, 5 ether);
    }

    function test_setAmounts_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit AmountsSet(1 ether, 10 ether);
        trigger.setAmounts(1 ether, 10 ether);
    }

    function test_setAmounts_revertsIfNotOwner() public {
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        trigger.setAmounts(1 ether, 10 ether);
    }

    // ─── setFeeOtoD / setFeeDtoO ───────────────────────────────────────

    function test_setFeeOtoD_updatesFee() public {
        bytes memory fee = hex"deadbeef";
        trigger.setFeeOtoD(fee);
        assertEq(keccak256(trigger.getFeeOtoD()), keccak256(fee));
    }

    function test_setFeeDtoO_updatesFee() public {
        bytes memory fee = hex"cafebabe";
        trigger.setFeeDtoO(fee);
        assertEq(keccak256(trigger.getFeeDtoO()), keccak256(fee));
    }

    function test_setFeeOtoD_revertsIfNotOwner() public {
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        trigger.setFeeOtoD(hex"00");
    }

    function test_setFeeDtoO_revertsIfNotOwner() public {
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        trigger.setFeeDtoO(hex"00");
    }

    // ─── sweep ─────────────────────────────────────────────────────────

    function test_sweep_transfersTokens() public {
        address recipient = makeAddr("recipient");
        deal(address(weth), address(trigger), 5 ether);
        // MockERC20 doesn't support real transfer; test via native ETH sweep
        vm.deal(address(trigger), 3 ether);
        trigger.sweep(address(0), recipient, 3 ether);
        assertEq(recipient.balance, 3 ether);
    }

    function test_sweep_revertsIfNotOwner() public {
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        trigger.sweep(address(0), makeAddr("r"), 1);
    }

    // ─── shouldSync ────────────────────────────────────────────────────

    function test_shouldSync_revertsWhenDeactivated() public {
        // Default delay is type(uint48).max — addition with lastExecution overflows uint48
        trigger.setAmounts(1 ether, 10 ether);
        weth.mint(oraclePool, 5 ether);
        vm.expectRevert();
        trigger.shouldSync();
    }

    function test_shouldSync_falseBeforeDelay() public {
        _configureForSync(1 ether, 10 ether, 1 hours);
        weth.mint(oraclePool, 5 ether);
        // Don't warp — still within delay
        (bool needed,) = trigger.shouldSync();
        assertFalse(needed);
    }

    function test_shouldSync_falseWhenBelowMin() public {
        _configureForSync(5 ether, 10 ether, 1 hours);
        weth.mint(oraclePool, 4 ether); // below min
        vm.warp(block.timestamp + 1 hours);
        (bool needed,) = trigger.shouldSync();
        assertFalse(needed);
    }

    function test_shouldSync_trueAtExactMin() public {
        _configureForSync(5 ether, 10 ether, 1 hours);
        weth.mint(oraclePool, 5 ether); // exactly min
        vm.warp(block.timestamp + 1 hours);
        (bool needed, uint256 amount) = trigger.shouldSync();
        assertTrue(needed);
        assertEq(amount, 5 ether);
    }

    function test_shouldSync_capsAtMax() public {
        _configureForSync(5 ether, 10 ether, 1 hours);
        weth.mint(oraclePool, 50 ether); // well above max
        vm.warp(block.timestamp + 1 hours);
        (bool needed, uint256 amount) = trigger.shouldSync();
        assertTrue(needed);
        assertEq(amount, 10 ether);
    }

    // ─── triggerSync ───────────────────────────────────────────────────

    function test_triggerSync_revertsIfNotForwarder() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(ISyncTrigger.SyncTriggerOnlyForwarder.selector);
        trigger.triggerSync();
    }

    function test_triggerSync_revertsIfSyncNotNeeded() public {
        _configureForSync(5 ether, 10 ether, 1 hours);
        trigger.setForwarder(forwarder);
        // Pool has no WETH, so amount is 0
        vm.warp(block.timestamp + 1 hours);
        vm.prank(forwarder);
        vm.expectRevert(ISyncTrigger.SyncTriggerSyncNotNeeded.selector);
        trigger.triggerSync();
    }

    function test_triggerSync_happyPath_nativeFees() public {
        uint128 maxFeeOtoD = 0.1 ether;
        uint128 feeDtoO = 0.05 ether;
        _armTriggerSync(1 ether, 10 ether, 1 hours, 5 ether, _encodeFee(maxFeeOtoD, false), _encodeFee(feeDtoO, false));

        vm.prank(forwarder);
        trigger.triggerSync();

        assertEq(sender.lastSyncAmount(), 5 ether, "synced amount");
        assertEq(sender.lastSyncValue(), uint256(maxFeeOtoD) + feeDtoO, "native fee forwarded");
        assertEq(trigger.getLastExecution(), uint48(block.timestamp), "lastExecution advanced");
    }

    function test_triggerSync_linkFees_sendsZeroValue() public {
        _armTriggerSync(1 ether, 10 ether, 1 hours, 5 ether, _encodeFee(0.1 ether, true), _encodeFee(0.05 ether, true));

        vm.prank(forwarder);
        trigger.triggerSync();

        // Both legs paid in LINK → no native value should accompany the sync call.
        assertEq(sender.lastSyncValue(), 0, "no native fee when both legs pay in LINK");
        assertEq(sender.lastSyncAmount(), 5 ether, "synced amount");
    }

    function test_triggerSync_mixedFees_forwardsOnlyNativeLeg() public {
        uint128 maxFeeOtoD = 0.1 ether;
        // OtoD native, DtoO in LINK → only the OtoD leg contributes native value.
        _armTriggerSync(1 ether, 10 ether, 1 hours, 5 ether, _encodeFee(maxFeeOtoD, false), _encodeFee(0.05 ether, true));

        vm.prank(forwarder);
        trigger.triggerSync();

        assertEq(sender.lastSyncValue(), maxFeeOtoD, "only native OtoD leg forwarded");
    }

    function test_triggerSync_capsAtMax() public {
        _armTriggerSync(1 ether, 10 ether, 1 hours, 50 ether, _encodeFee(0.1 ether, false), _encodeFee(0.05 ether, false));

        vm.prank(forwarder);
        trigger.triggerSync();

        assertEq(sender.lastSyncAmount(), 10 ether, "synced amount capped at maxAmount");
    }

    function test_triggerSync_blocksImmediateRetrigger() public {
        _armTriggerSync(1 ether, 10 ether, 1 hours, 5 ether, _encodeFee(0.1 ether, false), _encodeFee(0.05 ether, false));

        vm.prank(forwarder);
        trigger.triggerSync();

        // Same delay window → _lastExecution was just set, so a second call is rate-limited.
        vm.prank(forwarder);
        vm.expectRevert(ISyncTrigger.SyncTriggerSyncNotNeeded.selector);
        trigger.triggerSync();
    }

    // ─── getMaxFees ────────────────────────────────────────────────────

    function test_getMaxFees_nativeBoth() public {
        trigger.setFeeOtoD(_encodeFee(0.1 ether, false));
        trigger.setFeeDtoO(_encodeFee(0.05 ether, false));
        (uint256 maxNativeFee, uint256 maxLinkFee) = trigger.getMaxFees();
        assertEq(maxNativeFee, 0.15 ether, "native sum");
        assertEq(maxLinkFee, 0, "no link fee");
    }

    function test_getMaxFees_linkBoth() public {
        trigger.setFeeOtoD(_encodeFee(0.1 ether, true));
        trigger.setFeeDtoO(_encodeFee(0.05 ether, true));
        (uint256 maxNativeFee, uint256 maxLinkFee) = trigger.getMaxFees();
        assertEq(maxNativeFee, 0, "no native fee");
        assertEq(maxLinkFee, 0.15 ether, "link sum");
    }

    function test_getMaxFees_mixed() public {
        trigger.setFeeOtoD(_encodeFee(0.1 ether, false)); // native
        trigger.setFeeDtoO(_encodeFee(0.05 ether, true)); // link
        (uint256 maxNativeFee, uint256 maxLinkFee) = trigger.getMaxFees();
        assertEq(maxNativeFee, 0.1 ether, "native OtoD leg");
        assertEq(maxLinkFee, 0.05 ether, "link DtoO leg");
    }

    // ─── getAmountToSync (public wrapper) ──────────────────────────────

    function test_getAmountToSync_returnsAmount() public {
        _configureForSync(1 ether, 10 ether, 1 hours);
        weth.mint(oraclePool, 5 ether);
        vm.warp(block.timestamp + 1 hours);
        (, uint256 expected) = trigger.shouldSync();
        assertEq(trigger.getAmountToSync(), expected, "wrapper matches shouldSync");
        assertEq(trigger.getAmountToSync(), 5 ether);
    }

    // ─── receive ───────────────────────────────────────────────────────

    function test_canReceiveEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(trigger).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(trigger).balance, 1 ether);
    }

    // ─── Helpers ───────────────────────────────────────────────────────

    function _configureForSync(uint128 minAmount, uint128 maxAmount, uint48 delay) internal {
        trigger.setAmounts(minAmount, maxAmount);
        trigger.setDelay(delay);
    }

    /// @dev Builds a valid (21-byte) CCIP fee buffer; `decodeFeeMemory` reads the first 17 bytes.
    function _encodeFee(uint128 maxFee, bool payInLink) internal pure returns (bytes memory) {
        return FeeCodec.encodeCCIP(maxFee, payInLink, 1_000_000);
    }

    /// @dev Arms the trigger for a successful triggerSync: amounts, delay, forwarder, both fee
    ///      buffers, a funded pool, native ETH on the trigger to front the CCIP fee, and a warp
    ///      past `delay`.
    function _armTriggerSync(
        uint128 minAmount,
        uint128 maxAmount,
        uint48 delay,
        uint256 poolBalance,
        bytes memory feeOtoD,
        bytes memory feeDtoO
    ) internal {
        trigger.setAmounts(minAmount, maxAmount);
        trigger.setDelay(delay);
        trigger.setForwarder(forwarder);
        trigger.setFeeOtoD(feeOtoD);
        trigger.setFeeDtoO(feeDtoO);
        weth.mint(oraclePool, poolBalance);
        vm.deal(address(trigger), 100 ether); // ample native float to front any fee
        vm.warp(block.timestamp + delay);
    }
}
