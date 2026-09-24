// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";
import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {
    FundVaultExecutionInvariantHandler
} from "test/handlers/FundVaultExecutionInvariantHandler.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockFundVaultCallTarget, MockRecoveryVault} from "test/mocks/MockFundVaultExecution.sol";

contract AlphaEngineFundVaultExecutionInvariantTest is StdInvariant, Test {
    address private constant EMERGENCY_AUTHORITY = address(0xE911);

    MockERC20 private usdc;
    AlphaEngineFundVault private vault;
    MockFundVaultCallTarget private accountingManager;
    MockFundVaultCallTarget private target;
    MockRecoveryVault private recoveryVault;
    FundVaultExecutionInvariantHandler private handler;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new AlphaEngineFundVault(address(this), usdc);
        accountingManager = new MockFundVaultCallTarget();
        target = new MockFundVaultCallTarget();
        recoveryVault = new MockRecoveryVault();
        handler = new FundVaultExecutionInvariantHandler(
            IAlphaEngineFundVault(address(vault)), target, address(accountingManager)
        );

        vault.setUsdcManager(address(accountingManager));
        vault.setExecutionManager(address(handler));
        vault.setEmergencyConfiguration(EMERGENCY_AUTHORITY, address(recoveryVault));
        vault.unpause();

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.executeSuccessful.selector;
        selectors[1] = handler.executeFailing.selector;
        selectors[2] = handler.attemptProtectedAccountingCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantSuccessfulEffectsExactlyMatchTheIndependentGhostTotal() public view {
        assertEq(target.total(), handler.ghostSuccessfulTotal());
    }

    function invariantFailedBatchesAlwaysRollBackAndReturnTheExpectedTypedFailure() public view {
        assertFalse(handler.rollbackViolation());
    }

    function invariantAccountingManagerRemainsOutsideTheExecutionCallGraph() public view {
        assertFalse(handler.protectedTargetViolation());
    }

    function invariantExecutionCannotMutateTheShareLedgerOrControlPlane() public view {
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.usdcManager(), address(accountingManager));
        assertEq(vault.executionManager(), address(handler));
        assertEq(vault.emergencyAuthority(), EMERGENCY_AUTHORITY);
        assertEq(vault.recoveryVault(), address(recoveryVault));
        assertFalse(vault.paused());
        assertFalse(vault.recoveryActivated());
    }
}
