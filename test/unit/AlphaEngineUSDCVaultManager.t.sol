// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";
import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {AlphaEngineUSDCVaultManager} from "src/vault/AlphaEngineUSDCVaultManager.sol";
import {MockERC20, MockSelectiveFeeERC20} from "test/mocks/MockERC20.sol";
import {
    MockFundVaultExecutionManager,
    MockRecoveryVault
} from "test/mocks/MockFundVaultExecution.sol";

contract AlphaEngineUSDCVaultManagerTest is Test {
    uint64 private constant VESTING_PERIOD = 1 days;
    uint16 private constant PERFORMANCE_FEE_BPS = 1000;

    address private constant NAV_REPORTER = address(0xA11CE);
    address private constant FEE_RECIPIENT = address(0xFEE);
    address private constant USER = address(0xB0B);
    address private constant USER_TWO = address(0xCAFE);
    address private constant RECEIVER = address(0xD00D);

    MockERC20 private usdc;
    AlphaEngineFundVault private fundVault;
    AlphaEngineUSDCVaultManager private manager;
    MockFundVaultExecutionManager private executionManager;
    MockRecoveryVault private recoveryVault;

    function setUp() public {
        vm.roll(100);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        fundVault = new AlphaEngineFundVault(address(this), usdc);
        manager = new AlphaEngineUSDCVaultManager(
            address(this),
            usdc,
            IAlphaEngineFundVault(address(fundVault)),
            NAV_REPORTER,
            FEE_RECIPIENT,
            VESTING_PERIOD,
            PERFORMANCE_FEE_BPS
        );
        executionManager = new MockFundVaultExecutionManager(address(this));
        recoveryVault = new MockRecoveryVault();
        fundVault.setUsdcManager(address(manager));
        fundVault.setExecutionManager(address(executionManager));
        fundVault.setEmergencyConfiguration(address(this), address(recoveryVault));
        fundVault.unpause();
        manager.unpause();

        usdc.mint(USER, 10_000_000e6);
        usdc.mint(USER_TWO, 10_000_000e6);
        vm.prank(USER);
        usdc.approve(address(fundVault), type(uint256).max);
        vm.prank(USER_TWO);
        usdc.approve(address(fundVault), type(uint256).max);
    }

    function testInitialConfigurationIsMinimalAndPausedUntilLinked() public {
        MockERC20 asset = new MockERC20("USD Coin", "USDC", 6);
        AlphaEngineFundVault vault = new AlphaEngineFundVault(address(this), asset);
        AlphaEngineUSDCVaultManager accounting = new AlphaEngineUSDCVaultManager(
            address(this),
            asset,
            IAlphaEngineFundVault(address(vault)),
            NAV_REPORTER,
            FEE_RECIPIENT,
            VESTING_PERIOD,
            PERFORMANCE_FEE_BPS
        );

        assertTrue(vault.paused());
        assertTrue(accounting.paused());
        assertEq(vault.usdc(), address(asset));
        assertEq(address(accounting.USDC()), address(asset));
        assertEq(address(accounting.FUND_VAULT()), address(vault));
        assertEq(accounting.navReporter(), NAV_REPORTER);
        assertEq(accounting.feeRecipient(), FEE_RECIPIENT);
        assertEq(accounting.vestingPeriod(), VESTING_PERIOD);
        assertEq(accounting.performanceFeeBps(), PERFORMANCE_FEE_BPS);
        assertEq(accounting.nextRedemptionId(), 1);

        vm.expectRevert(AlphaEngineFundVault.IncompleteConfiguration.selector);
        vault.unpause();

        vault.setUsdcManager(address(accounting));
        vm.expectRevert(AlphaEngineFundVault.IncompleteConfiguration.selector);
        vault.unpause();

        MockFundVaultExecutionManager localExecutionManager =
            new MockFundVaultExecutionManager(address(this));
        vault.setExecutionManager(address(localExecutionManager));
        vm.expectRevert(AlphaEngineFundVault.IncompleteConfiguration.selector);
        vault.unpause();

        MockRecoveryVault localRecoveryVault = new MockRecoveryVault();
        vault.setEmergencyConfiguration(address(this), address(localRecoveryVault));
        vault.unpause();
        assertFalse(vault.paused());
    }

    function testConstructorsRejectInvalidAccountingConfiguration() public {
        MockERC20 eighteenDecimals = new MockERC20("Wrong", "WRONG", 18);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.InvalidUSDCDecimals.selector, uint8(18))
        );
        new AlphaEngineFundVault(address(this), eighteenDecimals);

        MockERC20 otherUsdc = new MockERC20("Other", "OTHER", 6);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InvalidFundVaultAsset.selector,
                address(otherUsdc),
                address(usdc)
            )
        );
        new AlphaEngineUSDCVaultManager(
            address(this),
            otherUsdc,
            IAlphaEngineFundVault(address(fundVault)),
            NAV_REPORTER,
            FEE_RECIPIENT,
            VESTING_PERIOD,
            PERFORMANCE_FEE_BPS
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InvalidPerformanceFee.selector, uint16(2001)
            )
        );
        new AlphaEngineUSDCVaultManager(
            address(this),
            usdc,
            IAlphaEngineFundVault(address(fundVault)),
            NAV_REPORTER,
            FEE_RECIPIENT,
            VESTING_PERIOD,
            2001
        );
    }

    function testFundVaultManagerCanOnlyBeSetOnce() public {
        vm.expectRevert(AlphaEngineFundVault.USDCManagerAlreadySet.selector);
        fundVault.setUsdcManager(address(manager));
    }

    function testFundVaultSettlementSelectorsRejectUnauthorizedCallers() public {
        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.UnauthorizedUSDCManager.selector, USER)
        );
        fundVault.settleDeposit(USER, USER, 1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.UnauthorizedUSDCManager.selector, USER)
        );
        fundVault.lockRedemptionShares(USER, 1);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.UnauthorizedUSDCManager.selector, USER)
        );
        fundVault.releaseRedemptionShares(USER, 1);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.UnauthorizedUSDCManager.selector, USER)
        );
        fundVault.settleRedemption(USER, 1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.UnauthorizedUSDCManager.selector, USER)
        );
        fundVault.mintFeeShares(USER, 1);
        vm.stopPrank();
    }

    function testAmountAndReceiverBoundariesFailLoudly() public {
        vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroAssets.selector);
        vm.prank(USER);
        manager.deposit(0, USER, 0);

        vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroAddress.selector);
        vm.prank(USER);
        manager.deposit(1, address(0), 0);

        vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroShares.selector);
        vm.prank(USER);
        manager.requestRedeem(0, USER, 0);

        _deposit(USER, 1e6);
        vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroAddress.selector);
        vm.prank(USER);
        manager.requestRedeem(1e18, address(0), 0);

        vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroAssets.selector);
        vm.prank(NAV_REPORTER);
        manager.reportProfit(1, 99, 0, keccak256("zero-profit"));

        vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroAssets.selector);
        vm.prank(NAV_REPORTER);
        manager.reportLoss(1, 99, 0, keccak256("zero-loss"));
    }

    function testDepositSupportsExactAndMaximumBalanceButRejectsAboveBalance() public {
        address exactUser = address(0xE1);
        uint256 exactAssets = 100e6;
        usdc.mint(exactUser, exactAssets);
        vm.prank(exactUser);
        usdc.approve(address(fundVault), type(uint256).max);

        vm.prank(exactUser);
        manager.deposit(exactAssets, exactUser, 0);
        assertEq(usdc.balanceOf(exactUser), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, exactUser, uint256(0), uint256(1)
            )
        );
        vm.prank(exactUser);
        manager.deposit(1, exactUser, 0);

        address maxUser = address(0xE2);
        uint256 maxAssets = type(uint96).max;
        usdc.mint(maxUser, maxAssets);
        vm.prank(maxUser);
        usdc.approve(address(fundVault), maxAssets);
        vm.prank(maxUser);
        uint256 maxShares = manager.deposit(maxAssets, maxUser, 0);
        assertGt(maxShares, 0);
        assertEq(usdc.balanceOf(maxUser), 0);
    }

    function testInitialDepositMintsImmediatelyAtOneDollarPerShare() public {
        uint256 assets = 100e6;
        uint256 expectedShares = 100e18;

        vm.expectEmit(true, true, false, true, address(manager));
        emit AlphaEngineUSDCVaultManager.Deposit(USER, USER, assets, expectedShares);
        vm.prank(USER);
        uint256 shares = manager.deposit(assets, USER, expectedShares);

        assertEq(shares, expectedShares);
        assertEq(manager.managedAssets(), assets);
        assertEq(manager.availableAssets(), assets);
        assertEq(fundVault.totalSupply(), expectedShares);
        assertEq(fundVault.balanceOf(USER), expectedShares);
        assertEq(usdc.balanceOf(address(fundVault)), assets);
        assertEq(usdc.balanceOf(address(manager)), 0);
    }

    function testLifecycleEventsMatchStoredAccountingState() public {
        uint256 depositAssets = 1000e6;
        uint256 depositShares = 1000e18;
        vm.expectEmit(true, true, false, true, address(fundVault));
        emit AlphaEngineFundVault.DepositSettled(USER, USER, depositAssets, depositShares);
        vm.expectEmit(true, true, false, true, address(manager));
        emit AlphaEngineUSDCVaultManager.Deposit(USER, USER, depositAssets, depositShares);
        vm.prank(USER);
        manager.deposit(depositAssets, USER, depositShares);

        vm.prank(USER);
        fundVault.approve(address(manager), 200e18);
        vm.expectEmit(true, false, false, true, address(fundVault));
        emit AlphaEngineFundVault.RedemptionSharesLocked(USER, 100e18);
        vm.expectEmit(true, true, true, true, address(manager));
        emit AlphaEngineUSDCVaultManager.RedemptionRequested(1, USER, RECEIVER, 100e18, 0);
        vm.prank(USER);
        uint64 cancelledId = manager.requestRedeem(100e18, RECEIVER, 0);

        vm.expectEmit(true, false, false, true, address(fundVault));
        emit AlphaEngineFundVault.RedemptionSharesReleased(USER, 100e18);
        vm.expectEmit(true, true, false, true, address(manager));
        emit AlphaEngineUSDCVaultManager.RedemptionCancelled(cancelledId, USER, 100e18);
        vm.prank(USER);
        manager.cancelRedeem(cancelledId);

        vm.expectEmit(true, false, false, true, address(fundVault));
        emit AlphaEngineFundVault.RedemptionSharesLocked(USER, 100e18);
        vm.expectEmit(true, true, true, true, address(manager));
        emit AlphaEngineUSDCVaultManager.RedemptionRequested(2, USER, RECEIVER, 100e18, 0);
        vm.prank(USER);
        uint64 completedId = manager.requestRedeem(100e18, RECEIVER, 0);

        vm.expectEmit(true, false, false, true, address(fundVault));
        emit AlphaEngineFundVault.RedemptionSettled(RECEIVER, 100e18, 100e6);
        vm.expectEmit(true, true, false, true, address(manager));
        emit AlphaEngineUSDCVaultManager.RedemptionCompleted(completedId, RECEIVER, 100e18, 100e6);
        manager.completeRedeem(completedId);

        bytes32 profitHash = keccak256("event-profit");
        vm.expectEmit(true, true, false, true, address(manager));
        emit AlphaEngineUSDCVaultManager.ProfitReported(1, 99, 100e6, 0, 10e6, profitHash);
        uint256 feeShares = Math.mulDiv(10e6, 900e18 + 1e12, 900e6 + 1);
        vm.expectEmit(true, false, false, true, address(fundVault));
        emit AlphaEngineFundVault.FeeSharesMinted(FEE_RECIPIENT, feeShares);
        vm.expectEmit(true, false, false, true, address(manager));
        emit AlphaEngineUSDCVaultManager.PerformanceFeeMinted(FEE_RECIPIENT, 10e6, feeShares);
        vm.prank(NAV_REPORTER);
        manager.reportProfit(1, 99, 100e6, profitHash);

        vm.roll(101);
        bytes32 lossHash = keccak256("event-loss");
        vm.expectEmit(true, true, false, true, address(manager));
        emit AlphaEngineUSDCVaultManager.LossReported(2, 100, 20e6, 20e6, lossHash);
        vm.prank(NAV_REPORTER);
        manager.reportLoss(2, 100, 20e6, lossHash);

        vm.warp(block.timestamp + VESTING_PERIOD);
        assertEq(manager.settleFinishedProfit(), 0);

        assertEq(manager.managedAssets(), 980e6);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), feeShares);
        assertEq(uint8(manager.getRedemption(completedId).status), 2);
    }

    function testDepositDoesNotChangeCurrentSharePrice() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);
        uint256 vestingStart = block.timestamp;
        vm.warp(vestingStart + 12 hours);

        uint256 assetsBefore = manager.availableAssets();
        uint256 supplyBefore = fundVault.totalSupply();
        uint256 priceBefore = Math.mulDiv(assetsBefore, 1e18, supplyBefore);

        _deposit(USER_TWO, 333e6);

        uint256 priceAfter = Math.mulDiv(manager.availableAssets(), 1e18, fundVault.totalSupply());
        assertApproxEqAbs(priceAfter, priceBefore, 1);
    }

    function testDirectDonationDoesNotChangeAccountingOrMintingRate() public {
        _deposit(USER, 100e6);
        uint256 sharesBefore = manager.previewDeposit(10e6);

        usdc.mint(address(fundVault), 1_000_000e6);

        assertEq(manager.managedAssets(), 100e6);
        assertEq(manager.availableAssets(), 100e6);
        assertEq(manager.previewDeposit(10e6), sharesBefore);
    }

    function testDepositHonoursMinimumSharesAndRollsBack() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientShares.selector, 10e18, 10e18 + 1
            )
        );
        vm.prank(USER);
        manager.deposit(10e6, USER, 10e18 + 1);

        assertEq(manager.managedAssets(), 0);
        assertEq(fundVault.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(fundVault)), 0);
    }

    function testFeeOnTransferAssetCannotCreateUnbackedShares() public {
        MockSelectiveFeeERC20 feeUsdc = new MockSelectiveFeeERC20("Fee USD Coin", "fUSDC", 6);
        AlphaEngineFundVault feeVault = new AlphaEngineFundVault(address(this), feeUsdc);
        AlphaEngineUSDCVaultManager feeManager = new AlphaEngineUSDCVaultManager(
            address(this),
            feeUsdc,
            IAlphaEngineFundVault(address(feeVault)),
            NAV_REPORTER,
            FEE_RECIPIENT,
            VESTING_PERIOD,
            PERFORMANCE_FEE_BPS
        );
        MockFundVaultExecutionManager feeExecutionManager =
            new MockFundVaultExecutionManager(address(this));
        MockRecoveryVault feeRecoveryVault = new MockRecoveryVault();
        feeVault.setUsdcManager(address(feeManager));
        feeVault.setExecutionManager(address(feeExecutionManager));
        feeVault.setEmergencyConfiguration(address(this), address(feeRecoveryVault));
        feeVault.unpause();
        feeManager.unpause();

        feeUsdc.mint(USER, 100e6);
        feeUsdc.setFeeRoute(USER, address(feeVault));
        vm.prank(USER);
        feeUsdc.approve(address(feeVault), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.AssetTransferMismatch.selector, 100e6, 100e6 - 1
            )
        );
        vm.prank(USER);
        feeManager.deposit(100e6, USER, 0);

        assertEq(feeManager.managedAssets(), 0);
        assertEq(feeVault.totalSupply(), 0);
    }

    function testRedemptionRequestAndCancellationDoNotChangeSharePrice() public {
        _deposit(USER, 1000e6);
        uint256 shares = 400e18;
        uint256 priceBefore = _sharePrice();

        vm.prank(USER);
        fundVault.approve(address(manager), shares);
        vm.prank(USER);
        uint64 requestId = manager.requestRedeem(shares, RECEIVER, 0);

        assertEq(_sharePrice(), priceBefore);
        assertEq(fundVault.balanceOf(address(fundVault)), shares);
        AlphaEngineUSDCVaultManager.RedemptionRequest memory request =
            manager.getRedemption(requestId);
        assertEq(request.owner, USER);
        assertEq(request.receiver, RECEIVER);
        assertEq(request.shares, shares);
        assertEq(uint8(request.status), uint8(AlphaEngineUSDCVaultManager.RedemptionStatus.Pending));

        vm.prank(USER);
        manager.cancelRedeem(requestId);
        assertEq(_sharePrice(), priceBefore);
        assertEq(fundVault.balanceOf(USER), 1000e18);
        assertEq(fundVault.balanceOf(address(fundVault)), 0);
    }

    function testRedemptionAuthorizationBoundsAndTerminalStates() public {
        _deposit(USER, 100e6);

        vm.prank(USER);
        fundVault.approve(address(manager), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                USER,
                uint256(100e18),
                uint256(100e18 + 1)
            )
        );
        vm.prank(USER);
        manager.requestRedeem(100e18 + 1, USER, 0);
        assertEq(manager.nextRedemptionId(), 1, "failed request must roll back its nonce");

        uint64 requestId = _requestRedeem(USER, 25e18, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.UnauthorizedRedemptionOwner.selector, USER_TWO, USER
            )
        );
        vm.prank(USER_TWO);
        manager.cancelRedeem(requestId);

        vm.prank(USER);
        manager.cancelRedeem(requestId);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InvalidRedemptionStatus.selector,
                requestId,
                AlphaEngineUSDCVaultManager.RedemptionStatus.Cancelled
            )
        );
        vm.prank(USER);
        manager.cancelRedeem(requestId);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.RedemptionNotFound.selector, uint64(999)
            )
        );
        manager.completeRedeem(999);
    }

    function testRedemptionCompletesOnlyAfterUSDCIsAvailable() public {
        _deposit(USER, 1000e6);
        uint64 requestId = _requestRedeem(USER, 600e18, 0);

        vm.prank(address(fundVault));
        assertTrue(usdc.transfer(address(0x5151), 900e6));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientVaultLiquidity.selector, 100e6, 600e6
            )
        );
        manager.completeRedeem(requestId);

        assertEq(manager.managedAssets(), 1000e6);
        assertEq(fundVault.totalSupply(), 1000e18);

        usdc.mint(address(fundVault), 500e6);
        uint256 priceBefore = _sharePrice();
        manager.completeRedeem(requestId);

        assertEq(usdc.balanceOf(RECEIVER), 600e6);
        assertEq(manager.managedAssets(), 400e6);
        assertEq(fundVault.totalSupply(), 400e18);
        assertEq(_sharePrice(), priceBefore);
    }

    function testPendingRedemptionParticipatesUntilCompletion() public {
        _deposit(USER, 1000e6);
        uint64 requestId = _requestRedeem(USER, 500e18, 0);

        _reportProfit(100e6);
        vm.warp(block.timestamp + VESTING_PERIOD);
        manager.settleFinishedProfit();

        uint256 expectedAssets = manager.previewRedeem(500e18);
        manager.completeRedeem(requestId);
        assertEq(usdc.balanceOf(RECEIVER), expectedAssets);
    }

    function testRedemptionMinimumAssetsProtectsCompletionPrice() public {
        _deposit(USER, 1000e6);
        uint64 requestId = _requestRedeem(USER, 500e18, 501e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientAssets.selector, 500e6, 501e6
            )
        );
        manager.completeRedeem(requestId);

        assertEq(fundVault.balanceOf(address(fundVault)), 500e18);
        assertEq(manager.managedAssets(), 1000e6);
    }

    function testFinalRedemptionWaitsForLockedProfit() public {
        manager.setPerformanceFeeBps(0);
        _deposit(USER, 1000e6);
        uint64 requestId = _requestRedeem(USER, 1000e18, 0);
        _reportProfit(100e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.FinalRedemptionWhileProfitLocked.selector, 100e6
            )
        );
        manager.completeRedeem(requestId);
        vm.warp(manager.profitUnlockTimestamp());
        usdc.mint(address(fundVault), 100e6);
        manager.completeRedeem(requestId);
        assertEq(fundVault.totalSupply(), 0);
        assertEq(manager.managedAssets(), 0);
        assertEq(fundVault.balanceOf(USER), 0);
    }

    function testTotalLossRedemptionCanTerminateAtZeroValue() public {
        _deposit(USER, 1000e6);
        uint64 requestId = _requestRedeem(USER, 1000e18, 0);
        _reportLoss(1000e6);

        manager.completeRedeem(requestId);

        AlphaEngineUSDCVaultManager.RedemptionRequest memory request =
            manager.getRedemption(requestId);
        assertEq(
            uint8(request.status), uint8(AlphaEngineUSDCVaultManager.RedemptionStatus.Completed)
        );
        assertEq(manager.managedAssets(), 0);
        assertEq(fundVault.totalSupply(), 0);
        assertEq(fundVault.balanceOf(address(fundVault)), 0);
        assertEq(usdc.balanceOf(RECEIVER), 0);
    }

    function testZeroValueRedemptionHonoursNonzeroMinimumAssets() public {
        _deposit(USER, 1000e6);
        uint64 requestId = _requestRedeem(USER, 1000e18, 1);
        _reportLoss(1000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientAssets.selector, uint256(0), uint256(1)
            )
        );
        manager.completeRedeem(requestId);

        assertEq(fundVault.totalSupply(), 1000e18);
        assertEq(fundVault.balanceOf(address(fundVault)), 1000e18);
    }

    function testProfitFeeMintsImmediatelyAndOnlyNetProfitVests() public {
        _deposit(USER, 1000e6);
        uint256 expectedFeeShares = Math.mulDiv(10e6, 1000e18 + 1e12, 1000e6 + 1);
        _reportProfit(100e6);
        assertEq(manager.managedAssets(), 1100e6);
        assertEq(manager.lockedProfit(), 90e6);
        assertEq(manager.availableAssets(), 1010e6);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), expectedFeeShares);
        assertApproxEqAbs(manager.previewRedeem(expectedFeeShares), 10e6, 1);
        uint256 start = block.timestamp;
        vm.warp(start + 12 hours);
        assertEq(manager.remainingLockedProfit(), 45e6);
        assertEq(manager.availableAssets(), 1055e6);
        vm.warp(start + VESTING_PERIOD);
        assertEq(manager.settleFinishedProfit(), 0);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), expectedFeeShares);
        assertEq(manager.lockedProfit(), 0);
        assertEq(manager.availableAssets(), 1100e6);
        assertGe(manager.previewRedeem(expectedFeeShares) + 1, 10e6);
    }

    function testProfitCleanupRequiresExactUnlockAndCannotMintAnotherFee() public {
        _deposit(USER, 100e6);
        _reportProfit(10);
        uint256 start = block.timestamp;
        uint256 issued = fundVault.balanceOf(FEE_RECIPIENT);
        assertGt(issued, 0);
        vm.warp(start + VESTING_PERIOD - 1);
        assertEq(manager.remainingLockedProfit(), 1);
        assertEq(manager.settleFinishedProfit(), 0);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), issued);
        vm.warp(start + VESTING_PERIOD);
        assertEq(manager.settleFinishedProfit(), 0);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), issued);
        assertEq(manager.remainingLockedProfit(), 0);
        vm.warp(start + VESTING_PERIOD + 1);
        assertEq(manager.settleFinishedProfit(), 0);
    }

    function testFeeSettlementDoesNotChangeDepositOrRedemptionPricing() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);
        vm.warp(block.timestamp + VESTING_PERIOD);

        uint256 depositPreviewBefore = manager.previewDeposit(100e6);
        uint256 redeemPreviewBefore = manager.previewRedeem(100e18);
        uint256 minted = manager.settleFinishedProfit();

        assertEq(minted, 0);
        assertEq(manager.previewDeposit(100e6), depositPreviewBefore);
        assertEq(manager.previewRedeem(100e18), redeemPreviewBefore);
    }

    function testNewProfitMintsOnlyItsOwnFeeAfterPreviousVesting() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);
        uint256 firstFeeShares = fundVault.balanceOf(FEE_RECIPIENT);
        vm.warp(manager.profitUnlockTimestamp());
        uint256 secondFeeShares = Math.mulDiv(5e6, fundVault.totalSupply() + 1e12, 1100e6 + 1);
        _reportProfit(50e6);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), firstFeeShares + secondFeeShares);
        assertEq(manager.lockedProfit(), 45e6);
    }

    function testPerformanceFeeUpdateIsProspective() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);
        uint256 firstFeeShares = fundVault.balanceOf(FEE_RECIPIENT);
        manager.setPerformanceFeeBps(2000);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), firstFeeShares);
        assertEq(manager.lockedProfit(), 90e6);
        vm.warp(manager.profitUnlockTimestamp());
        uint256 expected =
            Math.mulDiv(20e6, fundVault.totalSupply() + 1e12, manager.availableAssets() + 1);
        _reportProfit(100e6);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), firstFeeShares + expected);
        assertEq(manager.lockedProfit(), 80e6);
    }

    function testLossImmediatelyCancelsLockedProfitThenShareValue() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);
        uint256 feeShares = fundVault.balanceOf(FEE_RECIPIENT);
        vm.warp(block.timestamp + 12 hours);
        uint256 availableBefore = manager.availableAssets();
        _reportLoss(60e6);
        assertEq(manager.managedAssets(), 1040e6);
        assertEq(manager.lockedProfit(), 0);
        assertEq(manager.availableAssets(), 1040e6);
        assertEq(availableBefore - manager.availableAssets(), 15e6);
        assertEq(manager.lossToRecover(), 15e6);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), feeShares);
        assertLt(manager.previewRedeem(feeShares), 10e6 + 1e6);
    }

    function testLossEndingVestDoesNotClawBackIssuedFeeShares() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);
        uint256 issued = fundVault.balanceOf(FEE_RECIPIENT);
        vm.warp(block.timestamp + 12 hours);
        uint256 beforeValue = manager.previewRedeem(issued);
        vm.roll(block.number + 1);
        uint64 epoch = manager.reportEpoch() + 1;
        uint64 referenceBlock = uint64(block.number - 1);
        bytes32 reportHash = keccak256("loss-ending-vest");
        vm.expectEmit(true, true, false, true, address(manager));
        emit AlphaEngineUSDCVaultManager.LossReported(epoch, referenceBlock, 45e6, 45e6, reportHash);
        vm.prank(NAV_REPORTER);
        manager.reportLoss(epoch, referenceBlock, 45e6, reportHash);
        assertEq(manager.managedAssets(), 1055e6);
        assertEq(manager.lockedProfit(), 0);
        assertEq(manager.lossToRecover(), 0);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), issued);
        assertEq(manager.previewRedeem(issued), beforeValue);
        _reportLoss(10e6);
        assertLt(manager.previewRedeem(issued), beforeValue);
    }

    function testLossOneUnitBelowRemainingProfitKeepsFinalUnitLocked() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);
        uint256 issued = fundVault.balanceOf(FEE_RECIPIENT);
        vm.warp(block.timestamp + 12 hours);
        _reportLoss(45e6 - 1);
        assertEq(manager.lockedProfit(), 1);
        assertEq(manager.remainingLockedProfit(), 1);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), issued);
        uint256 unlock = manager.profitUnlockTimestamp();
        vm.warp(unlock - 1);
        assertEq(manager.remainingLockedProfit(), 1);
        assertEq(manager.settleFinishedProfit(), 0);
        vm.warp(unlock);
        assertEq(manager.settleFinishedProfit(), 0);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), issued);
    }

    function testLossAfterUnlockKeepsUpfrontFeeSharesAndClearsVesting() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);
        uint256 issued = fundVault.balanceOf(FEE_RECIPIENT);
        vm.warp(manager.profitUnlockTimestamp());
        _reportLoss(50e6);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), issued);
        assertEq(manager.managedAssets(), 1050e6);
        assertEq(manager.lockedProfit(), 0);
        assertEq(manager.lossToRecover(), 50e6);
    }

    function testRecoveredLossDoesNotPayPerformanceFeeTwice() public {
        _deposit(USER, 1000e6);
        _reportLoss(100e6);
        assertEq(manager.lossToRecover(), 100e6);

        _reportProfit(60e6);
        assertEq(manager.lockedRecoveryProfit(), 60e6);
        assertEq(manager.lossToRecover(), 40e6);

        vm.warp(block.timestamp + VESTING_PERIOD);
        manager.settleFinishedProfit();
        _reportProfit(50e6);

        assertEq(manager.lockedRecoveryProfit(), 40e6);
        assertEq(manager.lossToRecover(), 0);
        assertGt(fundVault.balanceOf(FEE_RECIPIENT), 0);
    }

    function testRedemptionRemovesProportionalUnrecoveredLoss() public {
        _deposit(USER, 1000e6);
        _reportLoss(100e6);
        assertEq(manager.lossToRecover(), 100e6);

        uint64 requestId = _requestRedeem(USER, 500e18, 0);
        manager.completeRedeem(requestId);

        assertEq(manager.lossToRecover(), 50e6);
        assertEq(manager.managedAssets(), 450e6);
        assertEq(fundVault.totalSupply(), 500e18);

        _reportProfit(60e6);
        assertEq(manager.lossToRecover(), 0);
        assertEq(manager.lockedRecoveryProfit(), 50e6);
        assertGt(fundVault.balanceOf(FEE_RECIPIENT), 0);
    }

    function testLossDuringRecoveryRestoresLossToRecover() public {
        _deposit(USER, 1000e6);
        _reportLoss(100e6);
        _reportProfit(80e6);
        assertEq(manager.lossToRecover(), 20e6);

        _reportLoss(50e6);

        assertEq(manager.lockedProfit(), 30e6);
        assertEq(manager.lockedRecoveryProfit(), 30e6);
        assertEq(manager.lossToRecover(), 70e6);
    }

    function testOnlyReporterCanSubmitSequentialFinalizedReports() public {
        _deposit(USER, 1000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.UnauthorizedNAVReporter.selector, USER
            )
        );
        vm.prank(USER);
        manager.reportProfit(1, 99, 10e6, keccak256("unauthorized"));

        _reportProfit(10e6);

        vm.warp(block.timestamp + VESTING_PERIOD);
        manager.settleFinishedProfit();
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InvalidReportEpoch.selector, uint64(2), uint64(1)
            )
        );
        vm.prank(NAV_REPORTER);
        manager.reportProfit(1, uint64(block.number - 1), 10e6, keccak256("replay"));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.FutureReferenceBlock.selector,
                uint64(block.number),
                block.number
            )
        );
        vm.prank(NAV_REPORTER);
        manager.reportProfit(2, uint64(block.number), 10e6, keccak256("future"));
    }

    function testReportHashesBlocksAndLossBoundsAreStrict() public {
        vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroShares.selector);
        vm.prank(NAV_REPORTER);
        manager.reportProfit(1, 99, 1, keccak256("no-share-profit"));

        _deposit(USER, 100e6);
        vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroReportHash.selector);
        vm.prank(NAV_REPORTER);
        manager.reportProfit(1, 99, 1, bytes32(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.LossExceedsManagedAssets.selector, 100e6 + 1, 100e6
            )
        );
        vm.prank(NAV_REPORTER);
        manager.reportLoss(1, 99, 100e6 + 1, keccak256("excess-loss"));

        _reportLoss(1e6);
        uint64 lastReferenceBlock = manager.lastReferenceBlock();
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InvalidReferenceBlock.selector,
                lastReferenceBlock,
                lastReferenceBlock
            )
        );
        vm.prank(NAV_REPORTER);
        manager.reportLoss(2, lastReferenceBlock, 1, keccak256("non-monotonic-reference"));
    }

    function testNewProfitCannotOverwriteActiveVesting() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);

        vm.roll(block.number + 2);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineUSDCVaultManager.ProfitStillVesting.selector, 90e6)
        );
        vm.prank(NAV_REPORTER);
        manager.reportProfit(2, uint64(block.number - 1), 10e6, keccak256("overlapping-profit"));
    }

    function testAdminUpdatesAreBoundedAndDoNotMutateAccounting() public {
        _deposit(USER, 1000e6);
        uint256 priceBefore = _sharePrice();

        vm.expectEmit(true, true, false, false, address(manager));
        emit AlphaEngineUSDCVaultManager.NAVReporterUpdated(NAV_REPORTER, USER_TWO);
        manager.setNavReporter(USER_TWO);
        vm.expectEmit(false, false, false, true, address(manager));
        emit AlphaEngineUSDCVaultManager.PerformanceFeeUpdated(PERFORMANCE_FEE_BPS, 0);
        manager.setPerformanceFeeBps(0);
        vm.expectEmit(false, false, false, true, address(manager));
        emit AlphaEngineUSDCVaultManager.VestingPeriodUpdated(VESTING_PERIOD, 2 days);
        manager.setVestingPeriod(2 days);
        vm.expectEmit(true, true, false, false, address(manager));
        emit AlphaEngineUSDCVaultManager.FeeRecipientUpdated(FEE_RECIPIENT, USER);
        manager.setFeeRecipient(USER);

        assertEq(manager.navReporter(), USER_TWO);
        assertEq(manager.feeRecipient(), USER);
        assertEq(manager.performanceFeeBps(), 0);
        assertEq(manager.vestingPeriod(), 2 days);
        assertEq(_sharePrice(), priceBefore);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InvalidPerformanceFee.selector, uint16(2001)
            )
        );
        manager.setPerformanceFeeBps(2001);
    }

    function testActiveProfitKeepsIssuedFeeOwnershipAndVestingTerms() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);
        uint256 issued = fundVault.balanceOf(FEE_RECIPIENT);
        manager.setFeeRecipient(USER_TWO);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), issued);
        assertEq(fundVault.balanceOf(USER_TWO), 0);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineUSDCVaultManager.ProfitStillVesting.selector, 90e6)
        );
        manager.setVestingPeriod(2 days);
        assertEq(manager.feeRecipient(), USER_TWO);
        assertEq(manager.vestingPeriod(), VESTING_PERIOD);
    }

    function testZeroPerformanceFeeClearsWithoutMintingShares() public {
        manager.setPerformanceFeeBps(0);
        _deposit(USER, 1000e6);
        _reportProfit(100e6);
        uint256 supplyBefore = fundVault.totalSupply();

        vm.warp(block.timestamp + VESTING_PERIOD);
        uint256 minted = manager.settleFinishedProfit();

        assertEq(minted, 0);
        assertEq(fundVault.totalSupply(), supplyBefore);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), 0);
        assertEq(manager.lockedProfit(), 0);
    }

    function testPauseBlocksNewRiskButAllowsRedemptionCancellationAndCompletion() public {
        _deposit(USER, 1000e6);
        uint64 cancelId = _requestRedeem(USER, 100e18, 0);
        uint64 completeId = _requestRedeem(USER, 100e18, 0);
        manager.pause();
        fundVault.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(USER_TWO);
        manager.deposit(10e6, USER_TWO, 0);

        vm.prank(USER);
        manager.cancelRedeem(cancelId);
        manager.completeRedeem(completeId);

        assertEq(usdc.balanceOf(RECEIVER), 100e6);
    }

    function testFuzzDepositPreservesSharePrice(uint96 firstAssetsRaw, uint96 secondAssetsRaw)
        public
    {
        uint256 firstAssets = bound(uint256(firstAssetsRaw), 1e6, 1_000_000e6);
        uint256 secondAssets = bound(uint256(secondAssetsRaw), 1, 1_000_000e6);
        _deposit(USER, firstAssets);
        uint256 priceBefore = _sharePrice();

        _deposit(USER_TWO, secondAssets);

        assertApproxEqAbs(_sharePrice(), priceBefore, 1);
    }

    function testFuzzRedemptionPreservesSharePrice(uint96 assetsRaw, uint96 sharesRaw) public {
        uint256 assets = bound(uint256(assetsRaw), 1e6, 1_000_000e6);
        _deposit(USER, assets);
        uint256 shares = bound(uint256(sharesRaw), 1e12, fundVault.balanceOf(USER));
        uint64 requestId = _requestRedeem(USER, shares, 0);
        uint256 assetsBefore = manager.availableAssets();
        uint256 supplyBefore = fundVault.totalSupply();

        uint256 remainingSupply = supplyBefore - shares;
        if (remainingSupply != 0 && remainingSupply < 1e18) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineUSDCVaultManager.InsufficientShareSupply.selector,
                    remainingSupply,
                    1e18
                )
            );
            manager.completeRedeem(requestId);
            assertEq(manager.availableAssets(), assetsBefore);
            assertEq(fundVault.totalSupply(), supplyBefore);
            return;
        }
        manager.completeRedeem(requestId);

        uint256 assetsAfter = manager.availableAssets();
        uint256 supplyAfter = fundVault.totalSupply();
        if (supplyAfter != 0) {
            uint256 left = (assetsAfter + 1) * (supplyBefore + 1e12);
            uint256 right = (assetsBefore + 1) * (supplyAfter + 1e12);
            assertGe(left, right, "redemption must not dilute remaining shares");
            assertLt(
                left - right, supplyBefore + 1e12, "rounding residue must be below one USDC unit"
            );
        }
    }

    function testFuzzLinearVesting(uint96 profitRaw, uint32 elapsedRaw) public {
        _deposit(USER, 1_000_000e6);
        uint256 profit = bound(uint256(profitRaw), 1, 500_000e6);
        uint256 elapsed = bound(uint256(elapsedRaw), 0, VESTING_PERIOD);
        _reportProfit(profit);
        uint256 start = block.timestamp;

        vm.warp(start + elapsed);

        uint256 netProfit = profit - profit / 10;
        uint256 expectedRemaining = elapsed == VESTING_PERIOD
            ? 0
            : Math.mulDiv(netProfit, VESTING_PERIOD - elapsed, VESTING_PERIOD, Math.Rounding.Ceil);
        assertEq(manager.remainingLockedProfit(), expectedRemaining);
        assertEq(manager.availableAssets(), 1_000_000e6 + profit - expectedRemaining);
    }

    function testFuzzTreasuryNeverReceivesMoreThanFeeEntitlement(
        uint96 assetsRaw,
        uint96 profitRaw,
        uint16 feeRaw
    ) public {
        uint256 assets = bound(uint256(assetsRaw), 1e6, 1_000_000e6);
        uint256 profit = bound(uint256(profitRaw), 1, 1_000_000e6);
        uint16 feeBps = uint16(bound(uint256(feeRaw), 0, 2000));
        manager.setPerformanceFeeBps(feeBps);
        _deposit(USER, assets);
        _reportProfit(profit);
        uint256 feeAssets = Math.mulDiv(profit, feeBps, 10_000);

        uint256 treasuryShares = fundVault.balanceOf(FEE_RECIPIENT);
        uint256 expectedShares = Math.mulDiv(feeAssets, assets * 1e12 + 1e12, assets + 1);
        assertEq(treasuryShares, expectedShares);
        assertLe(manager.previewRedeem(treasuryShares), feeAssets);
        assertGe(manager.previewRedeem(treasuryShares) + 1, feeAssets);
        vm.warp(manager.profitUnlockTimestamp());
        assertEq(manager.settleFinishedProfit(), 0);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), treasuryShares);
    }

    /// @notice FV-01/FV-02: a funded, fee-free round trip may lose at most two USDC base units.
    function testRegression_FV01_roundingMustNotTransferDepositorPrincipal() public {
        manager.setPerformanceFeeBps(0);
        _deposit(USER, 100e6);
        usdc.mint(address(fundVault), 100e6);
        _reportProfit(100e6);
        uint64 dustRequest = _requestRedeem(USER, fundVault.balanceOf(USER) - 1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientShareSupply.selector, 1, 1e18
            )
        );
        manager.completeRedeem(dustRequest);
        vm.prank(USER);
        manager.cancelRedeem(dustRequest);
        manager.completeRedeem(_requestRedeem(USER, fundVault.balanceOf(USER) - 1e18, 0));
        assertEq(fundVault.totalSupply(), 1e18);
        vm.warp(manager.profitUnlockTimestamp());
        manager.settleFinishedProfit();

        uint256 shares = _deposit(USER_TWO, 199e6);
        uint256 received = manager.completeRedeem(_requestRedeem(USER_TWO, shares, 0));
        assertGe(received + 2, 199e6, "FV-01: incoming holder loses principal to rounding");
    }

    /// @notice FV-10: in a profit-only fixture an early exit cannot charge another LP's principal.
    function testRegression_FV10_earlyExitMustNotShiftFeesToRemainingPrincipal() public {
        manager.setPerformanceFeeBps(2000);
        manager.setVestingPeriod(100);
        _deposit(USER, 980e6);
        _deposit(USER_TWO, 20e6);
        usdc.mint(address(fundVault), 100e6);
        _reportProfit(100e6);
        vm.warp(manager.profitLockTimestamp() + 99);
        assertEq(manager.remainingLockedProfit(), 800_000);
        manager.completeRedeem(_requestRedeem(USER, 980e18, 0));
        vm.warp(manager.profitUnlockTimestamp());
        manager.settleFinishedProfit();
        uint256 remainingClaim = manager.previewRedeem(fundVault.balanceOf(USER_TWO));
        // This does not prescribe a new during-vesting pricing formula or fee equalization.
        assertGe(remainingClaim + 1, 20e6, "FV-10: profit-only fees consumed remaining principal");
    }

    /// @notice FV-11: earned fees cannot disappear solely because another holder exits.
    function testRegression_FV11_earnedFeeMustNotBeSilentlyCleared() public {
        manager.setPerformanceFeeBps(2000);
        manager.setVestingPeriod(100);
        _deposit(USER, 100e6);
        usdc.mint(address(fundVault), 100e6);
        _reportProfit(100e6);
        vm.warp(manager.profitLockTimestamp() + 99);
        // Retain the original independent 19.8-USDC fee-erasure regression floor.
        uint256 earnedBeforeExit = 19_800_000;
        manager.completeRedeem(_requestRedeem(USER, 99e18, 0));
        assertGt(fundVault.balanceOf(FEE_RECIPIENT), 0, "fee entitlement is already owned");
        vm.warp(manager.profitUnlockTimestamp());
        manager.settleFinishedProfit();
        uint256 settledValue = manager.previewRedeem(fundVault.balanceOf(FEE_RECIPIENT));
        assertGe(
            settledValue + 1,
            earnedBeforeExit,
            "FV-11: earned entitlement erased by supply/NAV reduction"
        );
    }

    function testMinimumSupplyAppliesBeforeDuringAndAfterVesting() public {
        manager.setPerformanceFeeBps(0);
        _deposit(USER, 100e6);
        for (uint256 phase; phase < 3; ++phase) {
            if (phase == 1) _reportProfit(1e6);
            if (phase == 2) vm.warp(manager.profitUnlockTimestamp());
            uint64 id = _requestRedeem(USER, 99e18 + 1, 0);
            vm.expectRevert(
                abi.encodeWithSelector(
                    AlphaEngineUSDCVaultManager.InsufficientShareSupply.selector, 1e18 - 1, 1e18
                )
            );
            manager.completeRedeem(id);
            assertEq(fundVault.totalSupply(), 100e18);
            assertEq(
                uint8(manager.getRedemption(id).status),
                uint8(AlphaEngineUSDCVaultManager.RedemptionStatus.Pending)
            );
            vm.prank(USER);
            manager.cancelRedeem(id);
        }
        manager.completeRedeem(_requestRedeem(USER, 99e18, 0));
        assertEq(fundVault.totalSupply(), 1e18);
    }

    function testBootstrapMinimumDoesNotRejectSmallDepositsIntoFundedVault() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientShareSupply.selector, 1e18 - 1e12, 1e18
            )
        );
        vm.prank(USER);
        manager.deposit(1e6 - 1, USER, 0);
        _deposit(USER, 1e6);
        assertEq(_deposit(USER_TWO, 1), 1e12);
        assertEq(fundVault.totalSupply(), 1e18 + 1e12);
    }

    function testFinalResidualPaysProtocolAndAllowsCleanReentry() public {
        manager.setPerformanceFeeBps(0);
        _deposit(USER, 100e6);
        usdc.mint(address(fundVault), 100e6);
        _reportProfit(100e6);
        manager.completeRedeem(_requestRedeem(USER, 99e18, 0));
        vm.warp(manager.profitUnlockTimestamp());
        uint256 quote = manager.previewRedeem(1e18);
        uint256 residual = manager.managedAssets() - quote;
        uint64 id = _requestRedeem(USER, 1e18, 0);
        vm.prank(address(fundVault));
        usdc.transfer(USER, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientVaultLiquidity.selector,
                manager.managedAssets() - 1,
                manager.managedAssets()
            )
        );
        manager.completeRedeem(id);
        usdc.mint(address(fundVault), 1);
        vm.expectEmit(true, false, false, true, address(fundVault));
        emit AlphaEngineFundVault.ProtocolResidualSettled(FEE_RECIPIENT, residual);
        assertEq(manager.completeRedeem(id), quote);
        assertEq(usdc.balanceOf(FEE_RECIPIENT), residual);
        assertEq(manager.managedAssets(), 0);
        assertEq(fundVault.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(fundVault)), 0);
        assertEq(_deposit(USER_TWO, 1e6), 1e18);
    }

    function testResidualPayoutIsManagerOnlyAndRequiresEmptySupply() public {
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.UnauthorizedUSDCManager.selector, USER)
        );
        vm.prank(USER);
        fundVault.settleProtocolResidual(USER, 1);
        _deposit(USER, 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.OutstandingShares.selector, 1e18)
        );
        vm.prank(address(manager));
        fundVault.settleProtocolResidual(FEE_RECIPIENT, 1);
        vm.expectRevert(AlphaEngineFundVault.ZeroAddress.selector);
        vm.prank(address(manager));
        fundVault.settleProtocolResidual(address(0), 1);
        vm.expectRevert(AlphaEngineFundVault.ZeroAssets.selector);
        vm.prank(address(manager));
        fundVault.settleProtocolResidual(FEE_RECIPIENT, 0);
    }

    function testUnrepresentablePositiveFeeRevertsWithoutErasingEntitlement() public {
        manager.setPerformanceFeeBps(0);
        _deposit(USER, 1e6);
        _reportProfit(1e40);
        vm.warp(manager.profitUnlockTimestamp());
        manager.settleFinishedProfit();
        manager.setPerformanceFeeBps(2000);
        vm.roll(block.number + 1);
        uint256 beforeNav = manager.managedAssets();
        uint64 beforeEpoch = manager.reportEpoch();
        vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroShares.selector);
        vm.prank(NAV_REPORTER);
        manager.reportProfit(
            beforeEpoch + 1, uint64(block.number - 1), 5, keccak256("unrepresentable fee")
        );
        assertEq(manager.managedAssets(), beforeNav);
        assertEq(manager.reportEpoch(), beforeEpoch);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), 0);
    }

    function testRecoveryIsNotFeeableAndFeeSharesUseTheCurrentPrice() public {
        manager.setPerformanceFeeBps(2000);
        _deposit(USER, 100_000e6);
        _reportLoss(10_000e6);
        uint256 beforeSupply = fundVault.totalSupply();
        _reportProfit(10_100e6); // 10,000 recovery + 100 new profit; fee = 20.
        uint256 issued = fundVault.balanceOf(FEE_RECIPIENT);
        assertEq(issued, Math.mulDiv(20e6, beforeSupply + 1e12, 90_000e6 + 1));
        assertApproxEqAbs(manager.previewRedeem(issued), 20e6, 1);
        assertEq(manager.lockedRecoveryProfit(), 10_000e6);
        assertEq(manager.lockedProfit(), 10_080e6);
        vm.warp(manager.profitUnlockTimestamp());
        // Issued fee shares participate in subsequent vesting like all other shares.
        assertApproxEqAbs(manager.previewRedeem(issued), 22_239_502, 1);
    }

    function _deposit(address user, uint256 assets) private returns (uint256 shares) {
        vm.prank(user);
        shares = manager.deposit(assets, user, 0);
    }

    function _requestRedeem(address user, uint256 shares, uint256 minAssets)
        private
        returns (uint64 requestId)
    {
        vm.prank(user);
        fundVault.approve(address(manager), shares);
        vm.prank(user);
        requestId = manager.requestRedeem(shares, RECEIVER, minAssets);
    }

    function _reportProfit(uint256 profit) private {
        uint64 referenceBlock = manager.lastReferenceBlock() + 1;
        if (referenceBlock == 1) referenceBlock = 99;
        vm.roll(uint256(referenceBlock) + 1);
        uint64 epoch = manager.reportEpoch() + 1;
        vm.prank(NAV_REPORTER);
        manager.reportProfit(
            epoch, referenceBlock, profit, keccak256(abi.encode("profit", epoch, profit))
        );
    }

    function _reportLoss(uint256 loss) private {
        uint64 referenceBlock = manager.lastReferenceBlock() + 1;
        if (referenceBlock == 1) referenceBlock = 99;
        vm.roll(uint256(referenceBlock) + 1);
        uint64 epoch = manager.reportEpoch() + 1;
        vm.prank(NAV_REPORTER);
        manager.reportLoss(epoch, referenceBlock, loss, keccak256(abi.encode("loss", epoch, loss)));
    }

    function _sharePrice() private view returns (uint256) {
        uint256 supply = fundVault.totalSupply();
        if (supply == 0) return 1e6;
        return Math.mulDiv(manager.availableAssets(), 1e18, supply);
    }
}
