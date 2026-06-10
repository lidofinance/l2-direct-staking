// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {Internal} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Internal.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from
    "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICCIPRouterFork {
    function getOnRamp(uint64 destChainSelector) external view returns (address);
}

interface ITypeAndVersion {
    function typeAndVersion() external view returns (string memory);
}

/**
 * @title CCIPv16ForkRouter
 * @notice Routes a CCIP message across forks, picking the right code path for the OnRamp version.
 * @dev The four L2 lanes split by their ETH-destination OnRamp version — verified on-chain via
 *      `typeAndVersion` (2026-06-01): **Base + Arbitrum are v1.6** (`OnRamp 1.6.0`, emit
 *      `CCIPMessageSent`); **Optimism + Linea are v1.5** (`EVM2EVMOnRamp 1.5.0`, emit
 *      `CCIPSendRequested`). `_isV16OnRamp` detects this at runtime per lane, so the split is not
 *      hard-coded. (A prior version of this note wrongly listed Optimism as v1.6.)
 *
 *      Both paths bypass the OffRamp machinery and inject the message directly into the receiver's
 *      `ccipReceive` with a `gasleft()` sandwich, enabling isolated gas measurement for all lanes:
 *
 *      v1.5 path (Optimism, Linea): decodes the `CCIPSendRequested` event; recovers the destination
 *      token address from `EVM2EVMMessage.sourceTokenData[i]` (abi-encoded `SourceTokenData`); pre-funds
 *      the receiver via `deal()` and calls `ccipReceive` directly.
 *
 *      v1.6 path (Base, Arbitrum): decodes the `CCIPMessageSent` event; recovers the destination token
 *      address from `tokenAmounts[i].destTokenAddress`; same pre-fund and direct-inject pattern.
 *
 *      Both paths bypass the OffRamp's token-pool machinery on purpose — reproducing it faithfully
 *      isn't useful for tests that only care that the receiver dispatches to the right adapter.
 *      Gas accuracy: the only slots warmed by pool delivery before `ccipReceive` in production
 *      (WETH.balanceOf[receiver]) are warmed identically here by `deal()` or are cold in both paths.
 *      The ~1900-gas SLOAD warmth difference (if `deal()` doesn't warm via EVM semantics) is 0.3% of
 *      the ~600k Base budget and constitutes a safe over-estimate for the adequacy check.
 */
abstract contract CCIPv16ForkRouter is Test {
    bytes32 internal constant CCIP_MESSAGE_SENT_TOPIC =
        keccak256("CCIPMessageSent(uint64,uint64,((bytes32,uint64,uint64,uint64,uint64),address,bytes,bytes,bytes,address,uint256,uint256,(address,bytes,bytes,uint256,bytes)[]))");

    // EVM2EVMMessage tuple: (uint64,address,address,uint64,uint256,bool,uint64,address,uint256,bytes,(address,uint256)[],bytes[],bytes32)
    bytes32 internal constant CCIP_SEND_REQUESTED_TOPIC =
        keccak256("CCIPSendRequested((uint64,address,address,uint64,uint256,bool,uint64,address,uint256,bytes,(address,uint256)[],bytes[],bytes32))");

    error CCIPv16MessageNotFound();
    error CCIPv15MessageNotFound();

    /// @notice Gas consumed by the most recent L1 `ccipReceive` call — i.e. the work that
    ///         `FeeOtoD.gasLimit` budgets (`LidoCustomReceiver.ccipReceive` → Lido stake → wstETH wrap
    ///         → bridge adapter). Set by both the v1.5 and v1.6 direct-inject paths after routing;
    ///         `0` only if routing was not called or the message was not found. This is the in-repo,
    ///         regenerating carrier for the `gasLimit`-adequacy claim (A.10 `validatedBy`), recorded so
    ///         the value need not be justified against its prior config. NOTE: it reflects whatever
    ///         adapter is configured at route time — when the consuming test mocks the L1 adapter, the
    ///         figure is a LOWER BOUND (it omits the real per-network bridge endpoint).
    uint256 internal lastCcipReceiveGasUsed;

    function _routeCCIPMessage(
        uint256 srcFork,
        uint256 dstFork,
        address srcRouter,
        uint64 dstChainSelector,
        address dstReceiver,
        address dstCcipRouter
    ) internal {
        lastCcipReceiveGasUsed = 0; // reset; set to non-zero by both inject paths on success
        uint256 entryFork = vm.activeFork();
        vm.selectFork(srcFork);
        address onRamp = ICCIPRouterFork(srcRouter).getOnRamp(dstChainSelector);
        bool isV16 = _isV16OnRamp(onRamp);
        vm.selectFork(entryFork);

        if (!isV16) {
            _injectV15Message(dstFork, dstReceiver, dstCcipRouter);
            return;
        }

        _injectV16Message(dstFork, dstReceiver, dstCcipRouter);
    }

    function _isV16OnRamp(address onRamp) private view returns (bool) {
        string memory version = ITypeAndVersion(onRamp).typeAndVersion();
        bytes memory bytesVersion = bytes(version);
        if (bytesVersion.length < 3) return false;
        // typeAndVersion is like "OnRamp 1.6.0" / "EVM2EVMOnRamp 1.5.0"; the minor digit is 3rd from end.
        return bytesVersion[bytesVersion.length - 3] >= 0x36;
    }

    function _injectV15Message(uint256 dstFork, address dstReceiver, address dstCcipRouter) private {
        Internal.EVM2EVMMessage memory message = _findV15Message();

        vm.selectFork(dstFork);

        Client.EVMTokenAmount[] memory destTokenAmounts =
            new Client.EVMTokenAmount[](message.tokenAmounts.length);
        for (uint256 i; i < message.tokenAmounts.length; ++i) {
            // destTokenAddress is inside the abi-encoded SourceTokenData the OnRamp stores per token.
            Internal.SourceTokenData memory std =
                abi.decode(message.sourceTokenData[i], (Internal.SourceTokenData));
            address destToken = _decodeEVMAddress(std.destTokenAddress);
            uint256 amount = message.tokenAmounts[i].amount;
            destTokenAmounts[i] = Client.EVMTokenAmount({token: destToken, amount: amount});
            deal(destToken, dstReceiver, IERC20(destToken).balanceOf(dstReceiver) + amount);
        }

        _deliverAndMeasureGas(dstCcipRouter, dstReceiver, Client.Any2EVMMessage({
            messageId: message.messageId,
            sourceChainSelector: message.sourceChainSelector,
            sender: abi.encode(message.sender),
            data: message.data,
            destTokenAmounts: destTokenAmounts
        }));
    }

    function _injectV16Message(uint256 dstFork, address dstReceiver, address dstCcipRouter) private {
        Internal.EVM2AnyRampMessage memory message = _findV16Message();

        vm.selectFork(dstFork);

        Client.EVMTokenAmount[] memory destTokenAmounts =
            new Client.EVMTokenAmount[](message.tokenAmounts.length);
        for (uint256 i; i < message.tokenAmounts.length; ++i) {
            address destToken = _decodeEVMAddress(message.tokenAmounts[i].destTokenAddress);
            uint256 amount = message.tokenAmounts[i].amount;
            destTokenAmounts[i] = Client.EVMTokenAmount({token: destToken, amount: amount});
            // Mimic what the OffRamp's token pool would do: hand the destination tokens to the receiver
            // before invoking `ccipReceive`. The receiver expects tokens to be present when it runs.
            deal(destToken, dstReceiver, IERC20(destToken).balanceOf(dstReceiver) + amount);
        }

        _deliverAndMeasureGas(dstCcipRouter, dstReceiver, Client.Any2EVMMessage({
            messageId: message.header.messageId,
            sourceChainSelector: message.header.sourceChainSelector,
            sender: abi.encode(message.sender),
            data: message.data,
            destTokenAmounts: destTokenAmounts
        }));
    }

    function _deliverAndMeasureGas(
        address dstCcipRouter,
        address dstReceiver,
        Client.Any2EVMMessage memory any2EVMMessage
    ) private {
        vm.prank(dstCcipRouter);
        // Measure the receiver-side gas that FeeOtoD.gasLimit must cover. The call is uncapped
        // (full gas forwarded), recording actual consumption. The ~2.6k CALL overhead in the
        // delta is negligible against the ~10^5–10^6 callee cost.
        uint256 gasBefore = gasleft();
        IAny2EVMMessageReceiver(dstReceiver).ccipReceive(any2EVMMessage);
        lastCcipReceiveGasUsed = gasBefore - gasleft();
    }

    /// @dev OnRamps encode EVM destTokenAddress as `abi.encode(address)` (32 bytes, address in the
    ///      rightmost 20). The local-simulator copy in chainlink-local treats it as the leftmost
    ///      20 bytes, which only works when the OnRamp encodes naïvely as packed 20 bytes — not
    ///      the case for the mainnet v1.6 OnRamps we hit. Decode by reading the trailing 20 bytes.
    function _decodeEVMAddress(bytes memory raw) private pure returns (address) {
        if (raw.length == 20) return address(bytes20(raw));
        if (raw.length == 32) return address(uint160(uint256(bytes32(raw))));
        revert("CCIPv16ForkRouter: unexpected destTokenAddress length");
    }

    function _findV16Message() private returns (Internal.EVM2AnyRampMessage memory message) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length == 0) continue;
            if (entries[i].topics[0] != CCIP_MESSAGE_SENT_TOPIC) continue;
            message = abi.decode(entries[i].data, (Internal.EVM2AnyRampMessage));
            return message;
        }
        revert CCIPv16MessageNotFound();
    }

    function _findV15Message() private returns (Internal.EVM2EVMMessage memory message) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length == 0) continue;
            if (entries[i].topics[0] != CCIP_SEND_REQUESTED_TOPIC) continue;
            message = abi.decode(entries[i].data, (Internal.EVM2EVMMessage));
            return message;
        }
        revert CCIPv15MessageNotFound();
    }
}
