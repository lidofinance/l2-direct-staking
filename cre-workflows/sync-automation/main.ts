/**
 * Lido Direct Staking — CRE Sync Workflow
 *
 * ONE FILE ON PURPOSE. This is the whole workflow: the ABI it calls, the config contract it validates,
 * the lane fan-out, the pure encoders, the per-lane handler and the entry point. It used to be four
 * modules (abi/encoding/lanes/main); they were merged on 2026-08-25 because what gets registered on
 * mainnet is a single compiled artifact whose parameters are only checkable by reading the source that
 * produced it — and a reviewer chasing four files to answer "what does this DON actually do?" is one
 * import away from reviewing something the compiler did not use.
 *
 * ONE registered workflow, FOUR lanes: `initWorkflow` registers one cron trigger per lane, so each lane
 * runs in its own execution with its own time budget and its own failure domain — not one handler
 * looping over four chains, where a stuck lane strands the other three.
 *
 * Flow (per lane, per tick):
 *   CronCapability trigger → read shouldSyncAmount() (due? amount?) + canSync() (executable?) → if both,
 *   encode triggerSync() → sign report → write to CREReceiver → SyncTrigger.triggerSync() →
 *   CustomSender.sync() → CCIP → L1
 *
 * The sections below keep the old module boundary as a rule, not as a filename: everything above
 * "Workflow handler" is pure — no CRE runtime import is used in it — so `bun test` exercises it
 * directly, outside WASM. Only the handler and the entry touch the runtime.
 *
 * The entry is idempotent on purpose — the compiled bundle contains two calls to it (ours and the
 * toolchain's) and must still produce exactly one Runner and one response.
 *
 * ONE EXPORT RULE, enforced by the toolchain: javy turns every ESM export of the entry module into a
 * WASM export and fails the build with "Exported functions with parameters are not supported". While
 * this was four modules the rule was invisible — only `main()` was exported from the entry. In one file
 * it is load-bearing, so nothing here is exported except `main` and the `__test__` bag at the bottom
 * (an object, not a function), and the types, which the compiler erases.
 */

import {
  cre,
  EVMClient,
  getNetwork,
  hexToBase64,
  bytesToHex,
  TxStatus,
  type Runtime,
  Runner,
  encodeCallMsg,
  LATEST_BLOCK_NUMBER,
} from "@chainlink/cre-sdk";
import {
  encodeFunctionData,
  decodeFunctionResult,
  encodeAbiParameters,
  isAddress,
  zeroAddress,
  type Hex,
} from "viem";
import { z } from "zod";

// ─── ABI — SyncTrigger (shouldSyncAmount / canSync / triggerSync) ────────────

const SyncTriggerABI = [
  {
    inputs: [],
    name: "shouldSyncAmount",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "canSync",
    outputs: [{ internalType: "bool", name: "", type: "bool" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "triggerSync",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;

// ─── Config contract + lane fan-out ─────────────────────────────────────────
//
// The per-lane facts are deliberately thin — `chainSelectorName` + `schedule`. `receiverAddress` and
// `targetAddress` are SHARED, because the CREReceiver and SyncTrigger carry the same CREATE2 address
// on every lane. That equality is not assumed silently: `just verify-constants-sync` asserts the four
// <net>.deployed.yaml pairs are identical, and if a future redeploy ever breaks it, that lint fails
// loudly — which is the moment to add per-lane address overrides here, not before.

/**
 * Reject placeholders ("0xYOUR_..."), typos, and the zero address at config-validation time — a bare
 * z.string() lets them through, and they then fail only inside the DON at runtime (viem throws on
 * encode / the eth_call hits an empty account), a silent permanent no-sync.
 */
const evmAddress = z
  .string()
  .refine((a) => isAddress(a, { strict: false }) && a.toLowerCase() !== zeroAddress, {
    message: "must be a 0x-prefixed 20-byte hex EVM address",
  });

/**
 * CRE cron expressions carry a SECONDS field: "0 15 * * * *" is six fields, not the five of ordinary
 * crontab. A five-field expression pasted in from crontab habits (minute-first, no seconds) would be a
 * different schedule — or a load-time error — discovered only inside the DON, so require the count here.
 */
const CRON_FIELD_COUNT = 6;

const laneSchema = z.object({
  /** CRE chain selector name, e.g. "ethereum-mainnet-optimism-1" — one EVMClient is built per lane. */
  chainSelectorName: z.string().min(1),
  /** Six-field cron for THIS lane. Lanes are staggered so the four executions never collide. */
  schedule: z
    .string()
    .refine((s) => s.trim().split(/\s+/).length === CRON_FIELD_COUNT, {
      message: `must be a ${CRON_FIELD_COUNT}-field CRE cron expression (leading seconds field)`,
    }),
});

const configSchema = z.object({
  /** CREReceiver address — identical on every lane (CREATE2). */
  receiverAddress: evmAddress,
  /** SyncTrigger address (shouldSyncAmount/canSync/triggerSync target) — identical on every lane. */
  targetAddress: evmAddress,
  /**
   * Gas limit for the on-chain write transaction, shared by every lane. Shape-checked here, magnitude
   * checked elsewhere: `just verify-constants-sync` pins the VALUE against the measured Solidity
   * constant, but nothing stopped a `"750,000"`, `"0.75e6"` or `"0"` from parsing — and those fail only
   * inside the DON, as a rejected or out-of-gas write on every tick. That is the same silent permanent
   * no-sync the address refine above exists to prevent, so it is rejected at config time too.
   */
  writeGasLimit: z.string().refine((g) => /^[1-9][0-9]*$/.test(g), {
    message: 'must be a plain decimal gas amount with no separators, e.g. "750000"',
  }),
  /** One entry per lane this workflow drives. */
  lanes: z
    .array(laneSchema)
    .min(1, { message: "at least one lane is required" })
    // Two invariants, both cheap to state and both invisible in review once the list grows.
    //
    // A duplicated chainSelectorName would register two cron triggers writing the SAME report to the
    // SAME chain — double syncs, double fees, and a second report that reverts on the rate-limit
    // re-check.
    //
    // A duplicated SCHEDULE is the stagger silently disappearing. The whole reason this workflow uses
    // one trigger per lane is that each lane then gets its own execution and its own time budget;
    // schedules that coincide put all four in the same second, which is the shape this layout was
    // chosen to avoid. It also makes the cron subscriptions identical, and how the DON treats two
    // identical subscriptions is not something this repo has established — an unknown worth refusing
    // rather than discovering in production.
    .superRefine((lanes, ctx) => {
      const seen = new Set<string>();
      const schedules = new Map<string, string>();
      lanes.forEach((lane, i) => {
        if (seen.has(lane.chainSelectorName)) {
          ctx.addIssue({
            code: "custom",
            path: [i, "chainSelectorName"],
            message: `duplicate lane ${lane.chainSelectorName} — one entry per chain selector`,
          });
        }
        seen.add(lane.chainSelectorName);

        const cron = lane.schedule.trim().replace(/\s+/g, " ");
        const twin = schedules.get(cron);
        if (twin !== undefined) {
          ctx.addIssue({
            code: "custom",
            path: [i, "schedule"],
            message: `lane ${lane.chainSelectorName} shares the schedule "${cron}" with ${twin} — stagger the lanes`,
          });
        }
        schedules.set(cron, lane.chainSelectorName);
      });
    }),
});

export type Config = z.infer<typeof configSchema>;
export type Lane = z.infer<typeof laneSchema>;

/** A lane with the shared config folded in — everything one handler needs, nothing it does not. */
export type ResolvedLane = {
  chainSelectorName: string;
  schedule: string;
  receiverAddress: string;
  targetAddress: string;
  writeGasLimit: string;
};

/**
 * Expands the config into one ResolvedLane per lane, in config order (the order the handlers are
 * registered in, and therefore the order the runtime dispatches triggers by index).
 *
 * Re-checks the duplicate-lane invariant rather than trusting that the schema ran: the runner owns
 * config parsing, and a future SDK that validated more loosely would otherwise turn a duplicated
 * lane into two live triggers. Failing here still fails before any trigger is registered.
 */
function planLanes(config: Config): ResolvedLane[] {
  const seen = new Set<string>();
  const schedules = new Set<string>();
  return config.lanes.map((lane) => {
    if (seen.has(lane.chainSelectorName)) {
      throw new Error(`duplicate lane ${lane.chainSelectorName} in config.lanes`);
    }
    seen.add(lane.chainSelectorName);
    const cron = lane.schedule.trim().replace(/\s+/g, " ");
    if (schedules.has(cron)) {
      throw new Error(`duplicate schedule "${cron}" in config.lanes — lanes must be staggered`);
    }
    schedules.add(cron);
    return {
      chainSelectorName: lane.chainSelectorName,
      schedule: lane.schedule,
      receiverAddress: config.receiverAddress,
      targetAddress: config.targetAddress,
      writeGasLimit: config.writeGasLimit,
    };
  });
}

// ─── Pure encoding / decoding — the bridge between ABI and the CRE report ───
//
// No CRE runtime dependency: these are the parts a test can drive directly.

/**
 * Encodes the report payload for CREReceiver.onReport().
 * Layout: abi.encode(address target, bytes data)
 * where `data` is the triggerSync() calldata (no arguments).
 */
function encodeReportPayload(targetAddress: string): Hex {
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
function encodeShouldSyncAmountCall(): Hex {
  return encodeFunctionData({ abi: SyncTriggerABI, functionName: "shouldSyncAmount" });
}

/**
 * Decodes shouldSyncAmount() — the WETH amount a sync would move RIGHT NOW (capped at `maxAmount`), or
 * 0 when a sync is not DUE (the `delay` rate-limit has not elapsed, or the pool holds less than
 * `minAmount`). A nonzero return is both the due-ness signal AND the amount, so one read serves both.
 * Executability is a separate predicate, see {decodeCanSyncResult}.
 */
function decodeShouldSyncAmountResult(data: `0x${string}`): bigint {
  return decodeFunctionResult({
    abi: SyncTriggerABI,
    functionName: "shouldSyncAmount",
    data,
  }) as bigint;
}

// ─── canSync (executability) ────────────────────────────────────────────────

/** Encodes the canSync() call data (no arguments). */
function encodeCanSyncCall(): Hex {
  return encodeFunctionData({ abi: SyncTriggerABI, functionName: "canSync" });
}

/**
 * Decodes canSync() — whether a due sync would actually SUCCEED on-chain right now: the fee float covers
 * getMaxFees(), this trigger still holds SYNC_ROLE, and the OraclePool is not paused. Polled alongside
 * shouldSync so the DON suppresses a due-but-blocked tick instead of submitting a guaranteed-revert report.
 */
function decodeCanSyncResult(data: `0x${string}`): boolean {
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
function decideSyncAction(result: {
  due: boolean;
  executable: boolean;
}): SyncAction {
  if (!result.due) return "no-action";
  return result.executable ? "execute" : "blocked";
}

// ─── Workflow handler (one execution per lane, per tick) ────────────────────

const onLaneTick = (runtime: Runtime<Config>, lane: ResolvedLane): string => {
  // Every log line carries the lane: four handlers share one workflow's log stream, and an
  // un-prefixed "Sync needed" is unattributable once they interleave.
  const log = (msg: string) => runtime.log(`[${lane.chainSelectorName}] ${msg}`);

  log("=== Lido Sync Workflow Started ===");
  log(`Target: ${lane.targetAddress}`);

  // 1. Resolve network
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: lane.chainSelectorName,
  });

  if (!network) {
    throw new Error(`Network not found: ${lane.chainSelectorName}`);
  }

  const evmClient = new EVMClient(network.chainSelector.selector);

  // 2. Probe the two on-chain predicates the DON gates on. A sync proceeds only when it is both DUE
  //    (shouldSyncAmount: nonzero ⇔ delay elapsed + pool WETH >= minAmount, and the value IS the amount)
  //    AND executable (canSync: the fee float, SYNC_ROLE, and pool-pause preconditions that would
  //    otherwise make triggerSync revert). Splitting them lets the DON suppress a due-but-blocked tick
  //    (a silent, signalless stall surfaced off-chain) instead of submitting a guaranteed-revert report
  //    every tick.
  const staticCall = (data: Hex): Hex => {
    const res = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: zeroAddress,
          to: lane.targetAddress as `0x${string}`,
          data,
        }),
        blockNumber: LATEST_BLOCK_NUMBER,
      })
      .result();
    return bytesToHex(res.data);
  };

  log("Calling shouldSyncAmount (is a sync due, and for how much?)...");
  // One read yields both due-ness and the amount: nonzero ⇔ due. Only probe executability when actually
  // due — saves an eth_call on idle ticks.
  const amount = decodeShouldSyncAmountResult(staticCall(encodeShouldSyncAmountCall()));
  const due = amount !== 0n;
  const executable = due ? decodeCanSyncResult(staticCall(encodeCanSyncCall())) : false;

  log(`due=${due} executable=${executable} amount=${amount}`);

  // 3. Route the tick. `decideSyncAction` (pure, unit-tested) maps the two predicates to one of three
  //    terminal branches; only "execute" proceeds to the report path below. "blocked" (due but an
  //    executability precondition is unmet — float / SYNC_ROLE / pool pause) skips rather than submit a
  //    guaranteed-revert report (the stall off-chain monitoring surfaces); "no-action" is simply not
  //    due. A mis-route of a blocked tick into the report path is the exact DON spam this split
  //    prevents — hence the routing lives in a tested pure function.
  const action = decideSyncAction({ due, executable });
  if (action !== "execute") {
    if (action === "blocked") {
      log(
        `Sync due (amount=${amount}) but not currently executable — skipping. ` +
          "Check trigger float, SYNC_ROLE, and pool pause.",
      );
    } else {
      log("No sync needed, skipping.");
    }
    return action;
  }

  // 4. Encode triggerSync report for CREReceiver
  log("Sync needed — encoding triggerSync report...");
  const reportPayload = encodeReportPayload(lane.targetAddress);

  // 5. Sign and send report
  log("Signing report...");
  const reportResponse = runtime
    .report({
      encodedPayload: hexToBase64(reportPayload),
      encoderName: "evm",
      signingAlgo: "ecdsa",
      hashingAlgo: "keccak256",
    })
    .result();

  log("Writing report to CREReceiver...");
  const writeResult = evmClient
    .writeReport(runtime, {
      receiver: lane.receiverAddress,
      report: reportResponse,
      gasConfig: { gasLimit: lane.writeGasLimit },
    })
    .result();

  const rawTxHash = writeResult.txHash;
  log(
    `txHash=${rawTxHash && rawTxHash.length > 0 ? bytesToHex(rawTxHash) : "<none>"} status=${writeResult.txStatus}`,
  );

  if (writeResult.txStatus === TxStatus.SUCCESS) {
    // Never substitute an all-zero hash: a SUCCESS with no txHash reported as 0x000…000 is a hash
    // off-chain monitors would chase on-chain, find nothing at, and then either false-alarm on or
    // silently drop — a blind spot for every successful-but-unmined sync. Fail loudly instead.
    if (!rawTxHash || rawTxHash.length === 0) {
      throw new Error(`writeReport reported SUCCESS (status=${writeResult.txStatus}) but returned no txHash`);
    }
    log("=== Sync Workflow Completed ===");
    return bytesToHex(rawTxHash);
  }

  throw new Error(`Transaction failed: status=${writeResult.txStatus}`);
};

// ─── Entry point ───────────────────────────────────────────────────────────

// One handler per lane. A throw inside one lane's handler fails THAT lane's execution only — which is
// the whole reason the lanes are separate triggers rather than a loop inside one handler.
const initWorkflow = (config: Config) =>
  planLanes(config).map((lane) =>
    cre.handler(
      new cre.capabilities.CronCapability().trigger({ schedule: lane.schedule }),
      (runtime: Runtime<Config>) => onLaneTick(runtime, lane),
    ),
  );

// main() is IDEMPOTENT, and that is a fix for something the build output shows: the compiled bundle ends
// with BOTH the call below and the toolchain's own `main().catch(sendErrorResponse)` (see the tail of
// .cre_build_tmp.js). Two calls used to mean two Runners per execution — two WASI-arg parses and two
// responses for one request. Memoising the promise collapses them into one run while still handing the
// toolchain's catch the same promise, so an error is still reported exactly once.
let running: Promise<void> | null = null;

export function main(): Promise<void> {
  running ??= (async () => {
    const runner = await Runner.newRunner<Config>({ configSchema });
    await runner.run(initWorkflow);
  })();
  return running;
}

// The pure halves, handed to `bun test` as ONE exported object. Not twelve exported functions: javy
// would turn each into a parameterised WASM export and refuse to build (see the header). Nothing in the
// workflow reads this — it exists so the tests can drive the same code the DON runs, from this file.
export const __test__ = {
  SyncTriggerABI,
  evmAddress,
  CRON_FIELD_COUNT,
  laneSchema,
  configSchema,
  planLanes,
  encodeReportPayload,
  encodeShouldSyncAmountCall,
  decodeShouldSyncAmountResult,
  encodeCanSyncCall,
  decodeCanSyncResult,
  decideSyncAction,
};

// Autorun, kept as a FALLBACK rather than as the entry point. The toolchain appends its own
// `main().catch(sendErrorResponse)` to the bundle, so this line is not what starts the workflow on the
// DON — but it costs nothing now that main() is idempotent, and it keeps the module runnable under a
// toolchain that does not append one. The guard is opt-OUT for the same reason: a flag that had to be
// switched ON would let an environment we forgot about load the module, register nothing, and look
// exactly like a workflow that is simply never due. Tests set the flag before importing.
if (!(globalThis as { __CRE_NO_AUTORUN?: boolean }).__CRE_NO_AUTORUN) {
  main();
}
