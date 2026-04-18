# Testing Upgrade with Chainlink Local (CCIP)

Primary files:
- `/Users/arwer/projects/lido-direct-staking/test/OptimismPoolUpgrade.t.sol`
- `/Users/arwer/projects/lido-direct-staking/test/helpers/OptimismUpgradeTestBase.sol`
- `/Users/arwer/projects/lido-direct-staking/src/optimism/OptimismMigrationConstants.sol`

Primary end-to-end test:
- `test_upgradeSyncRoutesAcrossL2AndL1CCIPLayer`

## 1. Setup

1. Install dependencies:
   ```sh
   git submodule update --init --recursive
   just setup
   ```
2. Ensure `.env` contains:
   ```env
   L1_RPC_URL=...
   L2_OPTIMISM_RPC_URL=...
   ```

## 2. Run

1. Run only the CCIP upgrade test:
   ```sh
   forge test --match-test test_upgradeSyncRoutesAcrossL2AndL1CCIPLayer -vv
   ```
2. Run the full upgrade suite:
   ```sh
   forge test --match-contract OptimismPoolUpgradeTest -vv
   ```

## 3. How CCIP is mocked (official fork pattern)

The test follows the Chainlink Local forked simulator flow:

1. Create L1 and L2 forks with `vm.createFork(...)`.
2. Deploy `CCIPLocalSimulatorFork` in `setUp()` and keep it alive across forks:
   - `vm.makePersistent(address(ccipLocalSimulatorFork))`
3. Register network details for chain IDs `1` (Ethereum) and `10` (Optimism) using:
   - `ccipLocalSimulatorFork.setNetworkDetails(...)`
4. Execute upgrade steps on L2 and L1.
5. On L2, perform `fastStake` to accumulate WETH in the pool.
6. On L2, call `sync(...)` and capture CCIP logs:
   - `vm.recordLogs()`
7. Route the recorded CCIP message to L1 using:
   - `ccipLocalSimulatorFork.switchChainAndRouteMessage(l1Fork)`
8. Verify on L1:
   - message processed (`getFailedMessageHash(messageId) == 0`)
   - receiver stakes and increases wstETH balance
   - adapter dispatch event is emitted

## 4. Notes

- This is the **Chainlink Local fork simulator** approach (not hand-built `Any2EVMMessage` injection).
- It validates upgrade behavior together with actual router/off-ramp execution path on forked state.
- The tested L1->L2 return path on Optimism uses `OptimismLegacyAdapterL1toL2` because Lido is configured with a dedicated L1 token bridge (`0x76943C0D61395d8F2edF9060e1533529cAe05dE6`) rather than a generic OP-stack `L1StandardBridge` adapter.

## 5. Troubleshooting

- If Foundry crashes with `SCDynamicStoreBuilder` on macOS, run tests outside restricted sandbox/container environments.
