// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CREReceiver} from "src/cre/CREReceiver.sol";
import {IReceiver} from "src/cre/interfaces/IReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Harness to expose internal functions for testing
contract CREReceiverHarness is CREReceiver {
    constructor(
        address forwarder_,
        address expectedAuthor_,
        address allowedTarget,
        bytes4 allowedSelector
    ) CREReceiver(forwarder_, expectedAuthor_, allowedTarget, allowedSelector) {}

    function extractWorkflowOwner(bytes calldata metadata) external pure returns (address) {
        return _extractWorkflowOwner(metadata);
    }
}

contract MockTarget {
    event Called(uint256 value);
    error Boom();

    uint256 public lastValue;
    bool public shouldRevert;

    function doSomething(uint256 v) external {
        if (shouldRevert) revert Boom();
        lastValue = v;
        emit Called(v);
    }

    /// @dev Nullary mutating call — mirrors the production-seeded SyncTrigger.triggerSync().
    function ping() external {
        if (shouldRevert) revert Boom();
        lastValue += 1;
        emit Called(lastValue);
    }

    function somethingElse() external pure returns (uint256) {
        return 42;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }
}

/// @notice Malicious target that tries to re-enter CREReceiver.onReport during execution.
contract ReentrantTarget {
    address private _receiver;
    address private _expectedAuthor;

    constructor(address receiver_, address expectedAuthor_) {
        _receiver = receiver_;
        _expectedAuthor = expectedAuthor_;
    }

    function attack() external {
        bytes memory metadata = abi.encodePacked(bytes32(0), bytes10(0), _expectedAuthor);
        bytes memory report = abi.encode(address(this), abi.encodeWithSignature("noop()"));
        IReceiver(_receiver).onReport(metadata, report);
    }

    function noop() external {}
}

contract CREReceiverTest is Test {
    event CallExecuted(address indexed target, bytes4 indexed selector, bytes returnData);
    event ForwarderUpdated(address indexed previousForwarder, address indexed newForwarder);
    event ExpectedAuthorUpdated(address indexed previousAuthor, address indexed newAuthor);
    event AllowedCallUpdated(address indexed target, bytes4 indexed selector, bool allowed);
    event ETHWithdrawn(address indexed to, uint256 amount);

    CREReceiver internal receiver;
    MockTarget internal target;

    address internal forwarder = makeAddr("creForwarder");
    address internal expectedAuthor = makeAddr("expectedAuthor");
    address internal owner;
    bytes4 internal constant PING = MockTarget.ping.selector; // nullary — mirrors the production triggerSync() seed
    bytes4 internal constant DO_SOMETHING = MockTarget.doSomething.selector; // parameterized — for the nullary-gate test

    function setUp() public {
        owner = address(this);
        target = new MockTarget();
        receiver = new CREReceiver(forwarder, expectedAuthor, address(target), PING);
    }

    // ─── Construction ──────────────────────────────────────────────────

    function test_constructor_setsState() public {
        assertEq(receiver.getForwarder(), forwarder);
        assertEq(receiver.owner(), owner);
        assertEq(receiver.getExpectedAuthor(), expectedAuthor);
        assertTrue(receiver.isCallAllowed(address(target), PING));
    }

    function test_constructor_revertsOnZeroForwarder() public {
        vm.expectRevert(CREReceiver.InvalidForwarderAddress.selector);
        new CREReceiver(address(0), expectedAuthor, address(target), PING);
    }

    function test_constructor_revertsOnZeroExpectedAuthor() public {
        vm.expectRevert(CREReceiver.InvalidExpectedAuthor.selector);
        new CREReceiver(forwarder, address(0), address(target), PING);
    }

    function test_constructor_skipsSeedWhenAllowedTargetZero() public {
        CREReceiver r = new CREReceiver(forwarder, expectedAuthor, address(0), bytes4(0));
        assertFalse(r.isCallAllowed(address(target), PING));
    }

    function test_constructor_emitsAllowedCallEvent() public {
        vm.expectEmit(true, true, false, true);
        emit AllowedCallUpdated(address(target), PING, true);
        new CREReceiver(forwarder, expectedAuthor, address(target), PING);
    }

    function test_constructor_emitsForwarderAndAuthorEvents() public {
        vm.expectEmit(true, true, false, false);
        emit ForwarderUpdated(address(0), forwarder);
        vm.expectEmit(true, true, false, false);
        emit ExpectedAuthorUpdated(address(0), expectedAuthor);
        new CREReceiver(forwarder, expectedAuthor, address(target), PING);
    }

    function test_constructor_revertsOnCodelessAllowedTarget() public {
        // the constructor seed routes through _setAllowedCall, which rejects a code-less target: a bare
        // `.call` to an address with no code returns success=true with empty returndata, so allow-listing
        // one would make onReport a silent no-op (report marked delivered, CallExecuted emitted, sync
        // never fires). makeAddr returns an EOA-style address with no code.
        address noCode = makeAddr("noCodeTarget");
        vm.expectRevert(abi.encodeWithSelector(CREReceiver.TargetHasNoCode.selector, noCode));
        new CREReceiver(forwarder, expectedAuthor, noCode, PING);
    }

    // ─── onReport: access control ──────────────────────────────────────

    function test_onReport_revertsIfNotForwarder() public {
        bytes memory report = abi.encode(address(target), abi.encodeCall(MockTarget.doSomething, (42)));
        bytes memory metadata = _metadata(expectedAuthor);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(
            abi.encodeWithSelector(CREReceiver.UnauthorizedForwarder.selector, makeAddr("attacker"), forwarder)
        );
        receiver.onReport(metadata, report);
    }

    // ─── onReport: successful execution ────────────────────────────────

    function test_onReport_executesTargetCall() public {
        bytes memory data = abi.encodeCall(MockTarget.ping, ());
        bytes memory report = abi.encode(address(target), data);

        vm.prank(forwarder);
        receiver.onReport(_metadata(expectedAuthor), report);

        assertEq(target.lastValue(), 1);
    }

    function test_onReport_emitsCallExecuted() public {
        bytes memory data = abi.encodeCall(MockTarget.ping, ());
        bytes memory report = abi.encode(address(target), data);

        vm.prank(forwarder);
        vm.expectEmit(true, true, false, false);
        emit CallExecuted(address(target), PING, "");
        receiver.onReport(_metadata(expectedAuthor), report);
    }

    // ─── onReport: author validation ───────────────────────────────────

    function test_onReport_revertsOnWrongAuthor() public {
        address wrong = makeAddr("wrongAuthor");
        bytes memory report = abi.encode(address(target), abi.encodeCall(MockTarget.doSomething, (1)));

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CREReceiver.InvalidAuthor.selector, wrong, expectedAuthor));
        receiver.onReport(_metadata(wrong), report);
    }

    function test_onReport_revertsOnShortMetadata() public {
        // metadata shorter than the 62-byte Keystone layout (workflowId 32 + name 10 +
        // owner 20) is rejected with a named error rather than an implicit calldata-bounds panic.
        bytes memory report = abi.encode(address(target), abi.encodeCall(MockTarget.ping, ()));
        bytes memory shortMetadata = abi.encodePacked(bytes32("wfId"), bytes10("wfName")); // 42 bytes, no owner

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CREReceiver.MetadataTooShort.selector, uint256(42)));
        receiver.onReport(shortMetadata, report);
    }

    // ─── onReport: allow-list enforcement ──────────────────────────────

    function test_onReport_revertsOnDisallowedTarget() public {
        MockTarget other = new MockTarget();
        bytes memory data = abi.encodeCall(MockTarget.ping, ());
        bytes memory report = abi.encode(address(other), data);

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(CREReceiver.CallNotAllowed.selector, address(other), PING)
        );
        receiver.onReport(_metadata(expectedAuthor), report);
    }

    function test_onReport_revertsOnDisallowedSelector() public {
        bytes memory data = abi.encodeCall(MockTarget.somethingElse, ());
        bytes memory report = abi.encode(address(target), data);

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CREReceiver.CallNotAllowed.selector, address(target), MockTarget.somethingElse.selector
            )
        );
        receiver.onReport(_metadata(expectedAuthor), report);
    }

    function test_onReport_succeedsAfterNewEntryAllowed() public {
        receiver.setAllowedCall(address(target), MockTarget.somethingElse.selector, true);

        bytes memory data = abi.encodeCall(MockTarget.somethingElse, ());
        bytes memory report = abi.encode(address(target), data);

        vm.prank(forwarder);
        receiver.onReport(_metadata(expectedAuthor), report);
    }

    // ─── onReport: error cases ─────────────────────────────────────────

    function test_onReport_revertsOnZeroTarget() public {
        bytes memory report = abi.encode(address(0), abi.encodeCall(MockTarget.doSomething, (1)));

        vm.prank(forwarder);
        vm.expectRevert(CREReceiver.InvalidTargetAddress.selector);
        receiver.onReport(_metadata(expectedAuthor), report);
    }

    function test_onReport_revertsOnShortCallData() public {
        // sub-4-byte calldata is rejected by the single "must be exactly 4 bytes" invariant
        // (NonNullaryCall), which subsumes the former separate ReportTooShort guard.
        bytes memory report = abi.encode(address(target), hex"ab");

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CREReceiver.NonNullaryCall.selector, address(target), uint256(1)));
        receiver.onReport(_metadata(expectedAuthor), report);
    }

    function test_onReport_revertsWhenTargetReverts() public {
        target.setShouldRevert(true);
        bytes memory data = abi.encodeCall(MockTarget.ping, ());
        bytes memory report = abi.encode(address(target), data);

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CREReceiver.CallExecutionFailed.selector,
                address(target),
                abi.encodeWithSelector(MockTarget.Boom.selector)
            )
        );
        receiver.onReport(_metadata(expectedAuthor), report);
    }

    function test_onReport_revertsOnNonNullaryCall() public {
        // even an explicitly allow-listed selector is rejected when the report carries
        // arguments — only a bare 4-byte selector (a nullary call) may be dispatched.
        receiver.setAllowedCall(address(target), DO_SOMETHING, true);
        bytes memory data = abi.encodeCall(MockTarget.doSomething, (123)); // 4 selector + 32 arg = 36 bytes
        bytes memory report = abi.encode(address(target), data);

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(CREReceiver.NonNullaryCall.selector, address(target), uint256(36)));
        receiver.onReport(_metadata(expectedAuthor), report);

        // sanity: the parameterized call never reached the target
        assertEq(target.lastValue(), 0);
    }

    // ─── Metadata parsing ──────────────────────────────────────────────

    function test_extractWorkflowOwner_revertsOnShortMetadata() public {
        CREReceiverHarness harness =
            new CREReceiverHarness(forwarder, expectedAuthor, address(target), DO_SOMETHING);
        bytes memory shortMetadata = new bytes(10);

        // expect the NAMED error: a bare expectRevert would also pass on the implicit
        // calldata-bounds panic, i.e. exactly the regression the explicit guard exists to catch.
        vm.expectRevert(abi.encodeWithSelector(CREReceiver.MetadataTooShort.selector, uint256(10)));
        harness.extractWorkflowOwner(shortMetadata);
    }

    function test_extractWorkflowOwner_readsOwnerSlice() public {
        CREReceiverHarness harness =
            new CREReceiverHarness(forwarder, expectedAuthor, address(target), DO_SOMETHING);

        // real Keystone metadata carries trailing fields after the owner (e.g. reportId);
        // pin the [42:62] slice against off-by-one regressions that exact-62-byte metadata
        // cannot detect.
        bytes memory longMetadata =
            abi.encodePacked(bytes32("wfId"), bytes10("wfName"), expectedAuthor, bytes2(0x1234));
        assertEq(harness.extractWorkflowOwner(longMetadata), expectedAuthor);
    }

    function test_onReport_acceptsMetadataWithTrailingBytes() public {
        bytes memory metadata =
            abi.encodePacked(bytes32("wfId"), bytes10("wfName"), expectedAuthor, bytes2(0x1234));
        bytes memory report = abi.encode(address(target), abi.encodeCall(MockTarget.ping, ()));

        vm.prank(forwarder);
        receiver.onReport(metadata, report);
        assertEq(target.lastValue(), 1);
    }

    // ─── Admin: setForwarder ───────────────────────────────────────────

    function test_setForwarder_updatesForwarder() public {
        address newForwarder = makeAddr("newForwarder");
        receiver.setForwarder(newForwarder);
        assertEq(receiver.getForwarder(), newForwarder);
    }

    function test_setForwarder_revertsOnZero() public {
        vm.expectRevert(CREReceiver.InvalidForwarderAddress.selector);
        receiver.setForwarder(address(0));
    }

    function test_setForwarder_revertsIfNotOwner() public {
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        receiver.setForwarder(makeAddr("newForwarder"));
    }

    function test_setForwarder_emitsEvent() public {
        address newForwarder = makeAddr("newForwarder");
        vm.expectEmit(true, true, false, false);
        emit ForwarderUpdated(forwarder, newForwarder);
        receiver.setForwarder(newForwarder);
    }

    // ─── Admin: setExpectedAuthor ──────────────────────────────────────

    function test_setExpectedAuthor_updatesAuthor() public {
        address author = makeAddr("newAuthor");
        receiver.setExpectedAuthor(author);
        assertEq(receiver.getExpectedAuthor(), author);
    }

    function test_setExpectedAuthor_revertsOnZero() public {
        vm.expectRevert(CREReceiver.InvalidExpectedAuthor.selector);
        receiver.setExpectedAuthor(address(0));
    }

    function test_setExpectedAuthor_revertsIfNotOwner() public {
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        receiver.setExpectedAuthor(makeAddr("author"));
    }

    // ─── Admin: setAllowedCall ─────────────────────────────────────────

    function test_setAllowedCall_togglesAllowlist() public {
        bytes4 sel = MockTarget.somethingElse.selector;
        assertFalse(receiver.isCallAllowed(address(target), sel));
        receiver.setAllowedCall(address(target), sel, true);
        assertTrue(receiver.isCallAllowed(address(target), sel));
        receiver.setAllowedCall(address(target), sel, false);
        assertFalse(receiver.isCallAllowed(address(target), sel));
    }

    function test_setAllowedCall_emitsEvent() public {
        bytes4 sel = MockTarget.somethingElse.selector;
        vm.expectEmit(true, true, false, true);
        emit AllowedCallUpdated(address(target), sel, true);
        receiver.setAllowedCall(address(target), sel, true);
    }

    function test_setAllowedCall_revertsOnZeroTarget() public {
        vm.expectRevert(CREReceiver.InvalidTargetAddress.selector);
        receiver.setAllowedCall(address(0), DO_SOMETHING, true);
    }

    function test_setAllowedCall_revertsIfNotOwner() public {
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        receiver.setAllowedCall(address(target), DO_SOMETHING, true);
    }

    function test_setAllowedCall_revertsOnCodelessTarget() public {
        // same guard as the constructor seed (shared _setAllowedCall): ENABLING a call to a code-less
        // target is rejected so the silent no-op dispatch can never be configured.
        address noCode = makeAddr("noCodeTarget");
        vm.expectRevert(abi.encodeWithSelector(CREReceiver.TargetHasNoCode.selector, noCode));
        receiver.setAllowedCall(noCode, DO_SOMETHING, true);
    }

    function test_setAllowedCall_allowsRemovingCodelessTarget() public {
        // removals (allowed=false) are unconstrained — only enabling requires code, so a target that
        // later loses its code can still be de-listed.
        address noCode = makeAddr("noCodeTarget");
        receiver.setAllowedCall(noCode, DO_SOMETHING, false); // must NOT revert
        assertFalse(receiver.isCallAllowed(noCode, DO_SOMETHING));
    }

    // ─── ERC165 ────────────────────────────────────────────────────────

    function test_supportsInterface_IReceiver() public {
        // The CRE Keystone forwarder gates delivery on these two ids (ERC165Checker probes the
        // ERC-165 base id first, then the onReport-only IReceiver id). BOTH must return true or
        // reports are never delivered.
        assertTrue(receiver.supportsInterface(bytes4(0x805f2132)), "keystone IReceiver (onReport) id");
        assertTrue(receiver.supportsInterface(bytes4(0x01ffc9a7)), "ERC-165 base id");
        // The local IReceiver is onReport-only, so its id IS the keystone id.
        assertTrue(type(IReceiver).interfaceId == bytes4(0x805f2132), "IReceiver must be onReport-only");
        assertTrue(receiver.supportsInterface(type(IReceiver).interfaceId));
    }

    function test_supportsInterface_unknownReturnsFalse() public {
        // 0x21a4cdb3 was the buggy 3-function IReceiver id — it must NOT be advertised any more.
        assertFalse(receiver.supportsInterface(bytes4(0x21a4cdb3)), "old 3-fn id must not be claimed");
        assertFalse(receiver.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ─── ETH handling ──────────────────────────────────────────────────

    function test_canReceiveEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(receiver).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(receiver).balance, 1 ether);
    }

    function test_withdrawETH_succeeds() public {
        vm.deal(address(receiver), 2 ether);
        address payable recipient = payable(makeAddr("recipient"));
        receiver.withdrawETH(recipient, 1 ether);
        assertEq(recipient.balance, 1 ether);
        assertEq(address(receiver).balance, 1 ether);
    }

    function test_withdrawETH_emitsEvent() public {
        vm.deal(address(receiver), 2 ether);
        address payable recipient = payable(makeAddr("recipient"));
        vm.expectEmit(true, false, false, true);
        emit ETHWithdrawn(recipient, 1 ether);
        receiver.withdrawETH(recipient, 1 ether);
    }

    function test_withdrawETH_revertsIfNotOwner() public {
        vm.deal(address(receiver), 1 ether);
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        receiver.withdrawETH(payable(makeAddr("recipient")), 1 ether);
    }

    function test_withdrawETH_revertsOnZeroRecipient() public {
        // a call to address(0) succeeds (no code), so without the guard the ETH would be
        // silently burned instead of reverting.
        vm.deal(address(receiver), 1 ether);
        vm.expectRevert(CREReceiver.InvalidRecipientAddress.selector);
        receiver.withdrawETH(payable(address(0)), 1 ether);
    }

    function test_withdrawETH_revertsOnInsufficientBalance() public {
        vm.expectRevert(CREReceiver.ETHTransferFailed.selector);
        receiver.withdrawETH(payable(makeAddr("recipient")), 1 ether);
    }

    // ─── Reentrancy ────────────────────────────────────────────────────

    /// @dev Reentry from a whitelisted target is blocked by the allow-list (target=self, selector=attack
    ///      not in allow-list) and by the forwarder check (msg.sender = ReentrantTarget, not forwarder).
    function test_onReport_reentrancyBlocked() public {
        ReentrantTarget reentrant = new ReentrantTarget(address(receiver), expectedAuthor);
        bytes4 attackSel = ReentrantTarget.attack.selector;

        receiver.setAllowedCall(address(reentrant), attackSel, true);

        bytes memory report = abi.encode(address(reentrant), abi.encodeCall(ReentrantTarget.attack, ()));

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CREReceiver.CallExecutionFailed.selector,
                address(reentrant),
                abi.encodeWithSelector(CREReceiver.UnauthorizedForwarder.selector, address(reentrant), forwarder)
            )
        );
        receiver.onReport(_metadata(expectedAuthor), report);
    }

    // ─── Helpers ───────────────────────────────────────────────────────

    function _metadata(address workflowOwner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32("wfId"), bytes10("wfName"), workflowOwner);
    }
}
