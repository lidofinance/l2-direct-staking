// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {ICustomSender} from "@csr/interfaces/ICustomSender.sol";

/**
 * @dev Minimal view of OpenZeppelin's {Pausable} surface, used to probe the OraclePool's pause state
 *      without coupling to a specific pool implementation. The base {OraclePool} variant is not
 *      pausable and exposes no `paused()`; {SyncTrigger.canSync} calls this through a try/catch so a
 *      missing method reads as "not paused" rather than reverting the whole predicate.
 */
interface IPausableLike {
    function paused() external view returns (bool);
}

/**
 * @title SyncTrigger
 * @notice Decides when and how much to trigger `CustomSender.sync()`, which sends accumulated
 *         WETH from the L2 OraclePool to L1 for Lido staking and bridges wstETH back.
 * @dev The sync is triggered every `delay` seconds if the pool's WETH balance exceeds `minAmount`,
 *      capped at `maxAmount` per trigger.
 */
contract SyncTrigger is Ownable {
    using SafeERC20 for IERC20;

    error SyncTriggerInvalidAmounts(uint128 minAmount, uint128 maxAmount);
    error SyncTriggerInvalidParameters();
    error SyncTriggerSyncNotNeeded();
    error SyncTriggerOnlyForwarder();
    error SyncTriggerInvalidForwarder();
    error SyncTriggerInvalidDelay();
    error SyncTriggerInvalidRecipient();
    error SyncTriggerNativeTransferFailed();
    error SyncTriggerInsufficientFloat(uint256 required, uint256 available);
    error SyncTriggerGasLimitAboveMax(uint32 gasLimit, uint32 maxGasLimit);

    event AmountsSet(uint128 minAmount, uint128 maxAmount);
    event DelaySet(uint48 delay);
    event FeeDtoOSet(bytes fee);
    event FeeOtoDSet(bytes fee);
    event ForwarderSet(address forwarder);
    event MaxGasLimitSet(uint32 maxGasLimit);
    event Swept(address indexed token, address indexed recipient, uint256 amount);

    /**
     * @notice The owner-settable, in-storage SyncTrigger parameters, supplied at construction and
     *         thereafter via the gated setters. Grouped into a struct — rather than positional args —
     *         so the same-typed adjacent pairs (`minAmount`/`maxAmount`, `feeOtoD`/`feeDtoO`) cannot be
     *         silently transposed at the call site. The immutable identity (`sender`, `destChainSelector`)
     *         and `initialOwner` are passed as separate constructor arguments.
     * @param forwarder The address allowed to call {triggerSync} (the CREReceiver).
     * @param delay Minimum seconds between syncs; `type(uint48).max` deactivates syncing.
     * @param minAmount Minimum pool WETH that makes a sync due.
     * @param maxAmount Maximum WETH synced per trigger.
     * @param feeOtoD CCIP-encoded origin->destination fee blob (exactly 21 bytes).
     * @param feeDtoO Encoded destination->origin bridge fee blob (at least 17 bytes; the real
     *        lane-specific shape is enforced on L1 by the bridge adapter, NOT here — see {_setFeeDtoO}).
     * @param maxGasLimit Per-lane ceiling for the feeOtoD gasLimit.
     */
    struct InitParams {
        address forwarder;
        uint48 delay;
        uint128 minAmount;
        uint128 maxAmount;
        bytes feeOtoD;
        bytes feeDtoO;
        uint32 maxGasLimit;
    }

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

    uint32 private _maxGasLimit;

    modifier onlyForwarder() {
        if (msg.sender != _forwarder) revert SyncTriggerOnlyForwarder();
        _;
    }

    receive() external payable {}

    /**
     * @dev {WNATIVE} is read from {SENDER}. The owner-settable parameters in `p` are validated and stored
     *      at construction by delegating to the same internal setters the owner uses post-deploy, so the
     *      contract is born fully configured and emits the canonical `*Set` events. The call order is
     *      load-bearing: `_setMaxGasLimit` must precede `_setFeeOtoD`, which validates the decoded
     *      gasLimit against the ceiling. Grants {SENDER} an unbounded LINK allowance to pay CCIP fees.
     *
     *      Every parameter is strict — there is no "unset" representation: `_setFeeOtoD`/`_setFeeDtoO`
     *      reject empty blobs (length guards) and the amount/delay/forwarder setters reject zero, so a
     *      half-configured SyncTrigger cannot be constructed. Deactivation stays available post-deploy
     *      via `setDelay(type(uint48).max)`.
     */
    constructor(address sender, uint64 destChainSelector, address initialOwner, InitParams memory p)
        Ownable(initialOwner)
    {
        if (sender == address(0) || destChainSelector == 0) {
            revert SyncTriggerInvalidParameters();
        }

        SENDER = sender;
        DEST_CHAIN_SELECTOR = destChainSelector;
        WNATIVE = ICustomSender(sender).WNATIVE();
        _lastExecution = uint48(block.timestamp);

        IERC20(ICustomSender(sender).LINK_TOKEN()).forceApprove(sender, type(uint256).max);

        // Ceiling first: `_setFeeOtoD` validates gasLimit <= `_maxGasLimit`. `_setMaxGasLimit`'s
        // stored-feeOtoD re-check is skipped here because `_feeOtoD` is still empty at this point.
        _setMaxGasLimit(p.maxGasLimit);
        _setFeeOtoD(p.feeOtoD);
        _setFeeDtoO(p.feeDtoO);
        _setAmounts(p.minAmount, p.maxAmount);
        _setDelay(p.delay);
        _setForwarder(p.forwarder);
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
        // Split shared with the deploy script's `runPrintFeeParams` via the {_maxFees} mirror so the
        // on-chain truth and the verify-constants-sync oracle cannot drift. Reverts on an empty fee blob —
        // the sole on-chain caller, {canSync}, guards `_feeOtoD`/`_feeDtoO` non-empty before reaching here.
        return _maxFees(_feeOtoD, _feeDtoO);
    }

    function getMaxGasLimit() public view virtual returns (uint32) {
        return _maxGasLimit;
    }

    /**
     * @notice Returns whether a sync is DUE: the `delay` rate-limit has elapsed since the last sync AND
     *         the pool holds at least `minAmount` WETH (the amount itself, capped at `maxAmount`, is
     *         exposed separately via {getAmountToSync}).
     * @dev One of the two on-chain signals the CRE DON polls each tick; {canSync} (executability) is the
     *      other. The DON submits a `triggerSync` report only when BOTH hold; a tick that is due but not
     *      executable is a stall it suppresses (logs `blocked`, emits no report) rather than a
     *      guaranteed-revert submission that would silently stall syncing with no on-chain signal.
     *      {triggerSync} also re-checks this predicate on-chain as a defense-in-depth rate-limit.
     *
     *      Deliberately TOTAL (never reverts) so the off-chain `eth_call` probe always gets a clean
     *      bool: it reads only `block.timestamp`, the stored window, and the pool balance — never the fee
     *      blobs, whose decode reverts while unset (that guard lives in {canSync}).
     * @return True if a sync is due (delay elapsed AND pool WETH >= minAmount).
     */
    function shouldSync() public view virtual returns (bool) {
        // widen to uint256 before adding. With uint48 operands, _lastExecution + _delay
        // overflow-reverts when _delay == type(uint48).max (the "deactivated" value), turning the
        // intended "no sync" into a panic that the off-chain CRE eth_call probe sees as a revert.
        // In uint256 the threshold is simply unreachable, so the deactivated state cleanly returns false.
        if (block.timestamp < uint256(_lastExecution) + _delay) return false;

        return _getAmountToSync() != 0;
    }

    /**
     * @notice Returns whether a due sync would actually SUCCEED on-chain right now — the executability
     *         predicate the CRE DON polls alongside {shouldSync}. The DON submits a `triggerSync` report
     *         only when both are true; a due-but-`!canSync` tick is suppressed (logged `blocked`, no
     *         report) instead of a guaranteed-revert submission that would silently stall syncing.
     * @dev Checks the `triggerSync -> CustomSender.sync` preconditions reachable through stable,
     *      non-CCIP surfaces:
     *      - this contract still holds `SYNC_ROLE` on {SENDER} (revocation is a documented kill switch);
     *      - the OraclePool is not paused (also a documented kill switch — the DON then halts cleanly);
     *      - the native fee float covers `getMaxFees().maxNativeFee` (the value `triggerSync` fronts);
     *      - the LINK fee float covers `getMaxFees().maxLinkFee` (pulled by `CustomSender` via allowance).
     *
     *      Like {shouldSync} it is deliberately TOTAL (never reverts) so the off-chain probe gets a clean
     *      bool — hence the empty-fee guard below, since `getMaxFees` reverts on an unset blob.
     *
     *      It deliberately does NOT check the live CCIP fee, which would require mirroring `CustomSender`'s
     *      internal message construction (no public quote view) and would drift across CSR/CCIP releases.
     *      Live-fee adequacy stays an off-chain monitoring concern; an under-funded float also surfaces
     *      on-chain via the named {SyncTriggerInsufficientFloat} revert in {triggerSync}.
     *
     *      Three further `sync`-time preconditions are likewise NOT checked — a regression in any spams
     *      router/sync reverts rather than producing a clean stall, so all are caught elsewhere:
     *      - the CCIP dest-chain allow-list (`IRouterClient.isChainSupported`) and the RMN curse state,
     *        watched off-chain (docs/monitoring.md §3). If CCIP governance de-allow-lists
     *        `DEST_CHAIN_SELECTOR` or RMN curses the lane, both predicates still return true and every
     *        `triggerSync` reverts INSIDE the router. The RMN curse has no single stable view to mirror;
     *        the allow-list does, but is omitted too, to keep the predicate free of CCIP-version coupling
     *        (the same rationale as the live fee).
     *      - the per-lane gas-limit ceiling, enforced at set-time instead (`_setFeeOtoD` /
     *        `_setMaxGasLimit` vs the `_maxGasLimit` bound): a `feeOtoD` gasLimit above the lane's
     *        FeeQuoter `maxPerMsgGasLimit` reverts `MessageGasLimitTooHigh` inside every `sync`.
     *
     *      The LINK branch is dormant today: every lane pays both legs in native (`payInLink == false`),
     *      so `maxLinkFee == 0`. It is gated on the configured MAX (`getMaxFees().maxLinkFee`) whereas
     *      `CustomSender` pulls only the LIVE LINK fee, so a balance in `[liveFee, maxLinkFee)` reads as a
     *      conservative false-negative; a LINK-starved `triggerSync` reverts in `CustomSender`'s
     *      `transferFrom` with no named float error (unlike the native {SyncTriggerInsufficientFloat}).
     * @return True if every checked precondition holds (does NOT include due-ness — see {shouldSync}).
     */
    function canSync() public view returns (bool) {
        if (!IAccessControl(SENDER).hasRole(ICustomSender(SENDER).SYNC_ROLE(), address(this))) return false;

        if (_isPaused(ICustomSender(SENDER).getOraclePool())) return false;

        // Empty-fee guard (defense-in-depth). The strict constructor and the setters only ever store a
        // full, decodable blob, so an empty _feeOtoD/_feeDtoO is no longer reachable post-construction;
        // were one ever empty, getMaxFees() -> FeeCodec.decodeFeeMemory would revert
        // (FeeCodecInvalidDataLength) on the <17-byte buffer. Return false instead, keeping canSync
        // TOTAL: a due-but-unconfigured trigger reads as "not executable", never a probe revert.
        if (_feeOtoD.length == 0 || _feeDtoO.length == 0) return false;

        (uint256 maxNativeFee, uint256 maxLinkFee) = getMaxFees();

        if (address(this).balance < maxNativeFee) return false;
        if (
            maxLinkFee > 0
                && IERC20(ICustomSender(SENDER).LINK_TOKEN()).balanceOf(address(this)) < maxLinkFee
        ) return false;

        return true;
    }

    // ──────────────── Execution ──────────────────────────────────────────

    /**
     * @notice Triggers a sync of accumulated WETH from the L2 pool to L1 via CCIP.
     * @dev Re-checks {shouldSync} on-chain as a defense-in-depth rate-limit, then pre-flights the native
     *      fee float before fronting the CCIP fee.
     *
     * Requirements:
     * - The caller must be the forwarder (CREReceiver).
     * - The sync conditions must be met (delay passed, pool balance >= minAmount).
     */
    function triggerSync() public virtual onlyForwarder {
        // Defense-in-depth rate-limit re-checking shouldSync()'s window, but reading the pending amount
        // only ONCE here (calling shouldSync() would compute _getAmountToSync() a second time). Widen to
        // uint256 so the deactivated `_delay == type(uint48).max` value can't overflow-revert.
        if (block.timestamp < uint256(_lastExecution) + _delay) revert SyncTriggerSyncNotNeeded();
        uint256 amount = _getAmountToSync();
        if (amount == 0) revert SyncTriggerSyncNotNeeded();

        _lastExecution = uint48(block.timestamp);

        bytes memory feeOtoD = _feeOtoD;
        bytes memory feeDtoO = _feeDtoO;

        // Native fee to front = the native-denominated legs of both blobs. Shared with
        // getMaxFees()/canSync() via the {_maxFees} mirror so the float pre-flight here and the
        // executability check there cannot drift from the value actually sent.
        (uint256 nativeAmount,) = _maxFees(feeOtoD, feeDtoO);

        // Pre-flight the native fee float. `sync{value: nativeAmount}` fronts the CCIP fee from this
        // contract's own balance, which depletes monotonically (only the maxFeeOtoD overage refunds).
        // Without this, a depleted float reverts at the bare value transfer (surfaced as an opaque
        // CallExecutionFailed) while a pure delay/balance predicate would read true off-chain — a silent,
        // signalless stall. Revert with a named, indexable error instead; {canSync}'s float check
        // mirrors this exact requirement (getMaxFees().maxNativeFee) so the DON suppresses the report.
        if (address(this).balance < nativeAmount) {
            revert SyncTriggerInsufficientFloat(nativeAmount, address(this).balance);
        }

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

    function setMaxGasLimit(uint32 maxGasLimit) public virtual onlyOwner {
        _setMaxGasLimit(maxGasLimit);
    }

    function sweep(address token, address recipient, uint256 amount) public virtual onlyOwner {
        if (recipient == address(0)) revert SyncTriggerInvalidRecipient();
        if (amount == 0) return;

        if (token == address(0)) {
            (bool success,) = recipient.call{value: amount}("");
            if (!success) revert SyncTriggerNativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }

        emit Swept(token, recipient, amount);
    }

    // ──────────────── Internal ───────────────────────────────────────────

    /**
     * @dev Splits the OtoD/DtoO fee blobs into their max native- and LINK-denominated totals, summing
     *      each leg's `maxFee` into the native or LINK total per that leg's `payInLink` flag. Called by
     *      BOTH {getMaxFees} and {triggerSync} so the executability check and the value actually fronted
     *      share ONE on-chain definition. The deploy script's `runPrintFeeParams` keeps a byte-identical
     *      mirror; the two copies are pinned together by `verify-constants-sync` (pre-deploy) and
     *      state-mate (live) against the same `<net>.inputs.yaml` anchors, and by the fee-split
     *      equivalence test. `decodeFeeMemory` reads the first 17 bytes (maxFee[0:16] + payInLink[16]) and
     *      reverts (FeeCodecInvalidDataLength) on a <17-byte buffer, so callers must guard empty/unset
     *      blobs ({canSync} pre-checks non-empty; the constructor/setters reject short blobs).
     */
    function _maxFees(bytes memory feeOtoD, bytes memory feeDtoO)
        private
        pure
        returns (uint256 maxNativeFee, uint256 maxLinkFee)
    {
        (uint256 maxFeeOtoD, bool payInLinkOtoD) = FeeCodec.decodeFeeMemory(feeOtoD);
        if (payInLinkOtoD) maxLinkFee = maxFeeOtoD;
        else maxNativeFee = maxFeeOtoD;

        (uint256 maxFeeDtoO, bool payInLinkDtoO) = FeeCodec.decodeFeeMemory(feeDtoO);
        if (payInLinkDtoO) maxLinkFee += maxFeeDtoO;
        else maxNativeFee += maxFeeDtoO;
    }

    function _getAmountToSync() internal view virtual returns (uint256 amount) {
        address oraclePool = ICustomSender(SENDER).getOraclePool();
        uint256 wnativeAmount = IERC20(WNATIVE).balanceOf(oraclePool);

        if (wnativeAmount < _minAmount) {
            return 0;
        }

        uint256 maxAmount = _maxAmount;
        amount = wnativeAmount > maxAmount ? maxAmount : wnativeAmount;
    }

    function _isPaused(address pool) internal view virtual returns (bool) {
        // Production `getOraclePool()` returns a PausableImmutableOraclePool with a real `paused()`. The
        // base {OraclePool} variant has code but no `paused()` and no fallback, so the call reverts
        // cleanly and the catch reads it as "not paused". NOTE the catch is narrow: only a callee that
        // actively reverts is caught — a code-less `pool`, or one whose `paused()` returns < 32 bytes,
        // reverts during the success-branch ABI decode and PROPAGATES past this try/catch. Not reachable
        // today; do not rely on this to tolerate an arbitrary `pool` address.
        try IPausableLike(pool).paused() returns (bool paused) {
            return paused;
        } catch {
            return false;
        }
    }

    function _setForwarder(address forwarder) internal virtual {
        // reject address(0) to align with CREReceiver.setForwarder. Without this a single
        // owner call to setForwarder(0) would permanently brick triggerSync (its onlyForwarder
        // compares msg.sender != address(0), which is always true). Owner-only self-brick guard.
        if (forwarder == address(0)) revert SyncTriggerInvalidForwarder();
        _forwarder = forwarder;
        emit ForwarderSet(forwarder);
    }

    function _setDelay(uint48 delay) internal virtual {
        // reject 0: with _delay == 0, `_getAmountToSync`'s `block.timestamp >= _lastExecution + 0` is
        // ALWAYS true, permanently defeating the time-based rate limiter — every forwarder invocation
        // would fire a sync the moment the pool crosses minAmount, fragmenting batches and draining the
        // fee float at the CRE cron cadence. Deactivation uses `type(uint48).max` (the constructor
        // default), never 0, so 0 is never a valid value — guard the owner against this self-footgun,
        // mirroring the setForwarder(0) and setAmounts(0,...) guards.
        if (delay == 0) revert SyncTriggerInvalidDelay();
        _delay = delay;
        emit DelaySet(delay);
    }

    function _setAmounts(uint128 minAmount, uint128 maxAmount) internal virtual {
        if (minAmount == 0 || minAmount > maxAmount) revert SyncTriggerInvalidAmounts(minAmount, maxAmount);

        _minAmount = minAmount;
        _maxAmount = maxAmount;

        emit AmountsSet(minAmount, maxAmount);
    }

    function _setFeeOtoD(bytes memory fee) internal virtual {
        // validate at set-time with the same length the consumer enforces. `CustomSender` re-decodes
        // feeOtoD with `FeeCodec.decodeCCIP` (length must be EXACTLY 21). The memory decoder used below
        // only enforces length >= 21, so guard the exact length explicitly here — otherwise a 22+ byte
        // blob would store cleanly then self-DoS inside `sync`. (`memory` not `calldata`: the constructor
        // reuses this validator, and constructor args cannot be calldata.)
        if (fee.length != 21) revert FeeCodec.FeeCodecInvalidDataLength(fee.length, 21);
        (,, uint32 gasLimit) = FeeCodec.decodeCCIPMemory(fee);
        // a decodable 21-byte config can still carry a gasLimit below the sender's floor, which
        // makes every sync revert with CustomSenderInsufficientGas while shouldSync stays true —
        // the CRE DON would then submit a reverting tx every tick. Enforce the floor at set-time.
        if (gasLimit < ICustomSender(SENDER).MIN_PROCESS_MESSAGE_GAS()) {
            revert SyncTriggerInvalidParameters();
        }
        // ...and reject a gasLimit above the per-lane ceiling. CCIP's FeeQuoter (v1.6) / OnRamp (v1.5)
        // caps gasLimit at a per-lane `maxPerMsgGasLimit`; an over-cap config (e.g. a chain-blind uniform
        // bump that exceeds Linea's lower cap) is otherwise accepted here yet reverts MessageGasLimitTooHigh
        // inside every sync, with shouldSync still true. Fail loudly at set-time. `_maxGasLimit` is
        // seeded (constructor) / owner-set per lane, so this bound always binds.
        if (gasLimit > _maxGasLimit) {
            revert SyncTriggerGasLimitAboveMax(gasLimit, _maxGasLimit);
        }
        _feeOtoD = fee;
        emit FeeOtoDSet(fee);
    }

    function _setMaxGasLimit(uint32 maxGasLimit) internal virtual {
        // The ceiling must leave room for at least the sender's floor; a value below it would make
        // every feeOtoD unsettable (floor <= gasLimit <= max becomes empty). Guard the owner footgun.
        if (maxGasLimit < ICustomSender(SENDER).MIN_PROCESS_MESSAGE_GAS()) {
            revert SyncTriggerInvalidParameters();
        }
        // Re-validate the ALREADY-stored feeOtoD against the new ceiling. `_setFeeOtoD` enforces
        // gasLimit <= _maxGasLimit only at fee-set time, so LOWERING the ceiling here (e.g. to mirror a
        // CCIP `maxPerMsgGasLimit` cut) below a previously-accepted gasLimit would otherwise silently
        // re-open the C-1 stall: `shouldSync` stays true while every `sync` reverts MessageGasLimitTooHigh
        // in CCIP's FeeQuoter. Reject the lowering so the owner re-sets feeOtoD first. An empty feeOtoD
        // (fresh deploy) carries no gasLimit, so skip it — the bound binds again on the next setFeeOtoD.
        if (_feeOtoD.length != 0) {
            (,, uint32 gasLimit) = FeeCodec.decodeCCIPMemory(_feeOtoD);
            if (gasLimit > maxGasLimit) {
                revert SyncTriggerGasLimitAboveMax(gasLimit, maxGasLimit);
            }
        }
        _maxGasLimit = maxGasLimit;
        emit MaxGasLimitSet(maxGasLimit);
    }

    function _setFeeDtoO(bytes memory fee) internal virtual {
        // Validate at set-time: CustomSender re-decodes feeDtoO via FeeCodec.decodeFee (len must be
        // >= 17); reject short buffers here rather than letting them self-DoS inside sync. The memory
        // decoder enforces the same >= 17 bound as the calldata decodeFee. (`memory` not `calldata`:
        // the constructor reuses this validator, and constructor args cannot be calldata.)
        //
        // DELIBERATELY GENERIC — unlike _setFeeOtoD (which pins the exact 21-byte CCIP shape + gasLimit
        // floor/ceiling), this does NOT enforce the lane-specific feeDtoO shape the L1 bridge adapter
        // requires (Arbitrum 29B with feeAmount != 0; Optimism/Base 21B with feeAmount == 0; Linea 17B;
        // all payInLink == false). A lane-mismatched blob is accepted here AND on L2 (CustomSender also
        // decodes feeDtoO only with the generic decodeFee), crosses to L1, and reverts inside the
        // adapter — parked by the defensive receiver for owner recovery (recoverTokens), not lost. Left
        // off-chain on purpose: the format is immutable-per-lane (pinned in chainlink-csr + the L1
        // adapter, changeable only via a coordinated L1-governance setAdapter, so an on-chain check
        // would couple this trigger to a format it cannot re-bind), the failure is owner-gated
        // (onlyOwner) and L1-recoverable, and the encoded bytes are pinned off-chain at deploy
        // (verify-stage1 keccak vs the migration constants; live state-mate getFeeDtoO). The residual is
        // a manual post-deploy retune — see docs/fees.md §FeeDtoO encoding, docs/audit-scope.md §D F-4.
        FeeCodec.decodeFeeMemory(fee);
        _feeDtoO = fee;
        emit FeeDtoOSet(fee);
    }
}
