# Compiler and Build Checks

The repository pins Solidity 0.8.34 and EVM target `osaka` in `foundry.toml`.
Use resolved configuration and artifact metadata to check the build actually used;
a version pin alone does not establish compiler-bug exposure or deployed-code identity.

## Conditions checked

The existing guard covers two named compiler-bug conditions:

| Bug | Relevant exclusion checked here |
| --- | --- |
| `InheritanceOrderReversalOnStorageEndWarning` | No custom `layout at` specifier in the compilation closure and no storage-end warning |
| `UnsoundSpillInMutualRecursion` | IR pipeline disabled (`via_ir = false`) |

These are narrow conditions for SyncTrigger and CREReceiver, not a statement that
the compiler has no bugs. Reassess the conditions when changing compiler, pipeline,
source/dependency closure, or storage layout.

## Reproduce

```sh
forge config
forge build
just verify-compiler-provenance
```

The recipe checks:

1. Resolved `via_ir` is false.
2. Source files listed in each artifact's metadata have no `layout at` specifier.
3. A clean build emits no storage-end warning.
4. Each deployed contract's CBOR metadata trailer matches the local artifact's
   trailer, on lanes with configured RPC access.

Read the full output. A skipped RPC check establishes no deployed provenance.
The source scan is textual and is not an AST-level proof; matching metadata is
not a complete runtime-bytecode comparison, particularly for immutable values.
Build success must be checked independently because a warning filter alone does
not establish successful compilation.

Do not reuse an earlier pass after a compiler/settings/dependency change. Run
contract tests and the applicable deployed-state checks against the build under
review. [Development](development.md) lists those checks and their limits.
