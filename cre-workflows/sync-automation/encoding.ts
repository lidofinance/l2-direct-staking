/**
 * Pure encoding/decoding helpers for the Lido Sync CRE workflow.
 *
 * These functions bridge between on-chain ABI and the CRE report format.
 * They are pure (no CRE runtime dependency) and fully testable outside WASM.
 */

import {
  encodeFunctionData,
  decodeFunctionResult,
  encodeAbiParameters,
  type Hex,
} from "viem";
import { SyncTriggerABI } from "./abi";

/**
 * Encodes the report payload for CREReceiver.onReport().
 * Layout: abi.encode(address target, bytes data)
 * where `data` is the triggerSync() calldata (no arguments).
 */
export function encodeReportPayload(targetAddress: string): Hex {
  const callData = encodeFunctionData({
    abi: SyncTriggerABI,
    functionName: "triggerSync",
  });

  return encodeAbiParameters(
    [
      { name: "target", type: "address" },
      { name: "data", type: "bytes" },
    ],
    [targetAddress as Hex, callData],
  );
}

// ─── shouldSyncAmount (due-ness + amount) ────────────────────────────────────

/** Encodes the shouldSyncAmount() call data (no arguments). */
export function encodeShouldSyncAmountCall(): Hex {
  return encodeFunctionData({ abi: SyncTriggerABI, functionName: "shouldSyncAmount" });
}

/**
 * Decodes shouldSyncAmount() — the WETH amount a sync would move RIGHT NOW (capped at `maxAmount`), or
 * 0 when a sync is not DUE (the `delay` rate-limit has not elapsed, or the pool holds less than
 * `minAmount`). A nonzero return is both the due-ness signal AND the amount, so one read serves both.
 * Executability is a separate predicate, see {decodeCanSyncResult}.
 */
export function decodeShouldSyncAmountResult(data: `0x${string}`): bigint {
  return decodeFunctionResult({
    abi: SyncTriggerABI,
    functionName: "shouldSyncAmount",
    data,
  }) as bigint;
}

// ─── canSync (executability) ────────────────────────────────────────────────

/** Encodes the canSync() call data (no arguments). */
export function encodeCanSyncCall(): Hex {
  return encodeFunctionData({ abi: SyncTriggerABI, functionName: "canSync" });
}

/**
 * Decodes canSync() — whether a due sync would actually SUCCEED on-chain right now: the fee float covers
 * getMaxFees(), this trigger still holds SYNC_ROLE, and the OraclePool is not paused. Polled alongside
 * shouldSync so the DON suppresses a due-but-blocked tick instead of submitting a guaranteed-revert report.
 */
export function decodeCanSyncResult(data: `0x${string}`): boolean {
  return decodeFunctionResult({
    abi: SyncTriggerABI,
    functionName: "canSync",
    data,
  }) as boolean;
}

// ─── routing ────────────────────────────────────────────────────────────────

/** Terminal routing of a cron tick, derived purely from the shouldSyncAmount()/canSync() predicates. */
export type SyncAction = "execute" | "blocked" | "no-action";

/**
 * Routes a cron tick to one of three terminal branches from the two on-chain predicates:
 *  - "execute"   — due && executable: submit the triggerSync report.
 *  - "blocked"   — due && !executable: a sync IS due but an executability precondition is unmet
 *                  (fee float / SYNC_ROLE / pool pause). Skip — submitting would guarantee a revert
 *                  every tick (the silent DON spam this split exists to prevent); off-chain monitoring
 *                  surfaces the stall.
 *  - "no-action" — !due: nothing to sync (delay not elapsed / pool below min).
 *
 * Extracted as a pure function so the handler's branch routing is unit-testable outside the CRE WASM
 * runtime (the rest of onCronTrigger — EVMClient, Runtime, Runner — is not).
 */
export function decideSyncAction(result: {
  due: boolean;
  executable: boolean;
}): SyncAction {
  if (!result.due) return "no-action";
  return result.executable ? "execute" : "blocked";
}
