// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {AlphaEngineUSDCVaultManager} from "src/vault/AlphaEngineUSDCVaultManager.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract USDCVaultInvariantHandler is Test {
    uint256 public constant ACTOR_COUNT = 3;
    uint256 private constant MAX_ACTION_ASSETS = 1_000_000e6;

    MockERC20 public immutable USDC;
    AlphaEngineFundVault public immutable FUND_VAULT;
    AlphaEngineUSDCVaultManager public immutable MANAGER;
    address public immutable FEE_RECIPIENT;
    address public immutable STRATEGY;

    address[ACTOR_COUNT] private _actors;
    uint64[] private _requestIds;

    uint256 public ghostManagedAssets;
    uint256 public ghostDepositedUsdc;
    uint256 public ghostRedeemedUsdc;
    uint256 public ghostDonations;
    uint256 public ghostDeployedUsdc;
    uint256 public ghostCompletedRedemptionAssets;
    uint256 public ghostReportedProfit;
    uint256 public ghostReportedLoss;

    uint256 public successfulDeposits;
    uint256 public successfulRequests;
    uint256 public successfulCancellations;
    uint256 public successfulCompletions;
    uint256 public successfulProfitReports;
    uint256 public successfulLossReports;
    uint256 public successfulFeeSettlements;
    uint256 public expectedIlliquidCompletions;

    bool public depositPriceViolation;
    bool public redemptionPriceViolation;
    bool public feeOverchargeViolation;
    bool public failedCompletionMutation;
    bool public lossRecoveryFlowViolation;

    constructor(
        MockERC20 usdc,
        AlphaEngineFundVault fundVault,
        AlphaEngineUSDCVaultManager manager,
        address feeRecipient,
        address strategy
    ) {
        USDC = usdc;
        FUND_VAULT = fundVault;
        MANAGER = manager;
        FEE_RECIPIENT = feeRecipient;
        STRATEGY = strategy;

        for (uint256 index = 0; index < ACTOR_COUNT; ++index) {
            address actor = address(uint160(uint256(keccak256(abi.encode("vault actor", index)))));
            _actors[index] = actor;
            vm.prank(actor);
            USDC.approve(address(FUND_VAULT), type(uint256).max);
            vm.prank(actor);
            FUND_VAULT.approve(address(MANAGER), type(uint256).max);
        }
    }

    function deposit(uint256 actorSeed, uint96 rawAssets) public {
        address actor = actorAt(actorSeed);
        uint256 assets = bound(uint256(rawAssets), 1, MAX_ACTION_ASSETS);
        _settleFinishedProfit();
        uint256 lossToRecoverBefore = MANAGER.lossToRecover();
        uint256 supplyBefore = FUND_VAULT.totalSupply();
        uint256 assetsBefore = MANAGER.availableAssets();
        if (supplyBefore != 0 && assetsBefore == 0) return;

        USDC.mint(actor, assets);
        vm.prank(actor);
        MANAGER.deposit(assets, actor, 0);

        ghostManagedAssets += assets;
        ghostDepositedUsdc += assets;
        successfulDeposits += 1;
        if (MANAGER.lossToRecover() != lossToRecoverBefore) lossRecoveryFlowViolation = true;

        if (supplyBefore != 0) {
            uint256 left = MANAGER.availableAssets() * supplyBefore;
            uint256 right = assetsBefore * FUND_VAULT.totalSupply();
            if (left < right || left - right >= assetsBefore) depositPriceViolation = true;
        }
    }

    function requestRedeem(uint256 actorSeed, uint96 rawShares) public {
        address actor = actorAt(actorSeed);
        uint256 balance = FUND_VAULT.balanceOf(actor);
        if (balance == 0) return;

        uint256 shares = bound(uint256(rawShares), 1, balance);
        vm.prank(actor);
        uint64 requestId = MANAGER.requestRedeem(shares, actor, 0);
        _requestIds.push(requestId);
        successfulRequests += 1;
    }

    function cancelRedeem(uint256 requestSeed) public {
        (uint64 requestId, bool found) = _pendingRequest(requestSeed);
        if (!found) return;
        AlphaEngineUSDCVaultManager.RedemptionRequest memory request =
            MANAGER.getRedemption(requestId);

        vm.prank(request.owner);
        MANAGER.cancelRedeem(requestId);
        successfulCancellations += 1;
    }

    function completeRedeem(uint256 requestSeed) public {
        (uint64 requestId, bool found) = _pendingRequest(requestSeed);
        if (!found) return;
        _settleFinishedProfit();
        AlphaEngineUSDCVaultManager.RedemptionRequest memory request =
            MANAGER.getRedemption(requestId);

        uint256 remainingProfit = MANAGER.remainingLockedProfit();
        if (request.shares == FUND_VAULT.totalSupply() && remainingProfit != 0) return;

        uint256 assets = MANAGER.previewRedeem(request.shares);
        if (USDC.balanceOf(address(FUND_VAULT)) < assets) return;

        uint256 assetsBefore = MANAGER.availableAssets();
        uint256 supplyBefore = FUND_VAULT.totalSupply();
        uint256 lossToRecoverBefore = MANAGER.lossToRecover();
        MANAGER.completeRedeem(requestId);

        ghostManagedAssets -= assets;
        ghostRedeemedUsdc += assets;
        ghostCompletedRedemptionAssets += assets;
        successfulCompletions += 1;

        uint256 supplyAfter = FUND_VAULT.totalSupply();
        uint256 expectedLossToRecover = supplyAfter == 0
            ? 0
            : Math.mulDiv(lossToRecoverBefore, supplyAfter, supplyBefore, Math.Rounding.Ceil);
        if (MANAGER.lossToRecover() != expectedLossToRecover) {
            lossRecoveryFlowViolation = true;
        }
        if (supplyAfter != 0) {
            uint256 left = MANAGER.availableAssets() * supplyBefore;
            uint256 right = assetsBefore * supplyAfter;
            if (left < right || left - right >= supplyBefore) redemptionPriceViolation = true;
        }
    }

    function attemptIlliquidCompletion(uint256 requestSeed) public {
        (uint64 requestId, bool found) = _pendingRequest(requestSeed);
        if (!found) return;
        AlphaEngineUSDCVaultManager.RedemptionRequest memory request =
            MANAGER.getRedemption(requestId);
        uint256 remainingProfit = MANAGER.remainingLockedProfit();
        if (request.shares == FUND_VAULT.totalSupply() && remainingProfit != 0) return;

        uint256 assets = MANAGER.previewRedeem(request.shares);
        uint256 available = USDC.balanceOf(address(FUND_VAULT));
        if (assets == 0 || available >= assets) return;

        uint256 managedBefore = MANAGER.managedAssets();
        uint256 supplyBefore = FUND_VAULT.totalSupply();
        uint256 escrowBefore = FUND_VAULT.balanceOf(address(FUND_VAULT));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientVaultLiquidity.selector, available, assets
            )
        );
        MANAGER.completeRedeem(requestId);

        if (
            MANAGER.managedAssets() != managedBefore || FUND_VAULT.totalSupply() != supplyBefore
                || FUND_VAULT.balanceOf(address(FUND_VAULT)) != escrowBefore
        ) failedCompletionMutation = true;
        expectedIlliquidCompletions += 1;
    }

    function reportProfit(uint96 rawProfit) public {
        if (FUND_VAULT.totalSupply() == 0 || MANAGER.remainingLockedProfit() != 0) return;
        uint256 profit = bound(uint256(rawProfit), 1, MAX_ACTION_ASSETS);
        (uint64 epoch, uint64 referenceBlock) = _nextReport();

        MANAGER.reportProfit(
            epoch, referenceBlock, profit, keccak256(abi.encode("invariant profit", epoch, profit))
        );
        ghostManagedAssets += profit;
        ghostReportedProfit += profit;
        successfulProfitReports += 1;
    }

    function reportLoss(uint96 rawLoss) public {
        uint256 managed = MANAGER.managedAssets();
        if (managed == 0) return;
        uint256 loss = bound(uint256(rawLoss), 1, managed);
        (uint64 epoch, uint64 referenceBlock) = _nextReport();

        MANAGER.reportLoss(
            epoch, referenceBlock, loss, keccak256(abi.encode("invariant loss", epoch, loss))
        );
        ghostManagedAssets -= loss;
        ghostReportedLoss += loss;
        successfulLossReports += 1;
    }

    function advanceTime(uint32 rawSeconds) public {
        uint256 elapsed = bound(uint256(rawSeconds), 1, 2 days);
        vm.warp(block.timestamp + elapsed);
    }

    function settleFinishedProfit() public {
        _settleFinishedProfit();
    }

    function _settleFinishedProfit() private {
        uint256 feeAssets = MANAGER.pendingFeeAssets();
        uint256 sharesBefore = FUND_VAULT.balanceOf(FEE_RECIPIENT);
        uint256 minted = MANAGER.settleFinishedProfit();
        if (minted == 0) return;

        uint256 received = FUND_VAULT.balanceOf(FEE_RECIPIENT) - sharesBefore;
        if (received != minted || MANAGER.previewRedeem(received) > feeAssets) {
            feeOverchargeViolation = true;
        }
        successfulFeeSettlements += 1;
    }

    function deployLiquidity(uint96 rawAssets) public {
        uint256 available = USDC.balanceOf(address(FUND_VAULT));
        if (available == 0) return;
        uint256 assets = bound(uint256(rawAssets), 1, available);

        vm.prank(address(FUND_VAULT));
        assertTrue(USDC.transfer(STRATEGY, assets));
        ghostDeployedUsdc += assets;
    }

    function returnLiquidity(uint96 rawAssets) public {
        uint256 deployed = USDC.balanceOf(STRATEGY);
        if (deployed == 0) return;
        uint256 assets = bound(uint256(rawAssets), 1, deployed);

        vm.prank(STRATEGY);
        assertTrue(USDC.transfer(address(FUND_VAULT), assets));
        ghostDeployedUsdc -= assets;
    }

    function donate(uint96 rawAssets) public {
        uint256 assets = bound(uint256(rawAssets), 1, MAX_ACTION_ASSETS);
        USDC.mint(address(FUND_VAULT), assets);
        ghostDonations += assets;
    }

    function actorAt(uint256 seed) public view returns (address) {
        return _actors[seed % ACTOR_COUNT];
    }

    function requestCount() external view returns (uint256) {
        return _requestIds.length;
    }

    function requestAt(uint256 index) external view returns (uint64) {
        return _requestIds[index];
    }

    function pendingRedemptionShares() external view returns (uint256 total) {
        uint256 length = _requestIds.length;
        for (uint256 index = 0; index < length; ++index) {
            AlphaEngineUSDCVaultManager.RedemptionRequest memory request =
                MANAGER.getRedemption(_requestIds[index]);
            if (request.status == AlphaEngineUSDCVaultManager.RedemptionStatus.Pending) {
                total += request.shares;
            }
        }
    }

    function trackedShareSupply() external view returns (uint256 total) {
        for (uint256 index = 0; index < ACTOR_COUNT; ++index) {
            total += FUND_VAULT.balanceOf(_actors[index]);
        }
        total += FUND_VAULT.balanceOf(FEE_RECIPIENT);
        total += FUND_VAULT.balanceOf(address(FUND_VAULT));
    }

    function _pendingRequest(uint256 seed) private view returns (uint64 requestId, bool found) {
        uint256 length = _requestIds.length;
        if (length == 0) return (0, false);

        uint256 start = seed % length;
        for (uint256 offset = 0; offset < length; ++offset) {
            requestId = _requestIds[(start + offset) % length];
            if (
                MANAGER.getRedemption(requestId).status
                    == AlphaEngineUSDCVaultManager.RedemptionStatus.Pending
            ) return (requestId, true);
        }
        return (0, false);
    }

    function _nextReport() private returns (uint64 epoch, uint64 referenceBlock) {
        epoch = MANAGER.reportEpoch() + 1;
        referenceBlock = MANAGER.lastReferenceBlock() + 1;
        if (referenceBlock >= block.number) vm.roll(uint256(referenceBlock) + 1);
    }
}
