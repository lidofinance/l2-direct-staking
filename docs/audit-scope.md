# Audit Scope

## Repository-owned contracts

| File | Review focus |
| --- | --- |
| `src/cre/CREReceiver.sol` | Report authentication, metadata parsing, argument-less call authorization, ERC-165, and ownership |
| `src/SyncTrigger.sol` | Timing/amount limits, fee encoding, float accounting, execution, and owner controls |
| `src/cre/interfaces/IReceiver.sol` | Exact receiver interface and selector identity |

The two contracts are non-upgradeable. Solidity version and execution settings
are in `foundry.toml`; dependencies are pinned by Git submodules. Review the actual
revision under assessment rather than relying on recorded test counts or a prior
coverage percentage.

`lib/chainlink-csr` supplies the sender, pool, L1 receiver, adapters, and FeeCodec.
Chainlink infrastructure supplies CCIP and CRE forwarding. OpenZeppelin supplies
ownership, token utilities, and access-control interfaces. These are dependencies,
not repository-authored contracts. Dependency origin alone establishes no audit
coverage or equivalence; SyncTrigger's adapted accounting remains in scope.

## Trust boundaries

[Architecture](../DOC.md#ownership-and-access-control) defines current ownership.
Governance controls sender/L1 admin and proxy upgrades, the LOL Safe controls pool
liquidity, and the Automation Multisig controls the trigger, receiver, and workflow.
A workflow report cannot supply arbitrary arguments to the configured trigger.
The receiver owner can change the allowed call and authentication settings.

The receiver authenticates `(forwarder, workflowOwner)` and intentionally does not
bind workflow name or ID. A different workflow owned by the same author may invoke
the same allowed, argument-less action. Evaluate this as the specified boundary.

## Review checklist

- Reject unauthorized forwarders/authors, short metadata, malformed reports,
  zero targets, and calldata whose length differs from four bytes.
- Require an allowed target/selector and code at a newly allowed target.
  Rejected calls must not emit successful `CallExecuted` evidence.
- Preserve ERC-165 and onReport-only receiver interface IDs. Verify the deployed
  forwarder ABI; a descriptive `typeAndVersion` label is insufficient.
- Restrict trigger execution to its configured forwarder. Recheck timing and
  amount at execution and roll back the timestamp when downstream calls revert.
- Enforce nonzero ordered amount bounds, minimum delay, OtoD exact length, native
  payment, and the configured gas floor/ceiling.
- Keep `getMaxFees()`, `canSync()`, and forwarded native value consistent. Verify
  refund routing and owner-only sweep/withdraw behavior.
- Treat DtoO lane-shape validation as an off-chain obligation: the generic setter
  can accept a blob the selected L1 adapter rejects.
- Keep due-ness separate from local executability and both separate from successful
  CCIP/bridge completion. `canSync()` does not check live fee, RMN, or lane availability.
- Check complete role membership, including explicit revocation assertions for
  obsolete holders. Known-holder reads alone do not prove exclusivity.
- Check each lane's sender, destination, adapter, token, forwarder, and fee codec;
  matching addresses across chains do not make lane configurations interchangeable.
- Verify Safe ownership and registry author agreement without treating registration
  status as proof of DON delivery. Test receiver-side execution separately.

## Validation

Use the [developer guide](development.md#tests-and-consistency-checks) for unit,
workflow, fork, ABI, constant, and state checks. [Compiler checks](compiler-bug-exposure.md)
describe build preconditions. [Fees](fees.md) describes the lane-specific encoding
and measurement limits. Record the revision, toolchain, RPC blocks, and actual
results with the review that relies on them.
