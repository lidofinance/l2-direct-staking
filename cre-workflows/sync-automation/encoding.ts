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

/**
 * Decodes the shouldSync return value.
 */
export function decodeShouldSyncResult(data: `0x${string}`): {
  syncNeeded: boolean;
  amount: bigint;
} {
  const decoded = decodeFunctionResult({
    abi: SyncTriggerABI,
    functionName: "shouldSync",
    data,
  });

  return {
    syncNeeded: decoded[0] as boolean,
    amount: decoded[1] as bigint,
  };
}

/**
 * Encodes the shouldSync call data (no arguments).
 */
export function encodeShouldSyncCall(): Hex {
  return encodeFunctionData({
    abi: SyncTriggerABI,
    functionName: "shouldSync",
  });
}
