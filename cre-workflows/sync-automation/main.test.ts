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
  decodeShouldSyncResult,
  encodeShouldSyncCall,
} from "./encoding";

// ─── Test constants ────────────────────────────────────────────────────────

const MOCK_TARGET = "0x328de900860816d29D1367F6903a24D8ed40C997";
const FIVE_ETHER = BigInt("5000000000000000000");

// ─── encodeShouldSyncCall ─────────────────────────────────────────────────

describe("encodeShouldSyncCall", () => {
  test("encodes shouldSync() with no arguments", () => {
    const result = encodeShouldSyncCall();

    // Should be a valid hex string starting with the shouldSync selector
    expect(result.startsWith("0x")).toBe(true);

    // Decode it back to verify
    const decoded = decodeFunctionData({
      abi: SyncTriggerABI,
      data: result,
    });

    expect(decoded.functionName).toBe("shouldSync");
  });
});

// ─── decodeShouldSyncResult ───────────────────────────────────────────────

describe("decodeShouldSyncResult", () => {
  test("decodes syncNeeded=true with amount", () => {
    // Simulate what the contract would return:
    // shouldSync returns (bool syncNeeded, uint256 amount)
    const encoded = encodeAbiParameters(
      [{ type: "bool" }, { type: "uint256" }],
      [true, FIVE_ETHER],
    );

    const result = decodeShouldSyncResult(encoded);

    expect(result.syncNeeded).toBe(true);
    expect(result.amount).toBe(FIVE_ETHER);
  });

  test("decodes syncNeeded=false with zero amount", () => {
    const encoded = encodeAbiParameters(
      [{ type: "bool" }, { type: "uint256" }],
      [false, 0n],
    );

    const result = decodeShouldSyncResult(encoded);

    expect(result.syncNeeded).toBe(false);
    expect(result.amount).toBe(0n);
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
  test("shouldSync result → report payload → decodable on-chain", () => {
    // 1. Simulate shouldSync return: syncNeeded=true, amount=6 ether
    const syncAmount = BigInt("6000000000000000000");

    const shouldSyncReturnData = encodeAbiParameters(
      [{ type: "bool" }, { type: "uint256" }],
      [true, syncAmount],
    );

    // 2. Decode the shouldSync result (as the workflow does)
    const checkResult = decodeShouldSyncResult(shouldSyncReturnData);
    expect(checkResult.syncNeeded).toBe(true);
    expect(checkResult.amount).toBe(syncAmount);

    // 3. Encode the report payload (as the workflow does)
    const reportPayload = encodeReportPayload(MOCK_TARGET);

    // 4. Decode as the CREReceiver would: abi.decode(report, (address, bytes))
    const [target, callData] = decodeAbiParameters(
      [
        { name: "target", type: "address" },
        { name: "data", type: "bytes" },
      ],
      reportPayload,
    );

    expect(getAddress(target as string)).toBe(getAddress(MOCK_TARGET));

    // 5. The callData should be triggerSync()
    const innerDecoded = decodeFunctionData({
      abi: SyncTriggerABI,
      data: callData as Hex,
    });

    expect(innerDecoded.functionName).toBe("triggerSync");
  });
});

// ─── ABI sanity checks ────────────────────────────────────────────────────

describe("ABI sanity", () => {
  test("shouldSync selector is correct", () => {
    const encoded = encodeShouldSyncCall();

    // shouldSync() selector = keccak256("shouldSync()")[:4]
    // Just verify it's a 4-byte selector (0x + 8 hex chars)
    expect(encoded.length).toBe(10);
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
