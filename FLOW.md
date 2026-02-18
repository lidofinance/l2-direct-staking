# Diagram Naming Shortcuts

- `L2 CustomSenderReferral` -> `L2CustomSender`
- `L2 PausableImmutableOraclePool` -> `L2Pool`
- `L2 CCIP Router` -> `L2Router`
- Use these labels in future Mermaid diagrams in this repo for consistency.

# Fast Stake Flow

```mermaid
%%{init: {"sequence": {"diagramMarginX": 8, "diagramMarginY": 8, "actorMargin": 24, "width": 90, "height": 56, "boxMargin": 6, "boxTextMargin": 4, "noteMargin": 6, "messageMargin": 12}}}%%
sequenceDiagram
    autonumber
    actor User
    actor Rebalancer
    participant CS as L2CustomSender
    participant Pool as L2Pool
    participant L2R as L2Router
    participant L2Bridge as L2TokenBridge
    box LightBlue Offchain
    participant CCIP as Chainlink CCIP Network
    participant OPRelay as "L1->L2 Relay / Derivation"
    end
    participant L1Rtr as L1CcipRouter
    participant L1R as L1Receiver
    participant Lido as Lido Staking
    participant Ad as L1LegacyAdapter
    participant L1Bridge as L1TokenBridge

    link CS: Optimism Explorer @ https://optimistic.etherscan.io/address/0x328de900860816d29D1367F6903a24D8ed40C997
    link L2R: Optimism Explorer @ https://optimistic.etherscan.io/address/0x3206695CaE29952f4b0c22a169725a865bc8Ce0f
    link L1Rtr: Ethereum Explorer @ https://etherscan.io/address/0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D
    link L1R: Ethereum Explorer @ https://etherscan.io/address/0x6F357d53d6bE3238180316BA5F8f11467e164588
    link Ad: Ethereum Explorer @ https://etherscan.io/address/0x328de900860816d29D1367F6903a24D8ed40C997
    link L1Bridge: Ethereum Explorer @ https://etherscan.io/address/0x76943C0D61395d8F2edF9060e1533529cAe05dE6
    link L2Bridge: Optimism Explorer @ https://optimistic.etherscan.io/address/0x8E01013243a96601a86eb3153F0d9Fa4fbFb6957

    rect rgb(255, 247, 204)
    Note over User,Pool: Fast leg (steps 1-4): User WETH in, User wstETH out
    User->>CS: fastStake(amountIn, minOut)
    CS->>Pool: swap(amountIn, minOut)
    Pool-->>CS: amountOut (wstETH)
    CS-->>User: amountOut (wstETH)
    end

    rect rgb(236, 248, 255)
    Note over Rebalancer,CCIP: Sync leg (steps 5-7)
    Rebalancer->>CS: sync(dst, amount)
    CS->>L2R: ccipSend(dst, amount)
    L2R->>CCIP: enqueue(msgId)
    end

    CCIP->>L1Rtr: route(msgId)
    L1Rtr->>L1R: ccipReceive(msgId)

    L1R->>Lido: submit(amount)
    Lido-->>L1R: wrapToWstETH()
    L1R->>Ad: sendToken(recipient, amount)
    Ad->>L1Bridge: bridgeOut(recipient, amount)
    L1Bridge->>OPRelay: relayToL2(recipient, amount)
    OPRelay->>L2Bridge: finalizeToL2(recipient, amount)
    L2Bridge->>Pool: transfer(recipient, amount)
```

Explorer links:
- L2CustomSender: [0x328de900860816d29D1367F6903a24D8ed40C997](https://optimistic.etherscan.io/address/0x328de900860816d29D1367F6903a24D8ed40C997)
- L2Router: [0x3206695CaE29952f4b0c22a169725a865bc8Ce0f](https://optimistic.etherscan.io/address/0x3206695CaE29952f4b0c22a169725a865bc8Ce0f)
- L1 CCIP Router: [0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D](https://etherscan.io/address/0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D)
- L1 LidoCustomReceiver: [0x6F357d53d6bE3238180316BA5F8f11467e164588](https://etherscan.io/address/0x6F357d53d6bE3238180316BA5F8f11467e164588)
- L1 OptimismLegacyAdapterL1toL2: [0x328de900860816d29D1367F6903a24D8ed40C997](https://etherscan.io/address/0x328de900860816d29D1367F6903a24D8ed40C997)
- L1 wstETH Token Bridge: [0x76943C0D61395d8F2edF9060e1533529cAe05dE6](https://etherscan.io/address/0x76943C0D61395d8F2edF9060e1533529cAe05dE6)
- L2ERC20ExtendedTokensBridge: [0x8E01013243a96601a86eb3153F0d9Fa4fbFb6957](https://optimistic.etherscan.io/address/0x8E01013243a96601a86eb3153F0d9Fa4fbFb6957)
- OP Stack L1->L2 Relay / Derivation: offchain process (no single contract address)

## Why `OptimismLegacyAdapterL1toL2` Is Used

- This deployment uses Lido's dedicated L1 token bridge (`0x76943C0D61395d8F2edF9060e1533529cAe05dE6`) and therefore uses `OptimismLegacyAdapterL1toL2`, which is wired to `IOptimismL1ERC20TokenBridge`.
- The deployment script explicitly instantiates the legacy adapter for the Optimism lane:
  - `lib/chainlink-csr/script/lido/LidoDeploy.s.sol`
  - `lib/chainlink-csr/script/lido/LidoParameters.sol`
- "Legacy" here means the adapter targets the older/custom token-bridge interface, not that it is inactive.

### Modern Equivalent

- The modern OP-stack approach is an adapter against `L1StandardBridge` (`depositERC20To` on standard bridge ABI).
- In this repo, `OptimismAdapterL1toL2` (non-legacy) is not implemented yet.
- `lib/chainlink-csr/contracts/adapters/BaseAdapterL1toL2.sol` is the closest in-repo example of the standard-bridge adapter style.

# Fast Staking Test Flow
```mermaid
%%{init: {"sequence": {"diagramMarginX": 8, "diagramMarginY": 8, "actorMargin": 24, "width": 90, "height": 56, "boxMargin": 6, "boxTextMargin": 4, "noteMargin": 6, "messageMargin": 12}}}%%
sequenceDiagram
    autonumber
    actor User
    actor Rebalancer
    actor Test as TestHarness
    participant CS as L2CustomSender
    participant Pool as L2Pool
    participant L2Fin as L2Finalizer
    box LightBlue Offchain (tests/mocked)
    participant Sim as CcipLocalSim
    end
    participant L1R as L1Receiver
    participant Lido as Lido Staking
    participant Ad as L1Adapter

    User->>CS: fastStake(amountIn, minOut)
    CS->>Pool: swap(amountIn, minOut)
    Pool-->>CS: amountOut (wstETH)
    CS-->>User: amountOut (wstETH)
    Note over Pool: Pool accumulates WETH inventory from fastStake

    Rebalancer->>CS: sync(dst, amount)
    CS->>Sim: ccipSend(dst, amount)
    Sim->>L1R: routeToL1(forkId)

    L1R->>Lido: submit(amount)
    Lido-->>L1R: wrapToWstETH()
    L1R->>Ad: sendToken(recipient, amount)
    Test->>L2Fin: finalize(token, recipient, amount)
    L2Fin->>Pool: transfer(recipient, amount)
    Note over L1R,Ad: Cross-chain settlement updates L2-side liquidity backing
```

## Summary

- `fastStake` gives the user immediate output on L2 via local pool liquidity.
- WETH collected in the L2 pool is later sent by `sync` through CCIP.
- On L1, the receiver stakes into Lido, dispatches through the adapter, and the bridged `wstETH` replenishes `L2Pool`.
