# Repository Principles

## Test Target And Scope

The repository tests real protocol code pinned as submodules. Confirm the active pins with `git submodule status` before deriving behavior. The current master baseline pins `lib/sparklend-v1-core` at `8120e495061dc3315f0a86f682f4ca645a418bf7`; never assume a feature-branch or historical core API exists here.

Test changes normally belong in `test/`, test fixtures and mocks, or test-facing helpers. Protocol source, gitlinks, lockfiles, dependencies, and global configuration are separate review surfaces. A test that compiles only after moving a gitlink tests a different protocol.

## Suite Taxonomy

- Pool action behavior uses adjacent BTT specifications and Solidity suites under [`test/integration/btt/`](../../../../test/integration/btt/).
- Failure tests are descriptive and unnumbered. Successful leaves use stable `[NN]` tree labels and matching `test_action_NN` names.
- A BTT suite normally has base, failure, and concrete/success contracts. Shared actors, setup, modifiers, and virtual call seams belong in the base.
- Equivalent entry points inherit an existing tree only when equivalence is intentional. [`Deposit.t.sol`](../../../../test/integration/btt/Deposit.t.sol) overrides `_callSupply`; [`SupplyWithPermit.t.sol`](../../../../test/integration/btt/SupplyWithPermit.t.sol) also overrides permit-specific exceptions.
- Focused library fuzzing uses bounded inputs, a deterministic example, and a wrapper only when needed. See [`ReserveLogic.t.sol`](../../../../test/fuzz/ReserveLogic.t.sol) and its [wrapper](../../../../test/fuzz/wrappers/ReserveLogicWrapper.sol).
- ACL tests are component/role matrices rather than BTT action trees. See [`ACL.t.sol`](../../../../test/integration/ACL.t.sol).
- Fork tests describe a pinned historical chain snapshot, require `MAINNET_RPC_URL`, and must not mix local-mock assumptions with fork state. See [`ForkTestBase.sol`](../../../../test/fork/ForkTestBase.sol).

## Tree-First Behavior

The `.tree` is the behavioral specification. Put rejecting branches first in actual validation order, then successful leaves. Make externally observable distinctions explicit: sentinel versus explicit amount, full versus partial state transition, elapsed versus same-block accounting, receipt mode, fee mode, and caller versus beneficiary. Each tree node should correspond to one setup modifier in the same order; do not hide several behavioral axes behind a flattened composite branch.

[`Withdraw.tree`](../../../../test/integration/btt/Withdraw.tree) separately specifies max withdrawal, explicit full balance, and partial balance. [`Supply.tree`](../../../../test/integration/btt/Supply.tree) models isolation, role, LTV, existing collateral, time, and active-borrow axes. Preserve documented TODOs and unreachable branches rather than manufacturing impossible setup.

## Source Of Truth

Trace an action in this order:

1. Matching `.tree` and adjacent `.t.sol` suite.
2. [`SparkLendTestBase.sol`](../../../../test/SparkLendTestBase.sol) and [`UserActions.sol`](../../../../src/UserActions.sol).
3. Pinned [`Pool.sol`](../../../../lib/sparklend-v1-core/contracts/protocol/pool/Pool.sol), including any work before library dispatch.
4. Corresponding action library under [`logic/`](../../../../lib/sparklend-v1-core/contracts/protocol/libraries/logic/).
5. Called checks in [`ValidationLogic.sol`](../../../../lib/sparklend-v1-core/contracts/protocol/libraries/logic/ValidationLogic.sol), in literal order.
6. [`ReserveLogic.sol`](../../../../lib/sparklend-v1-core/contracts/protocol/libraries/logic/ReserveLogic.sol), cache/state-update behavior, and rate inputs.
7. `DataTypes` and relevant reserve/user configuration libraries.
8. Affected aToken/debt token implementation and scaled-balance bases.
9. [`Errors.sol`](../../../../lib/sparklend-v1-core/contracts/protocol/libraries/helpers/Errors.sol).
10. Reached math libraries, preserving operation order and rounding.

Do not infer semantics from test names, comments, Aave familiarity, or algebraically simplified formulas. Spark-specific behavior and call ordering control.

## Proxies, Callers, And Accounting

- Pool and token state lives at proxies. Calls, assertions, wrappers, and event emitters must target the live proxy, not implementation storage.
- Delegatecall preserves the external caller. Distinguish `msg.sender`, account owner, `onBehalfOf`, receiver, and treasury for every path.
- Underlying reserve cash sits at the aToken address.
- Scaled balances, stored indexes, normalized view indexes, and visible ERC-20 balances are different quantities.
- Supply income is linear; variable debt uses compounded approximation. State updates are lazy and same-timestamp calls can leave indexes untouched.
- `accruedToTreasury` is scaled. Convert it at the relevant liquidity index before comparing it with visible claims.
- The shared reserve assertion omits configuration, reserve id and addresses, strategy, and `isolationModeTotalDebt`. Assert omitted fields separately when a scenario can affect them.
- Setup-created secondary debtors and holders, plus minted or pending treasury claims, are part of the scenario state. Include their balances, debts, configuration, and account data in the same before/after accounting as the primary actor.

## Units And Fixtures

- Underlying amounts use token decimals; local defaults use 18 decimals.
- Local oracle prices use `1e8` base-currency precision and default to one dollar.
- Rates and indexes are ray (`1e27`); health factor is wad (`1e18`).
- LTV, thresholds, bonuses, reserve factor, and protocol fees use basis points.
- Caps are configured in whole tokens but validated at token precision. Debt ceilings have two implied decimals.
- [`UserActions.sol`](../../../../src/UserActions.sol) uses `deal` in `_supply` and `_repay`, replacing the actor's balance with exactly the requested amount. Do not use those helpers for precise pre-existing balances or insufficient balance/allowance cases.
- Modifier order is execution order. Setup that depends on an earlier modifier must come later.
- Preserve the repository's fixture timestamp baseline. Express elapsed-time setup as a delta from the observed fixture timestamp instead of replacing it with an unrelated hard-coded timestamp.
- `proveNoOp` means no storage write, not merely equal final values. Restart state-diff recording immediately before the target call if test-body setup writes state.

## Assertions And Reverts

Use the state structs and helpers in [`SparkLendTestBase.sol`](../../../../test/SparkLendTestBase.sol) to establish complete before/after state, including unchanged fields. Audit each helper's implementation and add explicit checks for user configuration, account data, isolation debt, secondary actors, treasury claims, or other omissions. An assertion helper must read actual protocol state and compare it with expectations; comparing two caller-supplied values proves nothing.

Derive complex values from protocol inputs, then assert the derivation against an independent hard-coded value. Reproduce arithmetic in literal source order, preserving intermediate rounding rather than substituting an algebraically equivalent expression or an unaudited fixture helper. Exact equality is the default. A tolerance is acceptable only when its source and maximum are demonstrated and the tolerance is local to affected fields; [`ReserveLogic.t.sol`](../../../../test/fuzz/ReserveLogic.t.sol) shows bounded cumulative rounding.

Use `vm.expectRevert(bytes(Errors.X))` for named protocol errors and `stdError` for known Solidity panics. Use a bare revert expectation only for a genuinely opaque downstream EVM path, and explain why. The expected revert is the first reachable failure along the complete call path.

## Stateful And Fuzz Assurance

Deterministic named examples establish important boundaries even when a fuzz property includes the same value mathematically. Bounds must cover meaningful protocol phases, including non-identity indexes, relevant decimals/prices, and both sides of any boundary where a nonzero scaled amount collapses to zero when visible, without letting unrelated overflow dominate. If the intended safety property fails on the pinned core, report the protocol blocker rather than selecting only passing inputs, gating the property, or accepting the unsafe state.

An invariant campaign must prove its holder/debtor sets are closed, move indexes into the behavior under test, enforce minimum successful coverage of critical actions, classify expected reverts, and keep safety properties always on. Logs, nonzero attempt counts, swallowed reverts, or deep optional runs do not establish reachability.
