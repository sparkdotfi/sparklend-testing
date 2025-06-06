# SparkLend Testing

![Foundry CI](https://github.com/marsfoundation/sparklend-testing/actions/workflows/ci.yml/badge.svg)
[![Foundry][foundry-badge]][foundry]
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://github.com/marsfoundation/sparklend-testing/blob/master/LICENSE)

[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg

## Overview

This repository imports all relevant submodules into one repo to test the SparkLend protocol. These tests include:
- Unit testing `[WIP]`
- Fuzz testing `[TODO]`
- Invariant testing `[TODO]`
- Mainnet integration testing `[TODO]`
- Mainnet integration invariant testing `[TODO]`
- End to end scenario testing `[TODO]`

This repo imports the following submodules relevant to the SparkLend protocol:
- [`marsfoundation/sparklend-v1-core (v1.0.0)`](https://github.com/marsfoundation/sparklend-v1-core/tree/master)
- [`marsfoundation/sparklend-advanced (v1.1.0)`](https://github.com/marsfoundation/sparklend-advanced/tree/master)

## Unit Testing
This repo uses [Branching Tree Techinique (BTT)](https://github.com/PaulRBerg/btt-examples?tab=readme-ov-file) style testing to ensure all logic branches are covered within each function. Below each testing file, there is a corresponding `.tree` file that includes the specs for these tests. 

In each `.tree` file, all failure modes are documented first, followed by all success cases.  The failure mode tests follow standard foundry naming conventions (`test_functionName_desciption`), where the success cases follow a numbering system (`test_functionName_xx`). 

Each numbered test corresponds to a statement with the same number in the `.tree` file. Due to the large number of permutations in BTT tests, it was determined that this approach would make tests easier to navigate, as the description of the test can be read from the modifiers instead of the test name. For example:

```solidity
function test_supply_01()
    public
    givenFirstUserSupply
    givenIsolationModeEnabled
    givenUserHasNoIsolatedCollateralRole
{
```

There are some functions that have identical logic trees to others, such as `repay` and `repayWithPermit`. For these functions, the `.tree` file was not duplicated. Instead, the `repay` function uses a virtual function `_callRepay` that it uses to run all of its tests, while `repayWithPermit` can inherit the `repay` tests and override this function to prove equivalence. 

Any differences in tests are remedied by overriding the tests themselves.

## Assertion Helper Functions

Since a lot of state variables are modified, the following procedure is followed to assert state:
1. Declare structs with all expected values for all relevant contracts (`pool`, `aToken`, `collateralAsset`, etc.).
2. Assert the state of each value in the structs against the contract using a helper function.
3. Call the function.
4. Modify the structs with ONLY the state that is expected to change.
5. Assert the structs again using the same helper.

This approach was chosen because of a few reasons:
1. It reduces code size, eliminating the need for inline assertions of state variables that aren't changing.
2. It ensures that state variables that aren't changing are still getting asserted to prove that they haven't changed.
3. It ensures that all relevant state is always getting asserted.

The second point is important because false assumptions can be made that a state variable isn't expected to change, so it is omitted from a test even though it does change. This can go unnoticed without the approach above.

The third point is also important, because tests with large blocks of repetitive assertions code can easily miss a line of important state that could be missed by a reviewer. Using standardized assertion functions asssures this never happens, while abstracting away all the repetitive code necessary to perform the assertions.

## Assertion of Both Hard-Coded and Derived Values

Since a lot of the assertions required in the SparkLend codebase are complex in nature, it becomes necessary to derive their expected values. This is an effective approach, but can also lead to issues as the derivation itself could have a bug in it. 

For this reason, all derived expected values are also asserted against hardcoded values provided by the tester. This allows the reviewer to review the derivation to see that it makes logical sense, and then spot check the hard-coded values against the result to make sure that the result is in the range they expect. 

It is also important to not only use hard-coded values either, as they can seem to be in the right range but be incorrect. When both approaches are used, hard-coded values reinforce the derived value's correctness and vice versa.

## Running Tests

To run tests in this repo, run:

```bash
forge test
```
