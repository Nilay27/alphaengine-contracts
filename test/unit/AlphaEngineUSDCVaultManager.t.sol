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
        fundVault.setUsdcManager(address(manager));
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

        vm.expectRevert(AlphaEngineFundVault.ZeroAddress.selector);
        vault.unpause();
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
        vm.prank(NAV_REPORTER);
        manager.reportProfit(1, 99, 100e6, profitHash);

        vm.roll(101);
        bytes32 lossHash = keccak256("event-loss");
        vm.expectEmit(true, true, false, true, address(manager));
        emit AlphaEngineUSDCVaultManager.LossReported(2, 100, 20e6, 20e6, lossHash);
        vm.prank(NAV_REPORTER);
        manager.reportLoss(2, 100, 20e6, lossHash);

        vm.warp(block.timestamp + VESTING_PERIOD);
        uint256 feeAssets = 8e6;
        uint256 feeShares = Math.mulDiv(feeAssets, fundVault.totalSupply(), 980e6 - feeAssets);
        vm.expectEmit(true, false, false, true, address(fundVault));
        emit AlphaEngineFundVault.FeeSharesMinted(FEE_RECIPIENT, feeShares);
        vm.expectEmit(true, false, false, true, address(manager));
        emit AlphaEngineUSDCVaultManager.PerformanceFeeMinted(FEE_RECIPIENT, feeAssets, feeShares);
        assertEq(manager.settleFinishedProfit(), feeShares);

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
        feeVault.setUsdcManager(address(feeManager));
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
        _deposit(USER, 1000e6);
        uint64 requestId = _requestRedeem(USER, 1000e18, 0);
        _reportProfit(100e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.FinalRedemptionWhileProfitLocked.selector, 100e6
            )
        );
        manager.completeRedeem(requestId);

        vm.warp(block.timestamp + VESTING_PERIOD);
        usdc.mint(address(fundVault), 100e6);
        manager.completeRedeem(requestId);
        assertGt(fundVault.totalSupply(), 0, "fee recipient remains a shareholder");
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

    function testProfitVestsLinearlyAndFeeMintsAfterVesting() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);

        assertEq(manager.managedAssets(), 1100e6);
        assertEq(manager.lockedProfit(), 100e6);
        assertEq(manager.pendingFeeAssets(), 10e6);
        assertEq(manager.availableAssets(), 1000e6);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), 0);

        uint256 vestingStart = block.timestamp;
        vm.warp(vestingStart + 12 hours);
        assertApproxEqAbs(manager.remainingLockedProfit(), 50e6, 1);
        assertApproxEqAbs(manager.availableAssets(), 1050e6, 1);

        vm.warp(vestingStart + VESTING_PERIOD);
        uint256 expectedFeeShares = Math.mulDiv(10e6, 1000e18, 1100e6 - 10e6);
        uint256 minted = manager.settleFinishedProfit();

        assertEq(minted, expectedFeeShares);
        assertEq(fundVault.balanceOf(FEE_RECIPIENT), expectedFeeShares);
        assertEq(manager.lockedProfit(), 0);
        assertEq(manager.pendingFeeAssets(), 0);
        assertEq(manager.availableAssets(), 1100e6);
        assertLe(
            manager.previewRedeem(expectedFeeShares),
            10e6,
            "treasury share value must not exceed the fee"
        );
    }

    function testPerformanceFeeUpdateIsProspective() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);
        assertEq(manager.pendingFeeAssets(), 10e6);

        manager.setPerformanceFeeBps(2000);
        assertEq(manager.pendingFeeAssets(), 10e6);

        vm.warp(block.timestamp + VESTING_PERIOD);
        manager.settleFinishedProfit();
        _reportProfit(100e6);
        assertEq(manager.pendingFeeAssets(), 20e6);
    }

    function testLossImmediatelyCancelsLockedProfitThenShareValue() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);
        vm.warp(block.timestamp + 12 hours);

        uint256 availableBefore = manager.availableAssets();
        _reportLoss(60e6);

        assertEq(manager.managedAssets(), 1040e6);
        assertEq(manager.lockedProfit(), 0);
        assertEq(manager.availableAssets(), 1040e6);
        assertApproxEqAbs(availableBefore - manager.availableAssets(), 10e6, 1);
        assertEq(manager.pendingFeeAssets(), 0);
        assertApproxEqAbs(manager.lossToRecover(), 10e6, 1);
    }

    function testRecoveredLossDoesNotPayPerformanceFeeTwice() public {
        _deposit(USER, 1000e6);
        _reportLoss(100e6);
        assertEq(manager.lossToRecover(), 100e6);

        _reportProfit(60e6);
        assertEq(manager.lockedRecoveryProfit(), 60e6);
        assertEq(manager.pendingFeeAssets(), 0);
        assertEq(manager.lossToRecover(), 40e6);

        vm.warp(block.timestamp + VESTING_PERIOD);
        manager.settleFinishedProfit();
        _reportProfit(50e6);

        assertEq(manager.lockedRecoveryProfit(), 40e6);
        assertEq(manager.lossToRecover(), 0);
        assertEq(manager.pendingFeeAssets(), 1e6);
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
        assertEq(manager.pendingFeeAssets(), 1e6);
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
            abi.encodeWithSelector(AlphaEngineUSDCVaultManager.ProfitStillVesting.selector, 100e6)
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

    function testActiveProfitProtectsFeeRecipientAndVestingTerms() public {
        _deposit(USER, 1000e6);
        _reportProfit(100e6);

        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineUSDCVaultManager.ActiveFeePending.selector, 10e6)
        );
        manager.setFeeRecipient(USER_TWO);

        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineUSDCVaultManager.ProfitStillVesting.selector, 100e6)
        );
        manager.setVestingPeriod(2 days);

        assertEq(manager.feeRecipient(), FEE_RECIPIENT);
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
        assertEq(manager.pendingFeeAssets(), 0);
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

        manager.completeRedeem(requestId);

        uint256 assetsAfter = manager.availableAssets();
        uint256 supplyAfter = fundVault.totalSupply();
        if (supplyAfter != 0) {
            uint256 left = assetsAfter * supplyBefore;
            uint256 right = assetsBefore * supplyAfter;
            assertGe(left, right, "redemption must not dilute remaining shares");
            assertLt(left - right, supplyBefore, "rounding residue must be below one USDC unit");
        }
    }

    function testFuzzLinearVesting(uint96 profitRaw, uint32 elapsedRaw) public {
        _deposit(USER, 1_000_000e6);
        uint256 profit = bound(uint256(profitRaw), 1, 500_000e6);
        uint256 elapsed = bound(uint256(elapsedRaw), 0, VESTING_PERIOD);
        _reportProfit(profit);
        uint256 start = block.timestamp;

        vm.warp(start + elapsed);

        uint256 expectedRemaining = Math.mulDiv(profit, VESTING_PERIOD - elapsed, VESTING_PERIOD);
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

        vm.warp(block.timestamp + VESTING_PERIOD);
        manager.settleFinishedProfit();

        uint256 treasuryShares = fundVault.balanceOf(FEE_RECIPIENT);
        assertLe(manager.previewRedeem(treasuryShares), feeAssets);
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
