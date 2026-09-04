# Direct Staking Glamsterdam Readiness Report

> **Status:** engineering assessment; core replay findings independently audited; §5.3 is source- and
> on-chain-evidence checked but not independently replayed; not yet sufficient for governance selection
>
> **Evidence window:** 2026-09-04
>
> **Scope:** Ethereum L1 execution repricing and its effect on Direct Staking sync fee parameters

## TL;DR

### Conclusion

- The Glamsterdam gas prices are **frozen**, not provisional: ACDT #90 fixed the repricing constants and
  ACDE #243 signed the v8.1.0 schedule off as correct and final.
- Foundry/Anvil v1.8.1 can run an `amsterdam` hardfork, but it embeds REVM 42's preliminary devnet-7 gas
  table rather than the frozen devnet-8 schedule. The observed +900 is explained by its stale
  `COLD_STORAGE_ACCESS = 3,000` instead of 2,100. Other stale constants undercharge account-write paths, so
  its result is not uniformly conservative.
- `FeeOtoD.gasLimit` is the Direct Staking parameter exposed to the L1 repricing. The present Optimism value
  of 1,000,000 failed in the available historical replay, whose success boundary was approximately
  1.086M–1.090M under the non-conformant Foundry model.
- **Do not select a production value from that boundary.** The frozen-schedule threshold may be higher or
  lower because the stale storage and account-write prices move in opposite directions. Base, Arbitrum, and
  Linea have not yet been measured equivalently.
- Treat 1.4M only as a validation candidate. CCIP charges for the committed receiver gas limit, so excess
  headroom has a recurring per-sync cost even when execution consumes less gas.
- Glamsterdam alone does not justify increasing `FeeOtoD.maxFee`, `FeeDtoO`, or the SyncTrigger float. Recheck
  them against live CCIP quotes after choosing each lane's receiver limit.
- CCIP or Direct Staking upgrades do not imply an automatic bump, but any change to the Router exact-gas
  helper, receiver, staking path, lane adapter, token pool, or native bridge reopens the measurement.

### Required actions

1. Obtain a test carrier using **REVM 43+** or another client that passes
   `tests-glamsterdam-devnet@v8.1.0`; rerun the cold/warm storage, account-write, value-call, CREATE, refund,
   and access-list probes before trusting its `amsterdam` label.
2. Check in one canonical replay harness with the exact historical message, pre-transaction state manifest,
   receiver proxy, real OffRamp/token-delivery prelude, and event-level success criteria.
3. Binary-search the minimum successful `FeeOtoD.gasLimit` separately for Optimism, Arbitrum, Base, and
   Linea using representative message sizes and the exact deployed CCIP, receiver, adapter, and bridge
   versions intended for production.
4. Repeat the same fixtures under Osaka and the frozen Glamsterdam schedule. Attribute the delta by component
   and retain the deepest nested-call gas observations so EIP-150 failures are visible.
5. Define and approve the sizing policy—required headroom, rounding, maximum acceptable per-sync cost, and
   reopen triggers—then obtain live CCIP quotes and verify lane caps for the candidate values.
6. Only after those checks, update the Solidity constants, encoded state inputs, live `FeeOtoD`, funding, and
   monitoring thresholds in lockstep; verify the encoded on-chain values after execution.
7. Independently monitor CCIP receiver events and `failedHashes`: an outer transaction or CCIP explorer
   “success” is not proof that Direct Staking processing completed.

## Executive conclusion

Foundry and Anvil **v1.8.1 recognize and execute an Amsterdam schedule**, but they are not a conformant
carrier for the finalized Glamsterdam EIP-8038 repricing schedule. Anvil accepts `--hardfork amsterdam`,
and Forge applies Amsterdam-like state repricing, but it embeds REVM's preliminary devnet-7 constants. The
observed +900 cold storage-write delta is exactly the stale 3,000-versus-2,100 cold-storage price; other stale
constants move in the opposite direction, so Foundry v1.8.1 is not uniformly conservative.

Hardhat exposes an experimental Amsterdam mode, but its public release documentation does not establish
EIP-8037/EIP-8038 conformance. It should not be used as the assurance carrier for this fee-limit decision
without equivalent state-access and state-creation probes.

For Direct Staking:

- `FeeOtoD.gasLimit` is the parameter affected by Glamsterdam because it budgets Ethereum L1 execution of
  `LidoCustomReceiver.ccipReceive` and the downstream staking/bridge path.
- The current Optimism value of **1,000,000 fails** for the tested historical message under Foundry v1.8.1's
  Amsterdam model when that value is supplied to the actual receiver-proxy call.
- Two independent replay harnesses placed the success boundary around **1.086M–1.090M**. The small difference
  between harnesses is itself an evidence gap that must be closed with a checked-in canonical carrier.
- Under a policy of keeping the minimum successful external-call envelope below 80% of the configured limit,
  the conservative observed boundary implies approximately **1.363M**. **1.4M is a rounded test candidate, not
  an approved production value.**
- No lane value is governance-ready until the replay uses a runtime matching a pinned current execution-spec
  release. Base, Arbitrum, and Linea additionally need their own exact external-call measurements.
- A normal CCIP ramp upgrade does not imply an automatic receiver-gas bump. Router/exact-call changes and
  upgrades inside the Direct Staking receiver/downstream call path can directly move the threshold; ramp
  changes require remeasurement, while FeeQuoter/config changes primarily reopen quote, cap, and float checks.
- `FeeOtoD.maxFee`, `FeeDtoO`, and the SyncTrigger float do **not** need to be raised solely because of
  Glamsterdam, provided the live CCIP quote remains below the existing monitoring threshold.

## 1. Terminology and parameter boundary

The word "gas limit" refers to several different objects in this flow. They must not be treated as
interchangeable:

| Quantity | Execution domain | Meaning |
|---|---|---|
| `FeeOtoD.gasLimit` | Ethereum L1 | Exact gas CCIP supplies to the external receiver-address call; charged as a commitment |
| Top-level transaction gas limit | Ethereum L1 | Envelope for a normal transaction, including intrinsic gas and outer frames |
| Receiver proxy-call gas | Ethereum L1 | Gas entering the `LidoCustomReceiver` proxy; this is the sizing boundary for `FeeOtoD.gasLimit` |
| Receiver implementation gas | Ethereum L1 | Gas remaining after proxy dispatch; not interchangeable with proxy-call gas |
| `processMessage` call gas | Ethereum L1 | Gas remaining after receiver checks, the 45k failure-handling reservation, and EIP-150 forwarding |
| `FeeDtoO.l2Gas` / `maxGas` | Destination L2 | Native-bridge execution budget on OP/Base/Arbitrum |
| `FeeOtoD.maxFee` | Origin L2 | Refundable upper bound on the CCIP fee quote, not an execution-gas allowance |

The repository-declared values are:

| Lane | `FeeOtoD.gasLimit` | `FeeOtoD.maxFee` | Return-leg setting |
|---|---:|---:|---|
| Optimism | 1,000,000 | 0.125 ETH | `l2Gas = 100,000` |
| Arbitrum | 1,000,000 | 0.125 ETH | `maxGas = 100,000`, fee ≈ 0.001005 ETH |
| Base | 1,000,000 | 0.125 ETH | `l2Gas = 100,000` |
| Linea | 500,000 | 0.125 ETH | zero-fee/nullary encoding |

See [`docs/fees.md`](docs/fees.md) and the per-lane constants in `script/<net>/<Net>MigrationConstants.sol`.

## 2. Glamsterdam rules relevant to Direct Staking

The current repository explanation predates the latest published repricing schedule and needs correction.

### EIP-7904 is not a repricing EIP

[EIP-7904](https://eips.ethereum.org/EIPS/eip-7904) is now informational and explicitly specifies no changes
to the Ethereum gas schedule. It does **not** increase `KECCAK256` or precompile prices. References describing
it as a compute-opcode repricing should be removed.

### The material changes are EIP-8037 and EIP-8038

- [EIP-8037](https://eips.ethereum.org/EIPS/eip-8037) increases and separately meters state-creation costs.
- [EIP-8038](https://eips.ethereum.org/EIPS/eip-8038) changes state-access and state-write pricing.
- `COLD_ACCOUNT_ACCESS` rises from 2,600 to 3,000.
- `COLD_STORAGE_ACCESS` remains 2,100 in the finalized schedule.
- Existing-state writes become materially more expensive.

Both EIPs remain in the editorial **Review** state as of the evidence date, but that status must not be
mistaken for an unresolved pricing decision. [ACD Testing #90](https://eipsinsight.com/calls/acdt/090) froze
the repricing numbers on 2026-08-03: the relative operation costs would no longer change, SLOAD/storage
access remained 2,100, and account writes became 9,000. [ACDE #243](https://eipsinsight.com/calls/acde/243)
then signed off those numbers on 2026-08-13 as correct and final, explicitly confirming that the
`tests-glamsterdam-devnet@v8.1.0` specifications did not need another release with changed repricing values.

The values below are therefore the **frozen Glamsterdam repricing schedule intended for mainnet**, not merely
a provisional development proposal. “Frozen” here applies to the EIP-2780/EIP-8037/EIP-8038 gas constants;
it does not mean that Glamsterdam is already active on mainnet, and it does not collapse the separate fork
activation/configuration decision into the repricing decision. Measurements should pin
`tests-glamsterdam-devnet@v8.1.0` (or a byte-for-byte-equivalent later release), and the assurance claim should
be reopened only if ACD explicitly changes the constants or a later normative execution-spec release differs.

The [Ethereum Foundation testing guidance](https://blog.ethereum.org/2026/08/24/glamsterdam-repricing-testing)
identifies fixed gas limits and nested gas-forwarding assumptions as the main compatibility concern and
recommends testing on the new schedule rather than relying on cached gas constants.

## 3. Tool support

### 3.1 Foundry and Anvil v1.8.1

The installed binaries were:

```text
anvil 1.8.1 (982849d3140c01fd3b72905759581a132df7aa98)
forge 1.8.1 (982849d3140c01fd3b72905759581a132df7aa98)
```

Anvil started successfully with:

```bash
anvil --hardfork amsterdam
```

Forge was checked using differential probes:

| Probe                    |  Osaka | Foundry Amsterdam | Current-spec expectation | Result                                                  |
| ------------------------ | -----: | ----------------: | -----------------------: | ------------------------------------------------------- |
| Cold `BALANCE`           |  2,620 |             3,020 |                    3,020 | Matches `COLD_ACCOUNT_ACCESS`: 2,600 → 3,000            |
| Existing cold-slot write |  5,023 |            13,023 |                   12,123 | **Foundry is +900**                                     |
| New cold-slot write      | 22,123 |           110,943 |                  110,043 | EIP-8037 component appears present; **Foundry is +900** |

This establishes that v1.8.1 does more than recognize the hardfork name, but it also disproves conformance
with the finalized schedule. Starting Anvil proves runtime availability, not schedule conformance.

#### Root cause of the +900 and the wider REVM mismatch

The +900 is not probe overhead or random measurement noise. Foundry v1.8.1 commit
`982849d3140c01fd3b72905759581a132df7aa98` locks `revm` 42.0.1 and the relevant
`revm-primitives`/`revm-context-interface` crates at 42.0.0. That release corresponds to REVM v114's
Glamsterdam devnet-7 implementation. Its gas-table source explicitly calls the values “preliminary draft
values” and sets:

```text
COLD_STORAGE_ACCESS = 3,000
WARM_ACCESS          =   100
STORAGE_WRITE        = 10,000
```

REVM charges the warm base plus the cold premium, so its first cold existing-slot write is:

```text
100 + (3,000 - 100) + 10,000 = 13,000
```

The frozen devnet-8 schedule instead specifies:

```text
100 + (2,100 - 100) + 10,000 = 12,100
```

The probe adds the same 23 gas of measurement scaffolding to each result, yielding **13,023 versus 12,123**.
The new-slot probe also pays the same EIP-8037 state-creation charge in both models, so only this cold-access
term changes and the result is again exactly **+900**. This paired decomposition identifies the stale
`COLD_STORAGE_ACCESS` constant as the cause.

The mismatch is broader than +900 and is not uniformly conservative:

| EIP-8038 quantity | Foundry v1.8.1 / REVM 42 | Frozen schedule / REVM 43 | Foundry minus frozen |
|---|---:|---:|---:|
| `COLD_ACCOUNT_ACCESS` | 3,000 | 3,000 | 0 |
| `ACCOUNT_WRITE` | 8,000 | 9,000 | **−1,000** |
| `COLD_STORAGE_ACCESS` | 3,000 | 2,100 | **+900** |
| `STORAGE_WRITE` | 10,000 | 10,000 | 0 |
| `STORAGE_CLEAR_REFUND` | 12,480 | 11,616 | **+864 refund** |
| `CREATE_ACCESS` | 11,000 | 12,000 | **−1,000** |
| `ACCESS_LIST_ADDRESS_COST` | 3,000 | 2,900 | **+100** |
| `ACCESS_LIST_STORAGE_KEY_COST` | 3,000 | 2,000 | **+1,000** |
| value-bearing `CALL_VALUE` | 10,300 | 11,300 | **−1,000** |

Thus the historical Direct Staking threshold cannot be corrected by simply subtracting 900. Relative to the
frozen schedule, Foundry overcharges each first cold storage-slot touch but undercharges account writes and
value-bearing calls. Refunds, access-list use, CREATE paths, and EIP-150 at nested call boundaries can further
change the whole-path result. The sign and size of the receiver-threshold error require a conformant replay or
an opcode/event census of the exact trace; the existing 1.086M–1.090M result is neither a safe upper nor lower
bound solely from this evidence.

The implementation has already been corrected upstream: [REVM PR #3850](https://github.com/bluealloy/revm/pull/3850)
changed the devnet-7 constants to the devnet-8/frozen values, and [REVM v116](https://github.com/bluealloy/revm/releases/tag/v116)
released them in the 43.0.0 crates after passing the v8.1.0 execution-spec tests. However, both the installed
Foundry v1.8.1 lock and Foundry's `master` lock as checked on 2026-09-04 still use REVM 42. A Foundry build is
not a conformant carrier until its own dependency lock moves to REVM 43+ and the local probes pass; REVM's
upstream fix alone does not change the installed binaries.

PR #3850 also adjusts EIP-2780 transaction-level accounting. Those intrinsic/top-level changes are outside
the `FeeOtoD.gasLimit` receiver-call boundary, but they are another reason not to use Foundry v1.8.1 for
full destination-transaction gas comparisons against the frozen schedule.

The repository now compiles for the latest Solidity-supported bytecode target and executes tests with the
Amsterdam runtime in [`foundry.toml`](foundry.toml):

```toml
evm_version = "osaka"
hardfork = "amsterdam"
```

These are deliberately separate settings in Foundry v1.8.1: `evm_version` controls the compiler target,
while `hardfork` controls the Forge runtime and its gas schedule. Foundry currently normalizes an unsupported
`evm_version = "amsterdam"` back to Osaka, so that spelling must not be used as the runtime switch.

An ordinary `forge test` or `just measure-fee-gas` invocation now measures **Foundry v1.8.1's Amsterdam
model**, not the finalized Glamsterdam repricing schedule exactly. Use an environment override only when an
Osaka runtime comparison is required:

```bash
FOUNDRY_HARDFORK=osaka forge test ...
```

The global Amsterdam runtime setting also applies while Forge operates on L2 forks. Optimism, Base,
Arbitrum, and Linea do not automatically inherit Ethereum L1's hardfork schedule. Gas-sensitive fork work
must therefore use explicit L1 and per-L2 profiles instead of treating one runtime as valid for every chain.

### 3.2 Hardhat

[Hardhat v3.12](https://github.com/NomicFoundation/hardhat/releases) introduced experimental Amsterdam
support, but its release notes explicitly demonstrate only EIP-7843 (`SLOTNUM`). Hardhat 3.15 ships EDR
0.19, while Hardhat 2.29.1 ships an older prerelease EDR line.

This is not enough evidence to assert conformance with the finalized EIP-8037/EIP-8038 schedule.
Before using Hardhat gas measurements for governance decisions, reproduce the probes above and compare them
with a pinned execution-spec release.

## 4. Repository test limitation

The current real-adapter carrier in
[`test/helpers/PoolUpgradeTests.sol`](test/helpers/PoolUpgradeTests.sol) measures the existing schedule and
then applies a fixed projection:

```solidity
measuredGas * 125 <= gasLimit * 100
```

This is useful as a planning heuristic, but it is not a faithful Glamsterdam test:

1. The `×1.25` factor came from an older repricing model.
2. It does not reproduce EIP-8037's separate state-gas behavior.
3. Total gas consumed does not by itself establish that sufficient gas reaches the deepest nested bridge
   call.

An attempted Amsterdam run of `just measure-fee-gas` was also blocked by the test's lifecycle precondition:
the configured canary contracts have already been handed off/sealed, while `_bindCanaryL2` requires a
deployer-owned Stage-1 canary. This is a harness-state problem, not an Amsterdam execution failure.

The carrier should ultimately execute the full path twice—Osaka and Amsterdam—and assert both completion and
an explicit entry-gas margin under Amsterdam.

## 5. Optimism historical replay

The successful recovery transaction used for the replay was:

- [`0x63d2499e…459ba`](https://etherscan.io/tx/0x63d2499ece4bf5af6c3e4e995353f8882cfa3ca3a36e5dcf3dd446bfb72459ba)
- message ID: `0xf478341ddbcd2d3ade47c6bd1dd9d619dc2719e6862515337c05085cf976b07f`
- return-leg `l2Gas`: 100,000

The transaction was replayed locally against Ethereum state at prior block **25,904,754**. The original
transaction was index 213 in block 25,904,755, so prior-block state is not proven identical to exact
pre-transaction state unless the preceding block transactions are replayed.

| Run | Outcome | Gas used |
|---|---|---:|
| Historical Osaka transaction, original 1,002,804 envelope | Success | 670,227 |
| Foundry Amsterdam replay, original envelope | Failure | not a completed-path measurement |
| Foundry Amsterdam replay, enlarged 2M envelope | Success | 760,597 |
| Completed-path difference | — | **+90,370 (+13.5%)** |

The completed-path delta is below 25% on this sample. That does not prove a `×1.25` envelope safe: the
original envelope still fails because total consumed gas and gas forwardable through nested frames are
different quantities.

### 5.1 External receiver-proxy gas threshold

The `Any2EVMMessage` was reconstructed from the retry calldata and delivered to the real receiver proxy from
the real Chainlink router address under Foundry's Amsterdam model. The receiver's own events distinguish a
caught internal failure from successful processing.

Two independent exact-call harnesses produced nearby but non-identical boundaries:

| Harness | Highest observed failure | Lowest observed success |
|---|---:|---:|
| Independent subagent replay | 1,085,625 | 1,086,250 |
| Primary replay | 1,087,500 | 1,090,000 |

Both reproduced `MessageFailed` at **1,000,000**. The discrepancy between harnesses must be resolved by a
checked-in replay script with a pinned state manifest; it must not be hidden by selecting the lower result.
For conservative arithmetic in this report, 1,090,000 is used as the observed boundary.

The previous 951k–961k result appears to have measured a deeper internal frame and mislabeled it as external
receiver-entry gas. It is not the quantity CCIP's configured receiver `gasLimit` supplies.

The gap between completed gas and required entry gas is expected. `ccipReceive` reserves gas for its
defensive catch, calls `processMessage` through another frame, and eventually traverses several proxy and
bridge calls. EIP-150 retains 1/64 of gas at each nested call. A deep call can therefore lack enough
forwardable gas even though the eventual successful execution consumes much less than the original envelope.

### 5.2 Meaning for the current 1M setting

For the observed Optimism message under Foundry v1.8.1's Amsterdam model:

```text
configured CCIP receiver gas = 1,000,000
observed success threshold   ≈ 1,086,000–1,090,000
result at configured limit   = MessageFailed
```

The current value is therefore inadequate for this replay. This is stronger than a low-headroom warning but
still narrower than a production-readiness conclusion because the runtime schedule is not current-spec
conformant and only one small historical OP message was tested.

This is a counterfactual replay, not an observation from post-Glamsterdam Ethereum mainnet. It should be
rerun with a client matching the pinned current execution-spec test release and with representative
production messages before any governance action is executed.

### 5.3 CCIP upgrade surfaces that can change gas

"A CCIP upgrade changed the gas" is too broad to support a parameter decision. FPF A.6.P requires the
changed component and the affected quantity to be named. FPF C.28 then requires a plausible causal path
from that change to the measured outcome. For this report, the relevant outcomes are separate:

1. the minimum external gas envelope that makes `LidoCustomReceiver.ccipReceive` emit
   `MessageSucceeded`;
2. the gas consumed by the complete destination execution transaction before, during, and after the
   receiver call;
3. the source-chain CCIP fee quote and maximum accepted message gas.

An upgrade may change one without changing the others.

#### Chainlink's ramp upgrade mechanism

For the deployed Ethereum Router used by Direct Staking, a normal CCIP lane upgrade is an **address-level
ramp change**, not evidence that one proxy implementation changed in place. The Router's owner can add and
remove `(sourceChainSelector, OffRamp)` pairs with `applyRampUpdates`; several OffRamp generations can be
enabled for the same source selector during a migration. The Direct Staking receiver, in contrast, is a
transparent proxy, and its implementation embeds `CCIP_ROUTER` as an immutable.

Read-only calls pinned to Ethereum block **25,905,594** on 2026-09-04 returned `Router 1.2.0` at
[`0x8022…f7D`](https://etherscan.io/address/0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D#readContract) and the
following enabled OffRamp generations for the four source selectors:

| Source lane | Enabled Ethereum OffRamps: `typeAndVersion` and address |
|---|---|
| Optimism | `EVM2EVMOffRamp 1.2.0` [`0xB095…0BF7`](https://etherscan.io/address/0xB095900fB91db00E6abD247A5A5AD1cee3F20BF7); `EVM2EVMOffRamp 1.5.0` [`0x562a…D3B`](https://etherscan.io/address/0x562a2025E60AA19Aa03Ea41D70ea1FD3286d1D3B); `OffRamp 2.0.0` [`0x4084…17c3`](https://etherscan.io/address/0x408428bca0e24A25ac8baAc1b70f64AF257717c3) |
| Arbitrum | `EVM2EVMOffRamp 1.2.0` [`0xeFC4…6F4d`](https://etherscan.io/address/0xeFC4a18af59398FF23bfe7325F2401aD44286F4d); `EVM2EVMOffRamp 1.5.0` [`0xdf61…5aC9`](https://etherscan.io/address/0xdf615eF8D4C64d0ED8Fd7824BBEd2f6a10245aC9); `OffRamp 1.6.0` [`0x26d3…73C5`](https://etherscan.io/address/0x26d3681DfC9E4c8C79cfbf461adec8A21d5d73C5); `OffRamp 2.0.0` [`0x4084…17c3`](https://etherscan.io/address/0x408428bca0e24A25ac8baAc1b70f64AF257717c3) |
| Base | `EVM2EVMOffRamp 1.2.0` [`0xdf85…dfb3`](https://etherscan.io/address/0xdf85c8381954694E74abD07488f452b4c2Cddfb3); `EVM2EVMOffRamp 1.5.0` [`0x6B4B…9EbD`](https://etherscan.io/address/0x6B4B6359Dd5B47Cdb030E5921456D2a0625a9EbD); `OffRamp 1.6.0` [`0x26d3…73C5`](https://etherscan.io/address/0x26d3681DfC9E4c8C79cfbf461adec8A21d5d73C5) |
| Linea | `EVM2EVMOffRamp 1.5.0` [`0x418d…FBB4`](https://etherscan.io/address/0x418dcbCf229897d0CCf1B8B464Db06C23879FBB4) |

This table describes Router authorization, not which version will execute every future message. A replay
must identify the OffRamp that committed and executes the particular message; selecting a version only from
the source selector would collapse concurrent migration paths.

#### Causal influence matrix

| Upgrade or reconfiguration surface | Receiver success threshold | Complete destination tx gas | Quote / accepted limit | Causal mechanism and required response |
|---|---|---|---|---|
| Ethereum `Router` or its exact-gas call helper | **Directly capable** | **Yes** | No direct source-lane effect | `Router.routeMessage` constructs the `ccipReceive` calldata and `CallWithExactGas` supplies the declared `gasLimit`. A change to calldata construction, EIP-150 check, return-data handling, or gas passed to the `CALL` invalidates the exact-call carrier. Re-run threshold tests. A Router address change also requires a compatible receiver implementation because `CCIP_ROUTER` is immutable in that implementation. |
| Ethereum OffRamp generation or dynamic config | **Indirectly capable** | **Yes** | Normally no | The OffRamp releases/mints tokens, may run an interceptor and interface checks, constructs `Any2EVMMessage`, and asks the Router to call the receiver. With unchanged normalized message and exact-gas semantics, its own proof and bookkeeping cost is outside the receiver allowance. It can nevertheless change callback gas through pre-call warm/cold state, token delivery state, or message contents. Replay each active OffRamp generation with its real prelude. |
| Token pool, Token Admin Registry, transferred-token implementation, or inbound message interceptor | **Indirectly capable** | **Yes** | Token fees may change | These execute before `ccipReceive`. A different token-delivery path can change the token/address/storage state already touched in the transaction and the `destTokenAmounts` supplied to the receiver. Preserve the real WETH delivery path in the replay; a direct receiver call alone cannot establish this equivalence. |
| RMN, OCR configuration, commit/root verification, nonce tracking, report batching | No, **if the same exact receiver call is reached** | **Yes** | Normally no | These determine authorization, proof work, ordering, batching, and whether execution reaches the callback. They can raise the relayer transaction envelope or stop delivery, but their gas is not taken from `FeeOtoD.gasLimit` once the Router supplies that limit exactly. Monitor outer execution separately. |
| Source L2 Router / OnRamp / message codec | Only through a changed normalized message | Source tx only; possibly destination decoding | **Yes** | The OnRamp validates and serializes `gasLimit`, payload, and token data. A compatible upgrade that preserves those receiver-visible values does not itself make the L1 callback more expensive. A changed payload length, token list, receiver ABI, or normalized message does; replay the resulting message rather than the old fixture. |
| Source L2 FeeQuoter, price feeds, fee multipliers, overhead constants, or `maxPerMsgGasLimit` | **No** | No | **Directly capable** | These change what the same committed `gasLimit` costs and whether it is accepted. They can force a `maxFee` or repository-guard decision without changing the L1 receiver threshold. Compare live quotes and caps; do not infer receiver gas from price movement. |
| Direct Staking `LidoCustomReceiver` proxy implementation or its CCIP defensive base | **Directly capable** | **Yes** | Only after a selected limit changes | Changes to router/sender checks, reentrancy guard, the 45k failure reserve, `try/catch`, failure hashing/storage, proxy dispatch, `_processMessage`, or compiler output directly change the bounded code. Re-run all lane thresholds after every implementation upgrade. |
| Lido staking/wstETH contracts, lane adapter, or native L1→L2 bridge reached by `_processMessage` | **Directly capable** | **Yes** | No direct CCIP quote-rule effect | These calls are inside the receiver allowance. Proxy implementation upgrades, bridge changes, or adapter replacement can change storage access, call depth, return data, and EIP-150 headroom even when CCIP itself is unchanged. Re-run the affected real-adapter lane. |

The practical result is that an OffRamp, RMN, or OCR upgrade does **not** justify an automatic
`FeeOtoD.gasLimit` bump. It creates a remeasurement obligation. A bump is justified only when a controlled
replay shows that the minimum successful external receiver-call envelope increased. FeeQuoter or price
configuration changes instead reopen `maxFee`, float, and cap checks. Receiver, staking, adapter, and native
bridge upgrades are the highest-risk surfaces for the receiver limit because their work occurs inside the
bounded call.

#### How to attribute an observed change

A before/after mainnet comparison across different blocks cannot isolate a CCIP upgrade from Glamsterdam,
message size, amount-dependent storage transitions, or ordinary state drift. Use a paired counterfactual:

```text
same fork state + same message + old component/config -> threshold_old
same fork state + same message + new component/config -> threshold_new

upgrade-attributed delta = threshold_new - threshold_old
```

Repeat that pair under Osaka and the pinned Glamsterdam schedule. This separates the CCIP-version effect,
the hardfork effect, and their interaction. Record the source OnRamp/FeeQuoter, destination Router and
executing OffRamp, token pool, receiver implementation, adapter, downstream bridge implementations, block,
message bytes, and warm-up prelude. Measure both the Router-reported receiver-call gas and a binary-searched
`MessageSucceeded` boundary; neither the outer transaction status nor the CCIP explorer's success label is a
sufficient witness.

FPF B.3 assurance disposition: the direct Router/exact-gas and vendored v1.6-era OffRamp paths are supported
by the repository-pinned Chainlink source, and the enabled-version table is supported by dated on-chain
reads. The effect of the enabled v2.0 implementation is **unresolved until its exact deployed source/config
and a paired replay are captured**. This section supports the causal classification and test design; it does
not support a numerical bump. Reopen it on any Router/ramp registration event, component `typeAndVersion` change,
receiver or downstream implementation upgrade, message-shape change, or hardfork schedule revision. This
applies A.6.P's exact-participant and changed-object discipline, C.28 checklist items 1, 3, 4, 7, and 8
for the counterfactual contrast and confounder controls, and `CC-B3-2`, `CC-B3-6`, `CC-B3-10`, and
`CC-B3-12`.

## 6. Parameter decision status

### 6.1 `FeeOtoD.gasLimit`

If the project explicitly adopts a policy that the minimum successful external-call envelope must be no more
than 80% of the configured limit, the conservative observed threshold gives:

```text
1,090,000 / 0.80 = 1,362,500
```

This is not the same metric as the existing monitoring rule `completed ccipReceive gas / gasLimit < 80%`.
The threshold-based rule may be safer, but it must be adopted explicitly rather than attributed to the
existing policy.

Current disposition:

| Lane | Repository value | Evidence disposition | Candidate status |
|---|---:|---|---|
| Optimism | 1,000,000 | Fails the tested Foundry-Amsterdam external-call replay | 1.4M is a non-governance test candidate |
| Base | 1,000,000 | Unresolved; no exact lane replay | No value selected |
| Arbitrum | 1,000,000 | Unresolved; no exact lane replay | No value selected |
| Linea | 500,000 | Unresolved; no exact lane replay | No value selected |

Repository guards and live CCIP caps are separate quantities. Read-only checks on 2026-09-04 found:

| Lane | Repository `SyncTrigger` guard | Live CCIP cap |
|---|---:|---:|
| Optimism | 7M | 15M |
| Arbitrum | 7M | 15M |
| Base | 7M | 7M |
| Linea | 3M | 3M |

Any selected value must satisfy both the repository guard and the then-live CCIP cap.

Because CCIP charges for the committed receiver `gasLimit`, unused headroom creates a recurring cost. The
selection should therefore be based on measured execution plus a declared margin, rather than an arbitrarily
large value.

### 6.2 Cost of setting `FeeOtoD.gasLimit` above the required value

The economic rule is simple: **CCIP prices the committed receiver `gasLimit`, not the gas ultimately
consumed by the successful receiver execution. Unused committed gas is not refunded.** This follows both
the [CCIP billing model](https://docs.chain.link/ccip/billing) and the vendored FeeQuoter calculation. For an
otherwise unchanged message and quote state, the marginal fee is linear in the configured limit:

```text
incremental actual fee
  ≈ added gasLimit
    × destination execution gas price
    × lane gas multiplier
    ÷ fee-token price
```

Here the fee token is the originating L2's native ETH. The exact coefficient is lane-owned and changes with
the price inputs and FeeQuoter configuration, so the authoritative cost at decision time is the difference
between two live `Router.getFee()` quotes for the same message, changing only `gasLimit`.

FPF A.6.P and C.16 require two different baselines to remain separate:

| Comparison | What it measures | May it be called avoidable slack? |
|---|---|---|
| configured limit − completed-path gas used | Includes gas that must exist at receiver entry so enough gas survives proxy calls, reservations, and EIP-150 forwarding | **No** |
| configured limit − minimum successful external receiver-call envelope | Commitment above the observed success boundary under the named runtime and state | **Yes, within that evidence scope** |

For the tested Optimism replay, completed execution consumed **760,597**, while the external receiver call
needed approximately **1.086M–1.090M** to succeed. Consequently, describing `1.4M − 760,597` as waste would
be incorrect. Using the conservative observed boundary, the candidate's measured-model discretionary slack
is instead approximately:

```text
1,400,000 − 1,090,000 = 310,000 gas
```

The repository's [live-quote snapshot](docs/fees.md#feeotodgaslimit-you-pay-for-the-commitment-and-above-the-lane-cap-you-halt)
from 2026-06-02 measured the following marginal prices. These are historical coefficients, not
post-Glamsterdam forecasts:

| Lane | Approximate added fee per +100k committed gas |
|---|---:|
| Optimism | 0.00024 ETH/sync |
| Arbitrum | 0.00030 ETH/sync |
| Base | 0.00023 ETH/sync |
| Linea | 0.00020 ETH/sync |

At the Optimism snapshot coefficient:

- changing the repository value from 1.0M to the 1.4M test candidate would add approximately **0.00096
  ETH per sync**;
- the 310k above the conservative observed success boundary would account for approximately **0.000744 ETH
  per sync**;
- at the maximum planned cadence of two paid syncs per day, that latter slack would be approximately
  **0.001488 ETH/day or 0.543 ETH/year**, if the lane ran at that cadence and the quote coefficient remained
  unchanged.

These figures describe the marginal execution commitment only. The total CCIP quote also contains fixed
execution overhead and a token-transfer premium, so a 40% increase in `gasLimit` does **not** imply a 40%
increase in the total fee. The live two-quote difference is the correct measurement.

The payment and refund consequences are:

- if the larger quote remains at or below `maxFee`, the Router charges the larger actual fee on every sync;
  the SyncTrigger receives a smaller `maxFee − actualFee` refund and its float drains faster;
- leaving `maxFee` unchanged leaves `getMaxFees()` and the hard pre-flight balance floor unchanged, but it
  does not make the added gas commitment free;
- raising `maxFee` alone does not add per-sync cost because its unused portion is refunded, although it raises
  the required float and the maximum fee one sync can authorize;
- if the quote exceeds `maxFee`, the send reverts without paying the CCIP fee; if `gasLimit` exceeds a
  repository guard or live lane cap, configuration or quoting fails instead of purchasing more safety;
- an oversized limit also lowers the monitored `gas used / gasLimit` ratio and can mask execution-cost drift.

FPF B.3 assurance disposition: the billing relation and linear direction are supported by the vendored
FeeQuoter and sender implementation. The ETH examples are supported only as calculations from the dated
quote slopes. They must not be used as a deployment budget without fresh per-lane quotes; a changed gas
price, price feed, multiplier, message amount, or FeeQuoter configuration reopens them. This applies
A.6.P checklist items 2, 8, and 11; C.16 checklist items 1–3 and 7–9; and `CC-B3-2`, `CC-B3-3`,
`CC-B3-5`, and `CC-B3-12`.

### 6.3 `FeeOtoD.maxFee`

No automatic bump is indicated.

`maxFee` is a refundable quote ceiling. Increasing `gasLimit` raises the actual CCIP quote. Retain 0.125 ETH
initially, but verify a live router quote using whichever `gasLimit` is subsequently selected and retain the
cap only while that quote remains below the repository's existing 80% threshold.

If `maxFee` is changed, the SyncTrigger must be funded to at least:

```text
FeeOtoD.maxFee + FeeDtoO.feeAmount
```

### 6.4 `FeeDtoO`

Do not increase `FeeDtoO` merely because Ethereum activates Glamsterdam:

- OP/Base `l2Gas` budgets L2 execution.
- Arbitrum `maxGas` budgets the retryable's L2 execution.
- Linea has no corresponding adjustable gas value in its encoding.

OP/Base have an indirect coupling: their `l2Gas` allowance causes L1 resource-metering work inside the
portal and therefore consumes `FeeOtoD.gasLimit`. Unnecessary `FeeDtoO.l2Gas` slack makes the L1 problem
worse and should not be used as Glamsterdam insurance.

## 7. Recommended validation and rollout

1. Pin an execution-spec test release and a client/runtime whose gas schedule matches the opcode probes;
   do not use the `amsterdam` label or `measured × 1.25` as the primary assertion.
2. Make the carrier runnable independently of a still-deployer-owned canary, or provide a reproducible
   temporary Stage-1 fixture.
3. Check in the opcode probes, historical replay carrier, fork/state manifest, calldata or message fixture,
   and expected event-level outcomes so the evidence is reproducible.
4. Inventory the exact source OnRamp/FeeQuoter, destination Router and enabled/executing OffRamp, token
   pool, receiver implementation, adapter, and downstream bridge implementations for every fixture.
5. Replay representative successful messages for all four lanes under the runtime appropriate to each
   source and destination chain, using current return-leg fee data and the real OffRamp/token-delivery
   prelude.
6. For each lane, binary-search the smallest gas supplied at the external receiver proxy that produces
   `MessageSucceeded`, not merely a successful outer CCIP transaction.
7. Apply `ceil(minimum successful entry gas / 0.80)` only if the project explicitly approves this as a new
   sizing rule; otherwise declare and justify a different margin policy.
8. Quote the proposed message through each live CCIP router and confirm:
   - actual fee / `maxFee` < 80%;
   - proposed `gasLimit` ≤ live `maxPerMsgGasLimit`;
   - SyncTrigger balance ≥ `getMaxFees()`.
9. Update in lockstep:
   - `script/<net>/<Net>MigrationConstants.sol`;
   - `config/state/<net>.inputs.yaml` encoded `feeOtoD` anchor;
   - the live SyncTrigger through owner-only `setFeeOtoD`;
   - documentation and monitoring thresholds.
10. Verify the live encoded bytes through state-mate and `just verify-constants-sync`.

## 8. FPF reasoning record

This assessment uses four FPF controls:

- **A.6.P — relational precision restoration:** separates the CCIP receiver commitment, transaction
  envelope, nested-call forwarding capacity, return-leg gas, and fee cap rather than calling all of them
  "gas limits."
- **B.3 — evidence and assurance:** distinguishes EIP editorial metadata, an ACD decision freezing constants,
  normative test/spec artifacts, recognition of the `amsterdam` label, opcode-level conformance, whole-path
  replay, and live production assurance. The ACD evidence establishes that the prices are final, while the
  local probes find a Foundry storage-cost mismatch and therefore do not support a governance-ready limit.
- **C.28 — causal-use boundary:** treats the Amsterdam historical replay as a counterfactual simulation
  against prior-block state under a named tool model. It supports the bounded finding that the current OP
  limit fails in that model, but it is neither exact pre-transaction reconstruction nor observed post-fork
  production behavior. It also separates upgrades that change receiver-call execution from upgrades that
  change only outer CCIP work or quote configuration, and requires paired old/new replays to attribute a
  delta.
- **C.16 — characteristic and measurement discipline:** gives each cost quantity a bearer, scale, unit, and
  evidence window. In particular, completed gas, minimum successful entry gas, configured gas, actual CCIP
  fee, and refundable `maxFee` excess are not combined into one unlabeled utilization or "waste" number.

The B.3 assurance result is:

| Field | Assessment |
|---|---|
| Target claim | The report supports selecting 1.2M–1.25M for Optimism and retaining the other lanes |
| Intended use | Governance, configuration, and deployment approval |
| Disposition | **Unsupported by the current evidence** |
| Supported narrower claim | The tested OP message fails at 1M in Foundry v1.8.1's Amsterdam model; every lane needs an exact, reproducible measurement |
| Unsupported claims | Approval of 1.2M/1.25M, preservation of a 20% margin, and no-change conclusions for Base, Arbitrum, or Linea |
| Evidence required to reopen | A pinned conformant runtime, checked-in carrier and state manifest, representative per-lane thresholds, and current live quotes, caps, and deployed values |

The resulting claim classes are:

| Class | Claim |
|---|---|
| Protocol fact | ACDT #90 froze and ACDE #243 finalized the Glamsterdam EIP-2780/EIP-8037/EIP-8038 gas constants; the material state repricings are EIP-8037/EIP-8038, while EIP-7904 is informational |
| Repository declaration | Current runtime is Amsterdam; receiver limits are 1M/1M/1M/500k per lane |
| Empirical evidence | Foundry v1.8.1 embeds REVM 42's preliminary devnet-7 EIP-8038 table: the +900 probes are caused by its stale cold-storage price, while other constants undercharge final account-write paths; the tested OP receiver fails at 1M and succeeds near 1.086M–1.090M only in that non-conformant model |
| Bounded inference | The present OP setting is inadequate in the tested model; the differing harness thresholds and non-conformant runtime prevent an exact production value |
| Decision recommendation | Do not approve a production bump from this report yet; establish a conformant, reproducible per-lane measurement and an explicit sizing policy first |

## 9. Sources

- [Ethereum Foundation: Glamsterdam repricing impact and testing](https://blog.ethereum.org/2026/08/24/glamsterdam-repricing-testing)
- [ACD Testing #90: repricing numbers frozen (2026-08-03)](https://eipsinsight.com/calls/acdt/090)
- [Official ACD Testing #90 agenda](https://github.com/ethereum/pm/issues/2174)
- [ACDE #243: repricing numbers signed off as correct and final (2026-08-13)](https://eipsinsight.com/calls/acde/243)
- [Official ACDE #243 agenda](https://github.com/ethereum/pm/issues/2178)
- [EIP-8007: Glamsterdam Meta](https://eips.ethereum.org/EIPS/eip-8007)
- [EIP-7904: Compute Gas Cost Analysis](https://eips.ethereum.org/EIPS/eip-7904)
- [EIP-8037: State Creation Gas Cost Increase](https://eips.ethereum.org/EIPS/eip-8037)
- [EIP-8038: State-access gas cost update](https://eips.ethereum.org/EIPS/eip-8038)
- [Glamsterdam execution-spec test releases](https://github.com/ethereum/execution-specs/releases)
- [Foundry releases](https://github.com/foundry-rs/foundry/releases)
- [Foundry v1.8.1 commit: dependency lock](https://github.com/foundry-rs/foundry/blob/982849d3140c01fd3b72905759581a132df7aa98/Cargo.lock)
- [REVM v114 / 42.0.0 preliminary EIP-8038 constants](https://github.com/bluealloy/revm/blob/v114/crates/primitives/src/eip8038.rs)
- [REVM PR #3850: devnet-8 gas repricing](https://github.com/bluealloy/revm/pull/3850)
- [REVM v116 / 43.0.0: Glamsterdam devnet-8 alignment](https://github.com/bluealloy/revm/releases/tag/v116)
- [Hardhat releases](https://github.com/NomicFoundation/hardhat/releases)
- [Chainlink CCIP billing](https://docs.chain.link/ccip/billing)
- [Chainlink CCIP receiver `gasLimit` guidance](https://docs.chain.link/ccip/tutorials/evm/ccipreceive-gaslimit)
- [Chainlink CCIP Router source pinned by this repository](https://github.com/smartcontractkit/ccip/blob/eb419a097bd11846ff2d82d25c447eee1f911b38/contracts/src/v0.8/ccip/Router.sol)
- [Chainlink `CallWithExactGas` source pinned by this repository](https://github.com/smartcontractkit/ccip/blob/eb419a097bd11846ff2d82d25c447eee1f911b38/contracts/src/v0.8/shared/call/CallWithExactGas.sol)
- [Chainlink v1.6 OffRamp source pinned by this repository](https://github.com/smartcontractkit/ccip/blob/eb419a097bd11846ff2d82d25c447eee1f911b38/contracts/src/v0.8/ccip/offRamp/OffRamp.sol)
- [Chainlink v1.6 FeeQuoter source pinned by this repository](https://github.com/smartcontractkit/ccip/blob/eb419a097bd11846ff2d82d25c447eee1f911b38/contracts/src/v0.8/ccip/FeeQuoter.sol)
- [`docs/fees.md`](docs/fees.md)
- [`DOC.md` §5.2](DOC.md#52-fee-parameters-per-chain--and-why-they-are-set-this-way)
- [`docs/monitoring.md`](docs/monitoring.md)
