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
    uint64 public lastDestChainSelector;
    uint256 public lastSyncAmount;
    uint256 public lastSyncValue;
    bytes32 public lastFeeOtoDHash;
    bytes32 public lastFeeDtoOHash;

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

    function sync(uint64 destChainSelector, uint256 amount, bytes calldata feeOtoD, bytes calldata feeDtoO)
        external
        payable
        returns (bytes32)
    {
        if (shouldRevertSync) revert("sync failed");
        lastDestChainSelector = destChainSelector;
        lastSyncAmount = amount;
        lastSyncValue = msg.value;
        lastFeeOtoDHash = keccak256(feeOtoD);
        lastFeeDtoOHash = keccak256(feeDtoO);
        return keccak256(abi.encode(amount));
    }

    function MIN_PROCESS_MESSAGE_GAS() external pure returns (uint32) {
        return 75_000; // mirrors CustomSender.MIN_PROCESS_MESSAGE_GAS
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

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
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
    event FeeOtoDSet(bytes fee);
    event FeeDtoOSet(bytes fee);

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
        // the max LINK approval is load-bearing: LINK-paid CCIP fees fail without it.
        assertEq(link.allowance(address(trigger), address(sender)), type(uint256).max, "LINK max approval");
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

    function test_setForwarder_revertsOnZero() public {
        // setting the forwarder to address(0) would brick triggerSync (onlyForwarder
        // compares against address(0)); the guard rejects it, aligning with CREReceiver.
        trigger.setForwarder(forwarder);
        vm.expectRevert(ISyncTrigger.SyncTriggerInvalidForwarder.selector);
        trigger.setForwarder(address(0));
        assertEq(trigger.getForwarder(), forwarder);
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

    function test_setDelay_revertsOnZero() public {
        // delay == 0 would permanently defeat the time-based rate limiter (the threshold
        // check is always true); deactivation uses type(uint48).max, never 0.
        vm.expectRevert(ISyncTrigger.SyncTriggerInvalidDelay.selector);
        trigger.setDelay(0);
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
        bytes memory fee = _encodeFee(0.1 ether, false); // 21-byte CCIP blob
        trigger.setFeeOtoD(fee);
        assertEq(keccak256(trigger.getFeeOtoD()), keccak256(fee));
    }

    function test_setFeeDtoO_updatesFee() public {
        bytes memory fee = _encodeFee(0.05 ether, false); // 21 bytes (>= 17)
        trigger.setFeeDtoO(fee);
        assertEq(keccak256(trigger.getFeeDtoO()), keccak256(fee));
    }

    function test_setFeeOtoD_emitsEvent() public {
        bytes memory fee = _encodeFee(0.1 ether, false);
        vm.expectEmit(false, false, false, true);
        emit FeeOtoDSet(fee);
        trigger.setFeeOtoD(fee);
    }

    function test_setFeeDtoO_emitsEvent() public {
        bytes memory fee = _encodeFee(0.05 ether, false);
        vm.expectEmit(false, false, false, true);
        emit FeeDtoOSet(fee);
        trigger.setFeeDtoO(fee);
    }

    function test_setFeeOtoD_revertsOnWrongLength() public {
        // feeOtoD must be exactly 21 bytes (CustomSender re-decodes with FeeCodec.decodeCCIP).
        // A 20-byte buffer previously passed the setter then self-DoSed inside sync.
        bytes memory tooShort = new bytes(20);
        vm.expectRevert(abi.encodeWithSelector(FeeCodec.FeeCodecInvalidDataLength.selector, uint256(20), uint256(21)));
        trigger.setFeeOtoD(tooShort);
    }

    function test_setFeeOtoD_revertsOnGasLimitBelowSenderFloor() public {
        // a decodable 21-byte blob whose gasLimit is below CustomSender.MIN_PROCESS_MESSAGE_GAS
        // would make every sync revert with CustomSenderInsufficientGas while shouldSync stays
        // true; the setter must reject it.
        bytes memory lowGas = FeeCodec.encodeCCIP(0.1 ether, false, 74_999);
        vm.expectRevert(ISyncTrigger.SyncTriggerInvalidParameters.selector);
        trigger.setFeeOtoD(lowGas);
    }

    function test_setFeeDtoO_revertsOnTooShort() public {
        // feeDtoO must be >= 17 bytes (FeeCodec.decodeFee).
        bytes memory tooShort = new bytes(16);
        vm.expectRevert(abi.encodeWithSelector(FeeCodec.FeeCodecInvalidDataLength.selector, uint256(16), uint256(17)));
        trigger.setFeeDtoO(tooShort);
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

    function test_sweep_transfersNative() public {
        address recipient = makeAddr("recipient");
        vm.deal(address(trigger), 3 ether);
        trigger.sweep(address(0), recipient, 3 ether);
        assertEq(recipient.balance, 3 ether);
    }

    function test_sweep_transfersERC20() public {
        address recipient = makeAddr("recipient");
        weth.mint(address(trigger), 5 ether);
        trigger.sweep(address(weth), recipient, 5 ether);
        assertEq(weth.balanceOf(recipient), 5 ether);
        assertEq(weth.balanceOf(address(trigger)), 0);
    }

    function test_sweep_revertsIfNotOwner() public {
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        trigger.sweep(address(0), makeAddr("r"), 1);
    }

    // ─── shouldSync ────────────────────────────────────────────────────

    function test_shouldSync_falseWhenDeactivated() public {
        // default delay is type(uint48).max ("deactivated"). The threshold
        // uint256(lastExecution) + delay is unreachable, so shouldSync cleanly returns
        // (false, 0) instead of overflow-reverting (the off-chain CRE eth_call probe needs
        // a clean "no sync", not a revert).
        trigger.setAmounts(1 ether, 10 ether);
        weth.mint(oraclePool, 5 ether);
        (bool needed, uint256 amount) = trigger.shouldSync();
        assertFalse(needed);
        assertEq(amount, 0);
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
        // pin the pass-through arguments: a swapped fee pair or wrong selector would
        // otherwise survive every unit test (the mock used to discard them).
        assertEq(sender.lastDestChainSelector(), DEST_CHAIN, "dest chain selector forwarded");
        assertEq(sender.lastFeeOtoDHash(), keccak256(_encodeFee(maxFeeOtoD, false)), "feeOtoD forwarded");
        assertEq(sender.lastFeeDtoOHash(), keccak256(_encodeFee(feeDtoO, false)), "feeDtoO forwarded");
    }

    function test_triggerSync_bubblesSenderRevert() public {
        _armTriggerSync(1 ether, 10 ether, 1 hours, 5 ether, _encodeFee(0.1 ether, false), _encodeFee(0.05 ether, false));
        sender.setShouldRevertSync(true);

        vm.prank(forwarder);
        vm.expectRevert(bytes("sync failed"));
        trigger.triggerSync();

        // the revert rolled back the _lastExecution update — the trigger stays armed.
        (bool needed,) = trigger.shouldSync();
        assertTrue(needed, "still armed after failed sync");
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
