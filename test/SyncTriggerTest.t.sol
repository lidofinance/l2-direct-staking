// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SyncTrigger} from "src/SyncTrigger.sol";
import {FeeCodec} from "@csr/libraries/FeeCodec.sol";

/// @notice Minimal mock for ICustomSender — just enough for SyncTrigger constructor + sync
contract MockCustomSender {
    bytes32 public constant SYNC_ROLE = keccak256("SYNC_ROLE");

    address public immutable WNATIVE;
    address public immutable LINK_TOKEN;
    address public oraclePool;

    bool public shouldRevertSync;
    uint64 public lastDestChainSelector;
    uint256 public lastSyncAmount;
    uint256 public lastSyncValue;
    bytes32 public lastFeeOtoDHash;
    bytes32 public lastFeeDtoOHash;

    mapping(address => bool) internal _syncRole;

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

    /// @dev Mirrors AccessControl.hasRole on the real CustomSender, reached via the IAccessControl
    ///      cast in SyncTrigger.canSync.
    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == SYNC_ROLE && _syncRole[account];
    }

    function setSyncRole(address account, bool granted) external {
        _syncRole[account] = granted;
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

/// @notice Has no receive/payable-fallback, so any native transfer to it fails — used to
///         exercise the SyncTriggerNativeTransferFailed path in sweep.
contract RejectEther {}

/// @notice Stand-in for the non-pausable base OraclePool: has code but no `paused()`, so the
///         try/catch in SyncTrigger._isPaused falls through to "not paused".
contract MockPool {}

/// @notice Stand-in for PausableImmutableOraclePool: exposes a toggleable `paused()`.
contract MockPausablePool {
    bool public paused;

    function setPaused(bool v) external {
        paused = v;
    }
}

/**
 * @title SyncTriggerTest
 * @notice Unit tests for SyncTrigger contract covering:
 *   - Construction & initial state
 *   - Admin setters (setForwarder, setDelay, setAmounts, setFeeOtoD, setFeeDtoO, sweep)
 *   - Access control on all admin functions
 *   - shouldSync (due) / canSync (executability) view logic
 *   - triggerSync execution + edge cases
 */
contract SyncTriggerTest is Test {
    event ForwarderSet(address forwarder);
    event DelaySet(uint48 delay);
    event AmountsSet(uint128 minAmount, uint128 maxAmount);
    event FeeOtoDSet(bytes fee);
    event FeeDtoOSet(bytes fee);
    event MaxGasLimitSet(uint32 maxGasLimit);
    event Swept(address indexed token, address indexed recipient, uint256 amount);

    SyncTrigger internal trigger;
    MockCustomSender internal sender;
    MockERC20 internal weth;
    MockERC20 internal link;
    address internal oraclePool;
    address internal forwarder = makeAddr("forwarder");
    address internal owner;
    uint64 internal constant DEST_CHAIN = 1;

    // Default constructor config. Values deliberately differ from the per-setter-test values
    // (1 hours / 1 & 10 ether / 1_000_000) so the setter "updates" tests stay non-tautological.
    uint48 internal constant DEFAULT_DELAY = 12 hours;
    uint128 internal constant DEFAULT_MIN_AMOUNT = 5 ether;
    uint128 internal constant DEFAULT_MAX_AMOUNT = 50 ether;
    uint32 internal constant DEFAULT_MAX_GAS_LIMIT = 7_000_000;

    function setUp() public {
        owner = address(this);
        weth = new MockERC20();
        link = new MockERC20();
        sender = new MockCustomSender(address(weth), address(link));
        oraclePool = address(new MockPool());
        sender.setOraclePool(oraclePool);
        trigger = _deploy(_defaultInitParams());
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

    function test_constructor_storesConfig() public {
        // Born fully configured from InitParams — no deactivated defaults.
        assertEq(trigger.getLastExecution(), uint48(block.timestamp));
        assertEq(trigger.getForwarder(), forwarder);
        assertEq(trigger.getDelay(), DEFAULT_DELAY);
        (uint128 min, uint128 max) = trigger.getAmounts();
        assertEq(min, DEFAULT_MIN_AMOUNT);
        assertEq(max, DEFAULT_MAX_AMOUNT);
        assertEq(keccak256(trigger.getFeeOtoD()), keccak256(_defaultFeeOtoD()));
        assertEq(keccak256(trigger.getFeeDtoO()), keccak256(_defaultFeeDtoO()));
        assertEq(trigger.getMaxGasLimit(), DEFAULT_MAX_GAS_LIMIT);
    }

    function test_constructor_revertsOnZeroSender() public {
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidParameters.selector);
        new SyncTrigger(address(0), DEST_CHAIN, owner, _defaultInitParams());
    }

    function test_constructor_revertsOnZeroChainSelector() public {
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidParameters.selector);
        new SyncTrigger(address(sender), 0, owner, _defaultInitParams());
    }

    function test_constructor_revertsOnMaxGasLimitBelowFloor() public {
        // _setMaxGasLimit runs first; a ceiling below MIN_PROCESS_MESSAGE_GAS reverts.
        SyncTrigger.InitParams memory p = _defaultInitParams();
        p.maxGasLimit = 74_999;
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidParameters.selector);
        _deploy(p);
    }

    function test_constructor_revertsOnFeeOtoDWrongLength() public {
        // exactly 21 bytes required; BOTH under- and over-length must revert (the explicit length
        // guard preserves decodeCCIP's exact-21 semantics through the memory decoder).
        SyncTrigger.InitParams memory p = _defaultInitParams();
        p.feeOtoD = new bytes(20);
        vm.expectRevert(abi.encodeWithSelector(FeeCodec.FeeCodecInvalidDataLength.selector, uint256(20), uint256(21)));
        _deploy(p);

        p.feeOtoD = new bytes(22);
        vm.expectRevert(abi.encodeWithSelector(FeeCodec.FeeCodecInvalidDataLength.selector, uint256(22), uint256(21)));
        _deploy(p);
    }

    function test_constructor_revertsOnFeeOtoDGasBelowFloor() public {
        SyncTrigger.InitParams memory p = _defaultInitParams();
        p.feeOtoD = FeeCodec.encodeCCIP(0.1 ether, false, 74_999);
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidParameters.selector);
        _deploy(p);
    }

    function test_constructor_revertsWhenFeeOtoDGasAboveMaxGasLimit() public {
        // proves the constructor seeds maxGasLimit BEFORE feeOtoD: feeOtoD's gasLimit is validated
        // against the just-set ceiling.
        SyncTrigger.InitParams memory p = _defaultInitParams();
        p.maxGasLimit = 500_000;
        p.feeOtoD = FeeCodec.encodeCCIP(0.1 ether, false, 500_001);
        vm.expectRevert(
            abi.encodeWithSelector(SyncTrigger.SyncTriggerGasLimitAboveMax.selector, uint32(500_001), uint32(500_000))
        );
        _deploy(p);
    }

    function test_constructor_revertsOnFeeDtoOTooShort() public {
        SyncTrigger.InitParams memory p = _defaultInitParams();
        p.feeDtoO = new bytes(16);
        vm.expectRevert(abi.encodeWithSelector(FeeCodec.FeeCodecInvalidDataLength.selector, uint256(16), uint256(17)));
        _deploy(p);
    }

    function test_constructor_revertsOnZeroMinAmount() public {
        SyncTrigger.InitParams memory p = _defaultInitParams();
        p.minAmount = 0;
        vm.expectRevert(
            abi.encodeWithSelector(SyncTrigger.SyncTriggerInvalidAmounts.selector, uint128(0), p.maxAmount)
        );
        _deploy(p);
    }

    function test_constructor_revertsWhenMinGtMax() public {
        SyncTrigger.InitParams memory p = _defaultInitParams();
        p.minAmount = 10 ether;
        p.maxAmount = 1 ether;
        vm.expectRevert(
            abi.encodeWithSelector(SyncTrigger.SyncTriggerInvalidAmounts.selector, uint128(10 ether), uint128(1 ether))
        );
        _deploy(p);
    }

    function test_constructor_revertsOnZeroDelay() public {
        SyncTrigger.InitParams memory p = _defaultInitParams();
        p.delay = 0;
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidDelay.selector);
        _deploy(p);
    }

    function test_constructor_revertsOnZeroForwarder() public {
        SyncTrigger.InitParams memory p = _defaultInitParams();
        p.forwarder = address(0);
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidForwarder.selector);
        _deploy(p);
    }

    function test_constructor_emitsConfigEvents() public {
        // The constructor configures via the same internal setters the owner uses, emitting each
        // canonical *Set event in body order. Ownable's OwnershipTransferred is emitted first by the
        // base constructor, so locate the first config event and assert the six follow contiguously.
        vm.recordLogs();
        _deploy(_defaultInitParams());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32[6] memory expected = [
            keccak256("MaxGasLimitSet(uint32)"),
            keccak256("FeeOtoDSet(bytes)"),
            keccak256("FeeDtoOSet(bytes)"),
            keccak256("AmountsSet(uint128,uint128)"),
            keccak256("DelaySet(uint48)"),
            keccak256("ForwarderSet(address)")
        ];

        uint256 start = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == expected[0]) {
                start = i;
                break;
            }
        }
        assertTrue(start != type(uint256).max, "MaxGasLimitSet emitted");
        assertEq(logs.length - start, expected.length, "six config events are the last logs, in order");
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(logs[start + i].topics[0], expected[i], "config event order");
        }
    }

    // ─── setForwarder ──────────────────────────────────────────────────

    function test_setForwarder_updatesForwarder() public {
        address newForwarder = makeAddr("newForwarder");
        trigger.setForwarder(newForwarder);
        assertEq(trigger.getForwarder(), newForwarder);
    }

    function test_setForwarder_revertsOnZero() public {
        // setting the forwarder to address(0) would brick triggerSync (onlyForwarder
        // compares against address(0)); the guard rejects it, aligning with CREReceiver.
        trigger.setForwarder(forwarder);
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidForwarder.selector);
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
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidDelay.selector);
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
        vm.expectRevert(abi.encodeWithSelector(SyncTrigger.SyncTriggerInvalidAmounts.selector, 0, 10 ether));
        trigger.setAmounts(0, 10 ether);
    }

    function test_setAmounts_revertsWhenMinGtMax() public {
        vm.expectRevert(abi.encodeWithSelector(SyncTrigger.SyncTriggerInvalidAmounts.selector, 10 ether, 1 ether));
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
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidParameters.selector);
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

    function test_sweep_native_emitsEvent() public {
        address recipient = makeAddr("recipient");
        vm.deal(address(trigger), 3 ether);
        vm.expectEmit(true, true, false, true);
        emit Swept(address(0), recipient, 3 ether);
        trigger.sweep(address(0), recipient, 3 ether);
    }

    function test_sweep_erc20_emitsEvent() public {
        address recipient = makeAddr("recipient");
        weth.mint(address(trigger), 5 ether);
        vm.expectEmit(true, true, false, true);
        emit Swept(address(weth), recipient, 5 ether);
        trigger.sweep(address(weth), recipient, 5 ether);
    }

    function test_sweep_native_revertsWhenRecipientRejects() public {
        // inlined native transfer uses a low-level call and reverts on failure (recipient with
        // no receive/fallback), replacing the former TokenHelperNativeTransferFailed.
        RejectEther rejecter = new RejectEther();
        vm.deal(address(trigger), 1 ether);
        vm.expectRevert(SyncTrigger.SyncTriggerNativeTransferFailed.selector);
        trigger.sweep(address(0), address(rejecter), 1 ether);
    }

    function test_sweep_zeroAmountIsNoop() public {
        // a zero amount is a no-op: no balance moves (and no Swept event). Preserves the
        // former TokenHelper.transfer behavior after inlining.
        address recipient = makeAddr("recipient");
        vm.deal(address(trigger), 2 ether);
        trigger.sweep(address(0), recipient, 0);
        assertEq(recipient.balance, 0, "no native moved");
        assertEq(address(trigger).balance, 2 ether, "trigger balance untouched");
    }

    function test_sweep_native_revertsOnZeroRecipient() public {
        // a low-level call to the code-less zero address SUCCEEDS, so without the guard this
        // would silently burn the native float. The guard turns it into a clean revert,
        // mirroring CREReceiver.withdrawETH.
        vm.deal(address(trigger), 1 ether);
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidRecipient.selector);
        trigger.sweep(address(0), address(0), 1 ether);
        assertEq(address(trigger).balance, 1 ether, "native float untouched");
    }

    function test_sweep_erc20_revertsOnZeroRecipient() public {
        // the guard precedes the token branch, so the ERC20 path is rejected too (not all
        // tokens revert on transfer to address(0)).
        weth.mint(address(trigger), 5 ether);
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidRecipient.selector);
        trigger.sweep(address(weth), address(0), 5 ether);
        assertEq(weth.balanceOf(address(trigger)), 5 ether, "token balance untouched");
    }

    function test_sweep_revertsOnZeroRecipientEvenWhenZeroAmount() public {
        // the recipient guard is validation-first: it runs before the amount==0 short-circuit,
        // so address(0) is never a valid recipient regardless of amount.
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidRecipient.selector);
        trigger.sweep(address(0), address(0), 0);
    }

    // ─── shouldSync ────────────────────────────────────────────────────

    function test_shouldSync_falseWhenDeactivated() public {
        // deactivation is an explicit value (type(uint48).max) set post-deploy via setDelay — the
        // constructor no longer defaults to it. The threshold uint256(lastExecution) + delay is then
        // unreachable, so shouldSync cleanly returns false instead of overflow-reverting (the off-chain
        // CRE eth_call probe needs a clean "no sync", not a revert).
        trigger.setDelay(type(uint48).max);
        weth.mint(oraclePool, 10 ether); // above DEFAULT_MIN_AMOUNT, so only the delay holds it back
        assertFalse(trigger.shouldSync());
    }

    function test_shouldSync_falseBeforeDelay() public {
        _configureForSync(1 ether, 10 ether, 1 hours);
        weth.mint(oraclePool, 5 ether);
        // Don't warp — still within delay
        assertFalse(trigger.shouldSync());
    }

    function test_shouldSync_falseWhenBelowMin() public {
        _configureForSync(5 ether, 10 ether, 1 hours);
        weth.mint(oraclePool, 4 ether); // below min
        vm.warp(block.timestamp + 1 hours);
        assertFalse(trigger.shouldSync());
    }

    function test_shouldSync_trueAtExactMin() public {
        // shouldSync is the due-ness predicate: delay elapsed + pool >= min. _armTriggerSync also funds
        // the float + sets fees + grants SYNC_ROLE, so canSync (executability) holds too.
        _armTriggerSync(5 ether, 10 ether, 1 hours, 5 ether, _encodeFee(0.1 ether, false), _encodeFee(0.05 ether, false));
        assertTrue(trigger.shouldSync(), "due at exact min");
        assertTrue(trigger.canSync(), "executable when fully armed");
        assertEq(trigger.getAmountToSync(), 5 ether);
    }

    function test_shouldSync_capsAtMax() public {
        _armTriggerSync(5 ether, 10 ether, 1 hours, 50 ether, _encodeFee(0.1 ether, false), _encodeFee(0.05 ether, false));
        assertTrue(trigger.shouldSync());
        assertEq(trigger.getAmountToSync(), 10 ether);
    }

    // ─── canSync executability (LOW-2: float / SYNC_ROLE / pool pause) ──

    function test_canSync_trueAtExactFloat() public {
        // native fees → maxNativeFee = 0.15 ether; fund the float to exactly that boundary.
        _armDueSync(_encodeFee(0.1 ether, false), _encodeFee(0.05 ether, false));
        vm.deal(address(trigger), 0.15 ether);
        sender.setSyncRole(address(trigger), true);

        assertTrue(trigger.canSync(), "all preconditions met at the float boundary");
        assertTrue(trigger.shouldSync(), "and the sync is due");
    }

    function test_canSync_falseWithoutSyncRole_total() public {
        // Right after construction the trigger holds no SYNC_ROLE on the sender, so canSync returns
        // false WITHOUT reverting — the DON's per-tick eth_call stays total. SYNC_ROLE is the first
        // gate, so this returns before any fee read.
        assertFalse(trigger.canSync());
    }

    function test_canSync_falseWhenNativeFloatBelowMax() public {
        _armDueSync(_encodeFee(0.1 ether, false), _encodeFee(0.05 ether, false));
        vm.deal(address(trigger), 0.15 ether - 1); // one wei short of maxNativeFee
        sender.setSyncRole(address(trigger), true);

        assertFalse(trigger.canSync(), "blocked by native float");
        assertTrue(trigger.shouldSync(), "still due (executability is separate)");
        assertEq(trigger.getAmountToSync(), 5 ether, "the need stands");
    }

    function test_canSync_falseWhenLinkFloatBelowMax() public {
        // both legs in LINK → maxNativeFee = 0, maxLinkFee = 0.15 ether.
        _armDueSync(_encodeFee(0.1 ether, true), _encodeFee(0.05 ether, true));
        vm.deal(address(trigger), 1 ether); // native irrelevant here
        sender.setSyncRole(address(trigger), true);
        link.mint(address(trigger), 0.15 ether - 1); // one wei short of maxLinkFee

        assertFalse(trigger.canSync(), "blocked by LINK float");
        assertTrue(trigger.shouldSync(), "still due");
    }

    function test_canSync_falseWhenSyncRoleMissing() public {
        _armDueSync(_encodeFee(0.1 ether, false), _encodeFee(0.05 ether, false));
        vm.deal(address(trigger), 1 ether);
        // SYNC_ROLE deliberately not granted (revocation is a documented kill switch).

        assertFalse(trigger.canSync(), "blocked by missing SYNC_ROLE");
        assertTrue(trigger.shouldSync(), "still due");
    }

    function test_canSync_falseWhenPoolPaused() public {
        MockPausablePool pausablePool = new MockPausablePool();
        sender.setOraclePool(address(pausablePool));
        _armDueSync(_encodeFee(0.1 ether, false), _encodeFee(0.05 ether, false));
        weth.mint(address(pausablePool), 5 ether); // the need reads from the live pool
        vm.deal(address(trigger), 1 ether);
        sender.setSyncRole(address(trigger), true);

        assertTrue(trigger.canSync(), "executable while unpaused");

        pausablePool.setPaused(true);
        assertFalse(trigger.canSync(), "blocked by pool pause");
        assertTrue(trigger.shouldSync(), "still due");
    }

    // ─── triggerSync ───────────────────────────────────────────────────

    function test_triggerSync_revertsIfNotForwarder() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(SyncTrigger.SyncTriggerOnlyForwarder.selector);
        trigger.triggerSync();
    }

    function test_triggerSync_revertsIfSyncNotNeeded() public {
        _configureForSync(5 ether, 10 ether, 1 hours);
        trigger.setForwarder(forwarder);
        // Pool has no WETH, so amount is 0
        vm.warp(block.timestamp + 1 hours);
        vm.prank(forwarder);
        vm.expectRevert(SyncTrigger.SyncTriggerSyncNotNeeded.selector);
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
        assertTrue(trigger.shouldSync(), "still armed after failed sync");
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
        vm.expectRevert(SyncTrigger.SyncTriggerSyncNotNeeded.selector);
        trigger.triggerSync();
    }

    function test_triggerSync_revertsOnInsufficientFloat() public {
        // native fees → nativeAmount = 0.1 + 0.05 = 0.15 ether; starve the float just below it.
        _armTriggerSync(1 ether, 10 ether, 1 hours, 5 ether, _encodeFee(0.1 ether, false), _encodeFee(0.05 ether, false));
        vm.deal(address(trigger), 0.15 ether - 1);

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                SyncTrigger.SyncTriggerInsufficientFloat.selector, uint256(0.15 ether), uint256(0.15 ether - 1)
            )
        );
        trigger.triggerSync();

        // the revert rolled back _lastExecution — the sync stays DUE (a top-up self-heals it). shouldSync
        // stays true (due-ness ignores the float); canSync is false (the starved float fails its
        // executability check), which is exactly why the DON suppresses the report rather than spam reverts.
        assertGt(trigger.getAmountToSync(), 0, "still due after blocked sync");
        assertTrue(trigger.shouldSync(), "still due while the float is starved");
        assertFalse(trigger.canSync(), "canSync false while the float is starved");
    }

    function test_triggerSync_succeedsAtExactFloat() public {
        // boundary: balance == nativeAmount must pass (strict `<` check).
        _armTriggerSync(1 ether, 10 ether, 1 hours, 5 ether, _encodeFee(0.1 ether, false), _encodeFee(0.05 ether, false));
        vm.deal(address(trigger), 0.15 ether);

        vm.prank(forwarder);
        trigger.triggerSync();
        assertEq(sender.lastSyncValue(), 0.15 ether, "exact float fronted");
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

    // ─── maxGasLimit ───────────────────────────────────────────────────

    function test_constructor_storesMaxGasLimit() public {
        // maxGasLimit is now a required constructor param (no uncapped default).
        assertEq(trigger.getMaxGasLimit(), DEFAULT_MAX_GAS_LIMIT);
    }

    function test_setMaxGasLimit_updates() public {
        trigger.setMaxGasLimit(1_000_000);
        assertEq(trigger.getMaxGasLimit(), 1_000_000);
    }

    function test_setMaxGasLimit_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit MaxGasLimitSet(1_000_000);
        trigger.setMaxGasLimit(1_000_000);
    }

    function test_setMaxGasLimit_revertsBelowSenderFloor() public {
        // a ceiling below MIN_PROCESS_MESSAGE_GAS would make every feeOtoD unsettable.
        vm.expectRevert(SyncTrigger.SyncTriggerInvalidParameters.selector);
        trigger.setMaxGasLimit(74_999);
    }

    function test_setMaxGasLimit_revertsIfNotOwner() public {
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        trigger.setMaxGasLimit(1_000_000);
    }

    function test_setFeeOtoD_revertsWhenGasLimitAboveMax() public {
        // a chain-blind over-bump (gasLimit above the per-lane ceiling) must fail loudly at set-time,
        // not silently inside every sync (MessageGasLimitTooHigh) while shouldSync stays true.
        trigger.setMaxGasLimit(500_000);
        bytes memory overCap = FeeCodec.encodeCCIP(0.1 ether, false, 500_001);
        vm.expectRevert(abi.encodeWithSelector(SyncTrigger.SyncTriggerGasLimitAboveMax.selector, uint32(500_001), uint32(500_000)));
        trigger.setFeeOtoD(overCap);
    }

    function test_setFeeOtoD_allowsGasLimitAtMax() public {
        // boundary: gasLimit == maxGasLimit is accepted (strict `>` check).
        trigger.setMaxGasLimit(500_000);
        bytes memory atCap = FeeCodec.encodeCCIP(0.1 ether, false, 500_000);
        trigger.setFeeOtoD(atCap);
        assertEq(keccak256(trigger.getFeeOtoD()), keccak256(atCap));
    }

    function test_setMaxGasLimit_revertsWhenBelowStoredFeeOtoDGasLimit() public {
        // the feeOtoD.gasLimit <= maxGasLimit invariant must hold in BOTH directions: LOWERING the
        // ceiling below an already-stored feeOtoD gasLimit must fail loudly, not silently re-open the
        // C-1 stall (shouldSync stays true while every sync reverts MessageGasLimitTooHigh in CCIP).
        trigger.setFeeOtoD(FeeCodec.encodeCCIP(0.1 ether, false, 1_000_000)); // stored gasLimit = 1M
        vm.expectRevert(
            abi.encodeWithSelector(SyncTrigger.SyncTriggerGasLimitAboveMax.selector, uint32(1_000_000), uint32(900_000))
        );
        trigger.setMaxGasLimit(900_000);
        assertEq(trigger.getMaxGasLimit(), DEFAULT_MAX_GAS_LIMIT, "ceiling unchanged after revert");
    }

    function test_setMaxGasLimit_allowsLoweringToStoredFeeOtoDGasLimit() public {
        // boundary: a ceiling exactly equal to the stored gasLimit is accepted (strict `>` check).
        trigger.setFeeOtoD(FeeCodec.encodeCCIP(0.1 ether, false, 900_000));
        trigger.setMaxGasLimit(900_000);
        assertEq(trigger.getMaxGasLimit(), 900_000);
    }

    function test_setMaxGasLimit_lowerAboveStoredFeeOtoD_thenRejectsOverCap() public {
        // Lowering the ceiling ABOVE the stored feeOtoD gasLimit (75_000 from construction) succeeds;
        // the bound then re-binds on the next setFeeOtoD, rejecting an over-cap blob.
        trigger.setMaxGasLimit(100_000);
        assertEq(trigger.getMaxGasLimit(), 100_000);
        vm.expectRevert(
            abi.encodeWithSelector(SyncTrigger.SyncTriggerGasLimitAboveMax.selector, uint32(100_001), uint32(100_000))
        );
        trigger.setFeeOtoD(FeeCodec.encodeCCIP(0.1 ether, false, 100_001));
    }

    // ─── getAmountToSync (public wrapper) ──────────────────────────────

    function test_getAmountToSync_returnsAmount() public {
        // getAmountToSync returns the pending need regardless of due-ness/executability. Arm a DUE sync
        // with fees set but leave the float unfunded (canSync false) — getAmountToSync still reports it.
        _armDueSync(_encodeFee(0.1 ether, false), _encodeFee(0.05 ether, false));
        assertFalse(trigger.canSync(), "float unfunded -> not executable");
        assertEq(trigger.getAmountToSync(), 5 ether, "the need is reported regardless");
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

    /// @dev The constructor-seeded feeOtoD. gasLimit is the sender floor (75_000) so the
    ///      maxGasLimit-lowering tests are never blocked by the stored feeOtoD's gasLimit.
    function _defaultFeeOtoD() internal pure returns (bytes memory) {
        return FeeCodec.encodeCCIP(0.1 ether, false, 75_000);
    }

    /// @dev The constructor-seeded feeDtoO (21 bytes; only the first 17 are read by decodeFee).
    function _defaultFeeDtoO() internal pure returns (bytes memory) {
        return FeeCodec.encodeCCIP(0.05 ether, false, 75_000);
    }

    /// @dev A fully-valid InitParams the constructor accepts. Strict construction means every field
    ///      must be valid, so revert tests start from this and override a single field.
    function _defaultInitParams() internal view returns (SyncTrigger.InitParams memory) {
        return SyncTrigger.InitParams({
            forwarder: forwarder,
            delay: DEFAULT_DELAY,
            minAmount: DEFAULT_MIN_AMOUNT,
            maxAmount: DEFAULT_MAX_AMOUNT,
            feeOtoD: _defaultFeeOtoD(),
            feeDtoO: _defaultFeeDtoO(),
            maxGasLimit: DEFAULT_MAX_GAS_LIMIT
        });
    }

    /// @dev Deploys a SyncTrigger with the fixed identity/owner args + the given storage params.
    function _deploy(SyncTrigger.InitParams memory p) internal returns (SyncTrigger) {
        return new SyncTrigger(address(sender), DEST_CHAIN, owner, p);
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
        sender.setSyncRole(address(trigger), true); // a fully-armed trigger holds SYNC_ROLE → canSync executable
        vm.warp(block.timestamp + delay);
    }

    /// @dev Arms the trigger so a sync is DUE (amounts, delay, fees, funded pool, warp past delay),
    ///      but leaves the executability levers (native/LINK float, SYNC_ROLE, pool pause) to the
    ///      individual canSync tests. Uses 1/10 ether min/max and a 5-ether pool → amount == 5 ether.
    function _armDueSync(bytes memory feeOtoD, bytes memory feeDtoO) internal {
        trigger.setAmounts(1 ether, 10 ether);
        trigger.setDelay(1 hours);
        trigger.setFeeOtoD(feeOtoD);
        trigger.setFeeDtoO(feeDtoO);
        weth.mint(oraclePool, 5 ether);
        vm.warp(block.timestamp + 1 hours);
    }
}
