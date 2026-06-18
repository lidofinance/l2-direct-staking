/**
 * Tests for Lido Sync CRE Workflow
 *
 * Tests the pure encoding/decoding logic used in the workflow.
 * The CRE runtime (EVMClient, Runtime, Runner) is not testable outside
 * the CRE WASM environment, so we test the encoding layer that bridges
 * between on-chain ABI and the CRE report format.
 */

import { describe, test, expect } from "bun:test";
import {
  encodeFunctionData,
  decodeFunctionData,
  encodeAbiParameters,
  decodeAbiParameters,
  type Hex,
  zeroAddress,
  getAddress,
} from "viem";
import { SyncTriggerABI } from "./abi";
import {
  encodeReportPayload,
  encodeShouldSyncCall,
  decodeShouldSyncResult,
  encodeCanSyncCall,
  decodeCanSyncResult,
  encodeAmountToSyncCall,
  decodeAmountToSyncResult,
  decideSyncAction,
} from "./encoding";

// ─── Test constants ────────────────────────────────────────────────────────

const MOCK_TARGET = "0x328de900860816d29D1367F6903a24D8ed40C997";
const FIVE_ETHER = BigInt("5000000000000000000");

const encodeBool = (v: boolean): Hex => encodeAbiParameters([{ type: "bool" }], [v]);
const encodeUint = (v: bigint): Hex => encodeAbiParameters([{ type: "uint256" }], [v]);

// ─── shouldSync (due-ness) ──────────────────────────────────────────────────

describe("encodeShouldSyncCall", () => {
  test("encodes shouldSync() with no arguments", () => {
    const result = encodeShouldSyncCall();
    expect(result.startsWith("0x")).toBe(true);

    const decoded = decodeFunctionData({ abi: SyncTriggerABI, data: result });
    expect(decoded.functionName).toBe("shouldSync");
  });
});

describe("decodeShouldSyncResult", () => {
  test("decodes due=true", () => {
    expect(decodeShouldSyncResult(encodeBool(true))).toBe(true);
  });

  test("decodes due=false", () => {
    expect(decodeShouldSyncResult(encodeBool(false))).toBe(false);
  });
});

// ─── canSync (executability) ────────────────────────────────────────────────

describe("encodeCanSyncCall", () => {
  test("encodes canSync() with no arguments", () => {
    const result = encodeCanSyncCall();
    expect(result.startsWith("0x")).toBe(true);

    const decoded = decodeFunctionData({ abi: SyncTriggerABI, data: result });
    expect(decoded.functionName).toBe("canSync");
  });
});

describe("decodeCanSyncResult", () => {
  test("decodes executable=true", () => {
    expect(decodeCanSyncResult(encodeBool(true))).toBe(true);
  });

  test("decodes executable=false", () => {
    expect(decodeCanSyncResult(encodeBool(false))).toBe(false);
  });
});

// ─── getAmountToSync (telemetry) ────────────────────────────────────────────

describe("getAmountToSync helpers", () => {
  test("encodes getAmountToSync() with no arguments", () => {
    const decoded = decodeFunctionData({ abi: SyncTriggerABI, data: encodeAmountToSyncCall() });
    expect(decoded.functionName).toBe("getAmountToSync");
  });

  test("decodes the pending amount", () => {
    expect(decodeAmountToSyncResult(encodeUint(FIVE_ETHER))).toBe(FIVE_ETHER);
  });
});

// ─── decideSyncAction (handler branch routing) ─────────────────────────────

describe("decideSyncAction", () => {
  test("routes due && executable to execute", () => {
    expect(decideSyncAction({ due: true, executable: true })).toBe("execute");
  });

  test("routes due && !executable to blocked, NOT the report path", () => {
    // The exact DON-spam-prevention branch: a due sync whose executability precondition is unmet must
    // route to "blocked" (skip, submit no report) — never into the report-submitting "execute" path.
    expect(decideSyncAction({ due: true, executable: false })).toBe("blocked");
  });

  test("routes !due to no-action (executability is irrelevant when not due)", () => {
    expect(decideSyncAction({ due: false, executable: false })).toBe("no-action");
    expect(decideSyncAction({ due: false, executable: true })).toBe("no-action");
  });
});

// ─── encodeReportPayload ───────────────────────────────────────────────────

describe("encodeReportPayload", () => {
  test("encodes target + triggerSync() correctly", () => {
    const payload = encodeReportPayload(MOCK_TARGET);

    // Decode the outer layer: (address target, bytes data)
    const [target, data] = decodeAbiParameters(
      [
        { name: "target", type: "address" },
        { name: "data", type: "bytes" },
      ],
      payload,
    );

    expect(getAddress(target as string)).toBe(getAddress(MOCK_TARGET));

    // Decode inner layer: triggerSync()
    const decoded = decodeFunctionData({
      abi: SyncTriggerABI,
      data: data as Hex,
    });

    expect(decoded.functionName).toBe("triggerSync");
  });

  test("report payload is deterministic", () => {
    const a = encodeReportPayload(MOCK_TARGET);
    const b = encodeReportPayload(MOCK_TARGET);

    expect(a).toBe(b);
  });

  test("different targets produce different payloads", () => {
    const a = encodeReportPayload(MOCK_TARGET);
    const b = encodeReportPayload(zeroAddress);

    expect(a).not.toBe(b);
  });
});

// ─── End-to-end encoding round-trip ────────────────────────────────────────

describe("encoding round-trip", () => {
  test("due + executable → report payload → decodable on-chain", () => {
    // 1. Simulate the two predicate reads (as the workflow does).
    expect(decodeShouldSyncResult(encodeBool(true))).toBe(true);
    expect(decodeCanSyncResult(encodeBool(true))).toBe(true);
    expect(decideSyncAction({ due: true, executable: true })).toBe("execute");

    // 2. Encode the report payload (as the workflow does).
    const reportPayload = encodeReportPayload(MOCK_TARGET);

    // 3. Decode as the CREReceiver would: abi.decode(report, (address, bytes)).
    const [target, callData] = decodeAbiParameters(
      [
        { name: "target", type: "address" },
        { name: "data", type: "bytes" },
      ],
      reportPayload,
    );

    expect(getAddress(target as string)).toBe(getAddress(MOCK_TARGET));

    // 4. The callData should be triggerSync().
    const innerDecoded = decodeFunctionData({
      abi: SyncTriggerABI,
      data: callData as Hex,
    });

    expect(innerDecoded.functionName).toBe("triggerSync");
  });
});

// ─── ABI sanity checks ────────────────────────────────────────────────────

describe("ABI sanity", () => {
  test("view predicates encode to 4-byte selectors", () => {
    // selector = keccak256("<sig>()")[:4] → "0x" + 8 hex chars
    expect(encodeShouldSyncCall().length).toBe(10);
    expect(encodeCanSyncCall().length).toBe(10);
    expect(encodeAmountToSyncCall().length).toBe(10);
  });

  test("triggerSync selector is correct", () => {
    const encoded = encodeFunctionData({
      abi: SyncTriggerABI,
      functionName: "triggerSync",
    });

    // triggerSync() selector = keccak256("triggerSync()")[:4]
    expect(encoded.length).toBe(10);
  });
});
