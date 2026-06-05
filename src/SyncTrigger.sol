// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {TokenHelper} from "@csr/libraries/TokenHelper.sol";
import {IOraclePool} from "@csr/interfaces/IOraclePool.sol";
import {ICustomSender} from "@csr/interfaces/ICustomSender.sol";
import {ISyncTrigger} from "src/interfaces/ISyncTrigger.sol";

/**
 * @title SyncTrigger
 * @notice Decides when and how much to trigger `CustomSender.sync()`, which sends accumulated
 *         WETH from the L2 OraclePool to L1 for Lido staking and bridges wstETH back.
 * @dev The sync is triggered every `delay` seconds if the pool's WETH balance exceeds `minAmount`,
 *      capped at `maxAmount` per trigger.
 */
contract SyncTrigger is Ownable, ISyncTrigger {
    using SafeERC20 for IERC20;

    address public immutable SENDER;
    uint64 public immutable DEST_CHAIN_SELECTOR;
    address public immutable WNATIVE;

    address private _forwarder;
    uint48 private _lastExecution;
    uint48 private _delay;

    uint128 private _minAmount;
    uint128 private _maxAmount;

    bytes private _feeOtoD;
    bytes private _feeDtoO;

    modifier onlyForwarder() {
        if (msg.sender != _forwarder) revert SyncTriggerOnlyForwarder();
        _;
    }

    receive() external payable {}

    /**
     * @dev Sets the immutable values for {SENDER}, {DEST_CHAIN_SELECTOR} and the initial owner.
     *      The {WNATIVE} address is retrieved from the {SENDER} contract.
     *      Sets the last execution timestamp to the current block timestamp and the delay to the
     *      maximum value to prevent any unwanted execution.
     *      Approves the maximum amount of LINK tokens to the {SENDER} contract to allow the
     *      payment of LINK fees for CCIP messages.
     */
    constructor(address sender, uint64 destChainSelector, address initialOwner) Ownable(initialOwner) {
        if (sender == address(0) || destChainSelector == 0) {
            revert SyncTriggerInvalidParameters();
        }

        SENDER = sender;
        DEST_CHAIN_SELECTOR = destChainSelector;
        WNATIVE = ICustomSender(sender).WNATIVE();

        _lastExecution = uint48(block.timestamp);
        _delay = type(uint48).max; // Deactivated by default

        IERC20(ICustomSender(sender).LINK_TOKEN()).forceApprove(sender, type(uint256).max);
    }

    // ──────────────── View ───────────────────────────────────────────────

    function getForwarder() public view virtual returns (address) {
        return _forwarder;
    }

    function getLastExecution() public view virtual returns (uint48) {
        return _lastExecution;
    }

    function getDelay() public view virtual returns (uint48) {
        return _delay;
    }

    function getAmounts() public view virtual returns (uint128, uint128) {
        return (_minAmount, _maxAmount);
    }

    function getFeeOtoD() public view virtual returns (bytes memory) {
        return _feeOtoD;
    }

    function getFeeDtoO() public view virtual returns (bytes memory) {
        return _feeDtoO;
    }

    function getAmountToSync() public view virtual returns (uint256) {
        return _getAmountToSync();
    }

    function getMaxFees() public view virtual returns (uint256 maxNativeFee, uint256 maxLinkFee) {
        (uint256 maxFeeOtoD, bool payInLinkOtoD) = FeeCodec.decodeFeeMemory(_feeOtoD);

        if (payInLinkOtoD) maxLinkFee = maxFeeOtoD;
        else maxNativeFee = maxFeeOtoD;

        (uint256 maxFeeDtoO, bool payInLinkDtoO) = FeeCodec.decodeFeeMemory(_feeDtoO);

        if (payInLinkDtoO) maxLinkFee += maxFeeDtoO;
        else maxNativeFee += maxFeeDtoO;
    }

    /**
     * @notice Returns whether a sync should be triggered and the amount to sync.
     * @return syncNeeded True if the pool has enough WETH and the delay has passed.
     * @return amount The amount of WETH that would be synced.
     */
    function shouldSync() public view virtual returns (bool syncNeeded, uint256 amount) {
        amount = _getAmountToSync();
        syncNeeded = amount > 0;
    }

    // ──────────────── Execution ──────────────────────────────────────────

    /**
     * @notice Triggers a sync of accumulated WETH from the L2 pool to L1 via CCIP.
     * @dev Re-checks conditions on-chain as a safety net (defense-in-depth).
     *
     * Requirements:
     * - The caller must be the forwarder (CREReceiver).
     * - The sync conditions must be met (delay passed, pool balance >= minAmount).
     */
    function triggerSync() public virtual onlyForwarder {
        uint256 amount = _getAmountToSync();

        if (amount == 0) revert SyncTriggerSyncNotNeeded();

        _lastExecution = uint48(block.timestamp);

        bytes memory feeOtoD = _feeOtoD;
        bytes memory feeDtoO = _feeDtoO;

        (uint256 maxFeeOtoD, bool payInLinkOtoD) = FeeCodec.decodeFeeMemory(feeOtoD);
        (uint256 feeAmountDtoO, bool payInLinkDtoO) = FeeCodec.decodeFeeMemory(feeDtoO);

        uint256 nativeAmount = (payInLinkDtoO ? 0 : feeAmountDtoO) + (payInLinkOtoD ? 0 : maxFeeOtoD);
        ICustomSender(SENDER).sync{value: nativeAmount}(DEST_CHAIN_SELECTOR, amount, feeOtoD, feeDtoO);
    }

    // ──────────────── Admin ──────────────────────────────────────────────

    function setForwarder(address forwarder) public virtual onlyOwner {
        _setForwarder(forwarder);
    }

    function setDelay(uint48 delay) public virtual onlyOwner {
        _setDelay(delay);
    }

    function setAmounts(uint128 minAmount, uint128 maxAmount) public virtual onlyOwner {
        _setAmounts(minAmount, maxAmount);
    }

    function setFeeOtoD(bytes calldata fee) public virtual onlyOwner {
        _setFeeOtoD(fee);
    }

    function setFeeDtoO(bytes calldata fee) public virtual onlyOwner {
        _setFeeDtoO(fee);
    }

    function sweep(address token, address recipient, uint256 amount) public virtual onlyOwner {
        TokenHelper.transfer(token, recipient, amount);
    }

    // ──────────────── Internal ───────────────────────────────────────────

    function _getAmountToSync() internal view virtual returns (uint256 amount) {
        // L-1: widen to uint256 before adding. With uint48 operands, _lastExecution + _delay
        // overflow-reverts when _delay == type(uint48).max (the "deactivated" default), turning the
        // intended "no sync" into a panic that the off-chain CRE eth_call probe sees as a revert.
        // In uint256 the threshold is simply unreachable, so the deactivated state cleanly returns 0.
        if (block.timestamp >= uint256(_lastExecution) + _delay) {
            address oraclePool = ICustomSender(SENDER).getOraclePool();
            uint256 wnativeAmount = IERC20(WNATIVE).balanceOf(oraclePool);

            if (wnativeAmount >= _minAmount) {
                uint256 maxAmount = _maxAmount;
                amount = wnativeAmount > maxAmount ? maxAmount : wnativeAmount;
            }
        }
    }

    function _setForwarder(address forwarder) internal virtual {
        // L-13: reject address(0) to align with CREReceiver.setForwarder. Without this a single
        // owner call to setForwarder(0) would permanently brick triggerSync (its onlyForwarder
        // compares msg.sender != address(0), which is always true). Owner-only self-brick guard.
        if (forwarder == address(0)) revert SyncTriggerInvalidForwarder();
        _forwarder = forwarder;
        emit ForwarderSet(forwarder);
    }

    function _setDelay(uint48 delay) internal virtual {
        _delay = delay;
        emit DelaySet(delay);
    }

    function _setAmounts(uint128 minAmount, uint128 maxAmount) internal virtual {
        if (minAmount == 0 || minAmount > maxAmount) revert SyncTriggerInvalidAmounts(minAmount, maxAmount);

        _minAmount = minAmount;
        _maxAmount = maxAmount;

        emit AmountsSet(minAmount, maxAmount);
    }

    function _setFeeOtoD(bytes calldata fee) internal virtual {
        // L-2: validate at set-time with the same decoder the consumer uses. `CustomSender`
        // re-decodes feeOtoD with `FeeCodec.decodeCCIP` (length must be exactly 21), but the
        // setter previously accepted any length, so a 17–20-byte config passed here then
        // self-DoSed inside `sync`. decodeCCIP reverts unless length == 21.
        FeeCodec.decodeCCIP(fee);
        _feeOtoD = fee;
        emit FeeOtoDSet(fee);
    }

    function _setFeeDtoO(bytes calldata fee) internal virtual {
        // L-2: validate at set-time with the same decoder the consumer uses. `CustomSender`
        // re-decodes feeDtoO with `FeeCodec.decodeFee` (length must be >= 17); reject shorter
        // buffers here rather than letting them self-DoS inside `sync`.
        FeeCodec.decodeFee(fee);
        _feeDtoO = fee;
        emit FeeDtoOSet(fee);
    }
}
