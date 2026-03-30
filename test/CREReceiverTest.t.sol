// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CREReceiver} from "src/cre/CREReceiver.sol";
import {IReceiver} from "src/cre/interfaces/IReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Harness to expose internal functions for testing
contract CREReceiverHarness is CREReceiver {
    constructor(address forwarder_) CREReceiver(forwarder_) {}

    function extractWorkflowOwner(bytes calldata metadata) external pure returns (address) {
        return _extractWorkflowOwner(metadata);
    }
}

/// @notice Dummy target that records calls for assertion
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

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }
}

/**
 * @title CREReceiverTest
 * @notice Unit tests for the CREReceiver contract covering:
 *   - Construction & initial state
 *   - onReport access control (forwarder check)
 *   - Report decoding & target call execution
 *   - Expected author validation
 *   - Admin functions (setForwarder, setExpectedAuthor)
 *   - Edge cases (zero target, failing target, ERC165)
 */
contract CREReceiverTest is Test {
    event CallExecuted(address indexed target, bytes returnData);
    event ForwarderUpdated(address indexed previousForwarder, address indexed newForwarder);
    event ExpectedAuthorUpdated(address indexed previousAuthor, address indexed newAuthor);

    CREReceiver internal receiver;
    MockTarget internal target;

    address internal forwarder = makeAddr("creForwarder");
    address internal owner;

    function setUp() public {
        owner = address(this);
        receiver = new CREReceiver(forwarder);
        target = new MockTarget();
    }

    // ─── Construction ──────────────────────────────────────────────────

    function test_constructor_setsForwarderAndOwner() public {
        assertEq(receiver.getForwarder(), forwarder);
        assertEq(receiver.owner(), owner);
        assertEq(receiver.getExpectedAuthor(), address(0));
    }

    function test_constructor_revertsOnZeroForwarder() public {
        vm.expectRevert(CREReceiver.InvalidForwarderAddress.selector);
        new CREReceiver(address(0));
    }

    // ─── onReport: access control ──────────────────────────────────────

    function test_onReport_revertsIfNotForwarder() public {
        bytes memory report = abi.encode(address(target), abi.encodeCall(MockTarget.doSomething, (42)));
        bytes memory metadata = _buildMetadata(bytes32(0), bytes10(0), address(0));

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(
            abi.encodeWithSelector(CREReceiver.UnauthorizedForwarder.selector, makeAddr("attacker"), forwarder)
        );
        receiver.onReport(metadata, report);
    }

    // ─── onReport: successful execution ────────────────────────────────

    function test_onReport_executesTargetCall() public {
        bytes memory data = abi.encodeCall(MockTarget.doSomething, (123));
        bytes memory report = abi.encode(address(target), data);
        bytes memory metadata = _buildMetadata(bytes32(0), bytes10(0), address(0));

        vm.prank(forwarder);
        receiver.onReport(metadata, report);

        assertEq(target.lastValue(), 123);
    }

    function test_onReport_emitsCallExecuted() public {
        bytes memory data = abi.encodeCall(MockTarget.doSomething, (456));
        bytes memory report = abi.encode(address(target), data);
        bytes memory metadata = _buildMetadata(bytes32(0), bytes10(0), address(0));

        vm.prank(forwarder);
        vm.expectEmit(true, false, false, false);
        emit CallExecuted(address(target), "");
        receiver.onReport(metadata, report);
    }

    // ─── onReport: error cases ─────────────────────────────────────────

    function test_onReport_revertsOnZeroTarget() public {
        bytes memory report = abi.encode(address(0), abi.encodeCall(MockTarget.doSomething, (1)));
        bytes memory metadata = _buildMetadata(bytes32(0), bytes10(0), address(0));

        vm.prank(forwarder);
        vm.expectRevert(CREReceiver.InvalidTargetAddress.selector);
        receiver.onReport(metadata, report);
    }

    function test_onReport_revertsWhenTargetReverts() public {
        target.setShouldRevert(true);

        bytes memory data = abi.encodeCall(MockTarget.doSomething, (1));
        bytes memory report = abi.encode(address(target), data);
        bytes memory metadata = _buildMetadata(bytes32(0), bytes10(0), address(0));

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CREReceiver.CallExecutionFailed.selector, address(target), abi.encodeWithSelector(MockTarget.Boom.selector)
            )
        );
        receiver.onReport(metadata, report);
    }

    // ─── Expected author validation ────────────────────────────────────

    function test_onReport_allowsAnyAuthorWhenNotSet() public {
        bytes memory data = abi.encodeCall(MockTarget.doSomething, (1));
        bytes memory report = abi.encode(address(target), data);
        address randomAuthor = makeAddr("randomAuthor");
        bytes memory metadata = _buildMetadata(bytes32("wfId"), bytes10("wfName"), randomAuthor);

        vm.prank(forwarder);
        receiver.onReport(metadata, report); // should not revert
        assertEq(target.lastValue(), 1);
    }

    function test_onReport_revertsOnWrongAuthor() public {
        address expectedAuthor = makeAddr("expectedAuthor");
        receiver.setExpectedAuthor(expectedAuthor);

        address wrongAuthor = makeAddr("wrongAuthor");
        bytes memory data = abi.encodeCall(MockTarget.doSomething, (1));
        bytes memory report = abi.encode(address(target), data);
        bytes memory metadata = _buildMetadata(bytes32("wfId"), bytes10("wfName"), wrongAuthor);

        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(CREReceiver.InvalidAuthor.selector, wrongAuthor, expectedAuthor)
        );
        receiver.onReport(metadata, report);
    }

    function test_onReport_allowsCorrectAuthor() public {
        address expectedAuthor = makeAddr("expectedAuthor");
        receiver.setExpectedAuthor(expectedAuthor);

        bytes memory data = abi.encodeCall(MockTarget.doSomething, (99));
        bytes memory report = abi.encode(address(target), data);
        bytes memory metadata = _buildMetadata(bytes32("wfId"), bytes10("wfName"), expectedAuthor);

        vm.prank(forwarder);
        receiver.onReport(metadata, report);
        assertEq(target.lastValue(), 99);
    }

    // ─── Short metadata ─────────────────────────────────────────────────

    function test_extractWorkflowOwner_revertsOnShortMetadata() public {
        CREReceiverHarness harness = new CREReceiverHarness(forwarder);
        // Metadata too short — only 10 bytes instead of required 62
        bytes memory shortMetadata = new bytes(10);

        // Should revert with out-of-bounds, not silently return garbage
        vm.expectRevert();
        harness.extractWorkflowOwner(shortMetadata);
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
        address author = makeAddr("author");
        receiver.setExpectedAuthor(author);
        assertEq(receiver.getExpectedAuthor(), author);
    }

    function test_setExpectedAuthor_revertsIfNotOwner() public {
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        receiver.setExpectedAuthor(makeAddr("author"));
    }

    function test_setExpectedAuthor_canDisableCheck() public {
        receiver.setExpectedAuthor(makeAddr("author"));
        receiver.setExpectedAuthor(address(0));
        assertEq(receiver.getExpectedAuthor(), address(0));
    }

    // ─── ERC165 ────────────────────────────────────────────────────────

    function test_supportsInterface_IReceiver() public {
        assertTrue(receiver.supportsInterface(type(IReceiver).interfaceId));
    }

    function test_supportsInterface_unknownReturnsFalse() public {
        assertFalse(receiver.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ─── Receive ETH ───────────────────────────────────────────────────

    function test_canReceiveEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(receiver).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(receiver).balance, 1 ether);
    }

    // ─── withdrawETH ────────────────────────────────────────────────────

    function test_withdrawETH_succeeds() public {
        vm.deal(address(receiver), 2 ether);
        address payable recipient = payable(makeAddr("recipient"));

        receiver.withdrawETH(recipient, 1 ether);

        assertEq(recipient.balance, 1 ether);
        assertEq(address(receiver).balance, 1 ether);
    }

    function test_withdrawETH_revertsIfNotOwner() public {
        vm.deal(address(receiver), 1 ether);
        vm.prank(makeAddr("nonOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("nonOwner")));
        receiver.withdrawETH(payable(makeAddr("recipient")), 1 ether);
    }

    function test_withdrawETH_revertsOnInsufficientBalance() public {
        vm.expectRevert(CREReceiver.ETHTransferFailed.selector);
        receiver.withdrawETH(payable(makeAddr("recipient")), 1 ether);
    }

    // ─── Helpers ───────────────────────────────────────────────────────

    /// @dev Builds metadata in CRE format: abi.encodePacked(bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    function _buildMetadata(bytes32 workflowId, bytes10 workflowName, address workflowOwner)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(workflowId, workflowName, workflowOwner);
    }
}
