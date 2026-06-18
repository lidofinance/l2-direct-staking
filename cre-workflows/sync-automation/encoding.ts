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

// ─── shouldSync (due-ness) ──────────────────────────────────────────────────

/** Encodes the shouldSync() call data (no arguments). */
export function encodeShouldSyncCall(): Hex {
  return encodeFunctionData({ abi: SyncTriggerABI, functionName: "shouldSync" });
}

/**
 * Decodes shouldSync() — whether a sync is DUE (the `delay` rate-limit has elapsed AND the pool holds
 * at least `minAmount` WETH). Due-ness only; executability is a separate predicate, see {decodeCanSyncResult}.
 */
export function decodeShouldSyncResult(data: `0x${string}`): boolean {
  return decodeFunctionResult({
    abi: SyncTriggerABI,
    functionName: "shouldSync",
    data,
  }) as boolean;
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

// ─── getAmountToSync (telemetry) ────────────────────────────────────────────

/** Encodes the getAmountToSync() call data (no arguments). */
export function encodeAmountToSyncCall(): Hex {
  return encodeFunctionData({ abi: SyncTriggerABI, functionName: "getAmountToSync" });
}

/**
 * Decodes getAmountToSync() — the WETH amount a sync would move (capped at `maxAmount`), independent of
 * due-ness/executability. Used only for logging: the report carries no amount, triggerSync recomputes it.
 */
export function decodeAmountToSyncResult(data: `0x${string}`): bigint {
  return decodeFunctionResult({
    abi: SyncTriggerABI,
    functionName: "getAmountToSync",
    data,
  }) as bigint;
}

// ─── routing ────────────────────────────────────────────────────────────────

/** Terminal routing of a cron tick, derived purely from the shouldSync()/canSync() predicates. */
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
