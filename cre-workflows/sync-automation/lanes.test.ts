/**
 * Tests for the consolidated workflow's lane fan-out (lanes.ts).
 *
 * The CRE runtime (EVMClient, Runtime, Runner) is not testable outside the CRE WASM environment, so
 * the config contract and the lane plan — the parts that decide HOW MANY triggers get registered and
 * WHICH chain each one writes to — are kept pure in lanes.ts and asserted here.
 */

import { describe, test, expect } from "bun:test";
// The workflow is ONE file now (main.ts), and its entry autoruns unless `__CRE_NO_AUTORUN` is set.
// Static imports hoist above every statement, so the flag would be set too late — hence the dynamic
// import below. Types come through a type-only import, which is erased and cannot trigger the module.
(globalThis as { __CRE_NO_AUTORUN?: boolean }).__CRE_NO_AUTORUN = true;
import type { Config } from "./main";
const { __test__ } = await import("./main");
const { configSchema, planLanes, CRON_FIELD_COUNT } = __test__;

const RECEIVER = "0x09BdB4E8BA68d245DCb1c6fbEb1e4f13b57cc69A";
const TARGET = "0x871a5cddE9813627Ff37A2895A0c9B117A664622";

const LANES = [
  { chainSelectorName: "ethereum-mainnet-optimism-1", schedule: "0 0 * * * *" },
  { chainSelectorName: "ethereum-mainnet-arbitrum-1", schedule: "0 15 * * * *" },
  { chainSelectorName: "ethereum-mainnet-base-1", schedule: "0 30 * * * *" },
  { chainSelectorName: "ethereum-mainnet-linea-1", schedule: "0 45 * * * *" },
];

const config = (over: Record<string, unknown> = {}) => ({
  receiverAddress: RECEIVER,
  targetAddress: TARGET,
  writeGasLimit: "750000",
  lanes: LANES,
  ...over,
});

describe("configSchema", () => {
  test("accepts the four-lane production shape", () => {
    const parsed = configSchema.parse(config());
    expect(parsed.lanes).toHaveLength(4);
    expect(parsed.lanes.map((l) => l.chainSelectorName)).toEqual(LANES.map((l) => l.chainSelectorName));
  });

  test("rejects a duplicated lane — two triggers would double-write one chain", () => {
    const dup = config({ lanes: [LANES[0], LANES[1], LANES[0]] });
    expect(() => configSchema.parse(dup)).toThrow(/duplicate lane ethereum-mainnet-optimism-1/);
  });

  test("rejects an empty lane list", () => {
    expect(() => configSchema.parse(config({ lanes: [] }))).toThrow(/at least one lane/);
  });

  test(`rejects a 5-field crontab schedule (CRE cron carries ${CRON_FIELD_COUNT} fields incl. seconds)`, () => {
    const fiveField = config({
      lanes: [{ chainSelectorName: "ethereum-mainnet-optimism-1", schedule: "*/5 * * * *" }],
    });
    expect(() => configSchema.parse(fiveField)).toThrow(/6-field CRE cron/);
  });

  test("rejects placeholder / zero receiver and target addresses", () => {
    expect(() => configSchema.parse(config({ receiverAddress: "0xYOUR_CRE_RECEIVER_ADDRESS" }))).toThrow();
    expect(() =>
      configSchema.parse(config({ targetAddress: "0x0000000000000000000000000000000000000000" })),
    ).toThrow();
  });

  test("rejects two lanes sharing one schedule — the stagger is the reason for per-lane triggers", () => {
    const collided = config({
      lanes: [
        LANES[0],
        { chainSelectorName: "ethereum-mainnet-arbitrum-1", schedule: LANES[0].schedule },
      ],
    });
    expect(() => configSchema.parse(collided)).toThrow(/shares the schedule/);
  });

  test("accepts the same schedule written with different spacing only once", () => {
    const respaced = config({
      lanes: [
        LANES[0],
        { chainSelectorName: "ethereum-mainnet-arbitrum-1", schedule: "0  0 * * * *" },
      ],
    });
    expect(() => configSchema.parse(respaced)).toThrow(/shares the schedule/);
  });

  test("rejects a writeGasLimit that is not a plain decimal amount", () => {
    for (const bad of ["750,000", "0.75e6", "0", "750000 ", "", "0x750000"]) {
      expect(() => configSchema.parse(config({ writeGasLimit: bad }))).toThrow(/plain decimal gas amount/);
    }
    expect(configSchema.parse(config({ writeGasLimit: "1200000" })).writeGasLimit).toBe("1200000");
  });

  test("rejects a lane without a chain selector name", () => {
    expect(() => configSchema.parse(config({ lanes: [{ chainSelectorName: "", schedule: "0 0 * * * *" }] }))).toThrow();
  });
});

describe("planLanes", () => {
  test("expands one descriptor per lane, in config order, with the shared addresses folded in", () => {
    const planned = planLanes(configSchema.parse(config()) as Config);
    expect(planned).toHaveLength(4);
    planned.forEach((lane, i) => {
      expect(lane.chainSelectorName).toBe(LANES[i].chainSelectorName);
      expect(lane.schedule).toBe(LANES[i].schedule);
      expect(lane.receiverAddress).toBe(RECEIVER);
      expect(lane.targetAddress).toBe(TARGET);
      expect(lane.writeGasLimit).toBe("750000");
    });
  });

  test("each descriptor is independent — one lane's selector never leaks into another handler", () => {
    const planned = planLanes(configSchema.parse(config()) as Config);
    const selectors = new Set(planned.map((l) => l.chainSelectorName));
    expect(selectors.size).toBe(planned.length);
  });

  test("planLanes re-rejects a duplicated schedule, not only the schema", () => {
    const collided = {
      ...config(),
      lanes: [LANES[0], { chainSelectorName: "ethereum-mainnet-base-1", schedule: LANES[0].schedule }],
    } as Config;
    expect(() => planLanes(collided)).toThrow(/duplicate schedule/);
  });

  test("staggered schedules: no two lanes fire in the same minute-of-hour", () => {
    const planned = planLanes(configSchema.parse(config()) as Config);
    const minutes = planned.map((l) => l.schedule.trim().split(/\s+/)[1]);
    expect(new Set(minutes).size).toBe(planned.length);
  });

  test("re-checks duplicates even if the schema was bypassed", () => {
    // Runner owns config parsing; a looser future SDK must not turn a duplicated lane into two triggers.
    const bypassed = { ...config(), lanes: [LANES[0], LANES[0]] } as unknown as Config;
    expect(() => planLanes(bypassed)).toThrow(/duplicate lane/);
  });

  test("a single-lane config (simulation) plans exactly one handler", () => {
    const one = configSchema.parse(
      config({ lanes: [{ chainSelectorName: "ethereum-mainnet-optimism-1", schedule: "0 */2 * * * *" }] }),
    ) as Config;
    expect(planLanes(one)).toHaveLength(1);
  });

  test("the checked-in simulation config uses the lanes shape", async () => {
    const simulation = await Bun.file(new URL("./config.simulate.json", import.meta.url)).json();
    const parsed = configSchema.parse({ ...simulation, receiverAddress: RECEIVER, targetAddress: TARGET }) as Config;
    expect(planLanes(parsed)).toHaveLength(1);
  });
});
