// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";
import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {AlphaEngineUSDCVaultManager} from "src/vault/AlphaEngineUSDCVaultManager.sol";
import {USDCVaultInvariantHandler} from "test/handlers/USDCVaultInvariantHandler.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {
    MockFundVaultExecutionManager, MockRecoveryVault
} from "test/mocks/MockFundVaultExecution.sol";

contract AlphaEngineUSDCVaultManagerInvariantTest is StdInvariant, Test {
    address private constant FEE_RECIPIENT = address(0xFEE);
    address private constant STRATEGY = address(0x5151);

    MockERC20 private usdc;
    AlphaEngineFundVault private fundVault;
    AlphaEngineUSDCVaultManager private manager;
    USDCVaultInvariantHandler private handler;

    function setUp() public {
        vm.roll(100);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        fundVault = new AlphaEngineFundVault(address(this), usdc);
        manager = new AlphaEngineUSDCVaultManager(
            address(this),
            usdc,
            IAlphaEngineFundVault(address(fundVault)),
            address(this),
            FEE_RECIPIENT,
            1 days,
            1000
        );
        handler = new USDCVaultInvariantHandler(usdc, fundVault, manager, FEE_RECIPIENT, STRATEGY);

        fundVault.setUsdcManager(address(manager));
        fundVault.setExecutionManager(address(new MockFundVaultExecutionManager(address(this))));
        fundVault.setEmergencyConfiguration(address(this), address(new MockRecoveryVault()));
        fundVault.unpause();
        manager.setNavReporter(address(handler));
        manager.unpause();

        handler.deposit(0, 1000e6);
        handler.requestRedeem(0, 100e18);
        handler.cancelRedeem(0);
        handler.requestRedeem(0, 100e18);
        handler.completeRedeem(0);
        handler.reportProfit(100e6);
        handler.advanceTime(1 days);
        handler.settleFinishedProfit();
        handler.reportLoss(10e6);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.requestRedeem.selector;
        selectors[2] = handler.cancelRedeem.selector;
        selectors[3] = handler.completeRedeem.selector;
        selectors[4] = handler.attemptIlliquidCompletion.selector;
        selectors[5] = handler.reportProfit.selector;
        selectors[6] = handler.reportLoss.selector;
        selectors[7] = handler.advanceTime.selector;
        selectors[8] = handler.settleFinishedProfit.selector;
        selectors[9] = handler.deployLiquidity.selector;
        selectors[10] = handler.returnLiquidity.selector;
        selectors[11] = handler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_managedAssetsMatchEveryAccountingDelta() public view {
        assertEq(manager.managedAssets(), handler.ghostManagedAssets());
        uint256 additions = handler.ghostDepositedUsdc() + handler.ghostReportedProfit();
        uint256 deductions = handler.ghostRedeemedUsdc() + handler.ghostReportedLoss();
        assertGe(additions, deductions);
        assertEq(manager.managedAssets(), additions - deductions);
    }

    function invariant_shareSupplyIsFullyAccountedFor() public view {
        assertEq(fundVault.totalSupply(), handler.trackedShareSupply());
        assertEq(fundVault.balanceOf(address(fundVault)), handler.pendingRedemptionShares());
    }

    function invariant_actualUSDCIsConservedAcrossVaultAndStrategy() public view {
        uint256 inflows = handler.ghostDepositedUsdc() + handler.ghostDonations();
        uint256 outflows = handler.ghostRedeemedUsdc();
        assertGe(inflows, outflows);
        assertEq(usdc.balanceOf(address(fundVault)) + usdc.balanceOf(STRATEGY), inflows - outflows);
        assertEq(usdc.balanceOf(STRATEGY), handler.ghostDeployedUsdc());
        assertEq(usdc.balanceOf(address(manager)), 0);
    }

    function invariant_lockedProfitAndRecoveryRemainBounded() public view {
        assertLe(manager.remainingLockedProfit(), manager.lockedProfit());
        assertLe(manager.remainingLockedProfit(), manager.managedAssets());
        assertLe(manager.remainingLockedRecoveryProfit(), manager.remainingLockedProfit());
        assertLe(manager.availableAssets(), manager.managedAssets());
        assertLe(manager.pendingFeeBps(), manager.MAX_PERFORMANCE_FEE_BPS());
    }

    function invariant_depositsAndRedemptionsNeverDiluteSharePrice() public view {
        assertFalse(handler.depositPriceViolation());
        assertFalse(handler.redemptionPriceViolation());
    }

    function invariant_performanceFeeNeverOvercharges() public view {
        assertFalse(handler.feeOverchargeViolation());
        assertFalse(handler.feeExactnessViolation());
        assertFalse(handler.feeSettlementPriceViolation());
        assertFalse(handler.lossRecoveryFlowViolation());
        assertLe(manager.performanceFeeBps(), manager.MAX_PERFORMANCE_FEE_BPS());
    }

    function invariant_independentAccountingModelMatchesEveryReachableState() public view {
        assertFalse(handler.accountingModelViolation());
        assertEq(manager.managedAssets(), handler.ghostManagedAssets());
        assertEq(manager.lockedProfit(), handler.ghostLockedProfit());
        assertEq(manager.lockedRecoveryProfit(), handler.ghostLockedRecoveryProfit());
        assertEq(manager.pendingFeeAssets(), handler.ghostPendingFeeAssets());
        assertEq(manager.lossToRecover(), handler.ghostLossToRecover());
        assertEq(manager.profitLockTimestamp(), handler.ghostProfitLockTimestamp());
        assertEq(manager.profitUnlockTimestamp(), handler.ghostProfitUnlockTimestamp());
        assertEq(manager.pendingFeeBps(), handler.ghostPendingFeeBps());
        assertEq(fundVault.totalSupply(), handler.ghostShareSupply());
        assertEq(manager.remainingLockedProfit(), handler.modelRemainingLockedProfit());
        assertEq(
            manager.remainingLockedRecoveryProfit(), handler.modelRemainingLockedRecoveryProfit()
        );
        assertEq(manager.availableAssets(), handler.modelAvailableAssets());
    }

    function invariant_failedIlliquidCompletionIsAtomic() public view {
        assertFalse(handler.failedCompletionMutation());
    }

    function invariant_reportsAreSequential() public view {
        assertEq(
            manager.reportEpoch(),
            handler.successfulProfitReports() + handler.successfulLossReports()
        );
    }

    function invariant_seededActionsPreventVacuousCoverage() public view {
        assertGt(handler.successfulDeposits(), 0);
        assertGt(handler.successfulRequests(), 0);
        assertGt(handler.successfulCancellations(), 0);
        assertGt(handler.successfulCompletions(), 0);
        assertGt(handler.successfulProfitReports(), 0);
        assertGt(handler.successfulLossReports(), 0);
        assertGt(handler.successfulFeeSettlements(), 0);
    }
}
