// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {AlphaEngineERC20DecoderAndSanitizer} from
    "src/decoders/AlphaEngineERC20DecoderAndSanitizer.sol";
import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";
import {AlphaEngineExecutionHashLib} from "src/libraries/AlphaEngineExecutionHashLib.sol";
import {AlphaEngineManageLeafHashLib} from "src/libraries/AlphaEngineManageLeafHashLib.sol";
import {AlphaEngineRollingSpendLib} from "src/libraries/AlphaEngineRollingSpendLib.sol";
import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {AlphaEngineVaultExecutionManager} from "src/vault/AlphaEngineVaultExecutionManager.sol";
import {MockERC20, MockStickyAllowanceERC20} from "test/mocks/MockERC20.sol";
import {MockFundVaultCallTarget, MockRecoveryVault} from "test/mocks/MockFundVaultExecution.sol";
import {
    MockCapitalStrategyManagerStage16,
    MockStrategyActionDecoder,
    MockVaultStrategyTarget
} from "test/mocks/MockVaultExecutionStage16.sol";

contract RollingSpendHarness {
    using AlphaEngineRollingSpendLib for AlphaEngineRollingSpendLib.SpendWindow;

    AlphaEngineRollingSpendLib.SpendWindow private _window;

    function consume(uint256 amount) external returns (uint256) {
        return _window.consume(amount);
    }

    function current() external view returns (uint256) {
        return _window.current();
    }
}

contract AlphaEngineVaultExecutionManagerTest is Test {
    address private constant ROOT_PROPOSER = address(0xA11CE);
    address private constant ROOT_GUARDIAN = address(0xB0B);
    address private constant EXECUTOR = address(0xE0);
    address private constant SECOND_EXECUTOR = address(0xE1);
    address private constant TRADER = address(0x7A);
    address private constant STRANGER = address(0xBAD);
    bytes32 private constant ARTIFACT_HASH = keccak256("reviewed policy artifact");
    uint256 private constant INITIAL_INPUT_BALANCE = 1000e6;
    uint256 private constant INITIAL_OUTPUT_BALANCE = 1000e18;

    MockERC20 private assetIn;
    MockERC20 private assetOut;
    MockCapitalStrategyManagerStage16 private capitalManager;
    AlphaEngineFundVault private fundVault;
    AlphaEngineVaultExecutionManager private executionManager;
    AlphaEngineERC20DecoderAndSanitizer private erc20Decoder;
    MockStrategyActionDecoder private strategyDecoder;
    MockVaultStrategyTarget private strategyTarget;
    MockFundVaultCallTarget private accountingManager;
    MockRecoveryVault private recoveryVault;

    bytes32 private policyRoot;
    bytes32 private approvalLeaf;
    bytes32 private strategyLeaf;

    function setUp() public {
        assetIn = new MockStickyAllowanceERC20("USD Coin", "USDC", 6);
        assetOut = new MockERC20("Position Token", "PT", 18);
        capitalManager = new MockCapitalStrategyManagerStage16();
        fundVault = new AlphaEngineFundVault(address(this), assetIn);
        executionManager = new AlphaEngineVaultExecutionManager(
            address(this),
            ROOT_PROPOSER,
            ROOT_GUARDIAN,
            capitalManager,
            IAlphaEngineFundVault(address(fundVault))
        );
        erc20Decoder = new AlphaEngineERC20DecoderAndSanitizer();
        strategyDecoder = new MockStrategyActionDecoder();
        strategyTarget = new MockVaultStrategyTarget();
        accountingManager = new MockFundVaultCallTarget();
        recoveryVault = new MockRecoveryVault();

        fundVault.setUsdcManager(address(accountingManager));
        fundVault.setExecutionManager(address(executionManager));
        fundVault.setEmergencyConfiguration(ROOT_GUARDIAN, address(recoveryVault));
        fundVault.unpause();

        assetIn.mint(address(fundVault), INITIAL_INPUT_BALANCE);
        assetOut.mint(address(strategyTarget), INITIAL_OUTPUT_BALANCE);

        _setRiskLimit(TRADER, address(assetIn), 200e6, 300e6);
        (approvalLeaf, strategyLeaf, policyRoot) = _policyLeaves();
        _activateRoot(EXECUTOR, policyRoot);
        executionManager.unpause();
    }

    function testExecutesExactApprovedBundleAndClearsAllowance() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(100e6, 90e18, 100e6, 90e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("intent-1"), 0, calls, limits);
        bytes32 commitment = capitalManager.approve(authorization);

        vm.prank(EXECUTOR);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        assertEq(assetIn.balanceOf(address(fundVault)), INITIAL_INPUT_BALANCE - 100e6);
        assertEq(assetOut.balanceOf(address(fundVault)), 90e18);
        assertEq(assetIn.allowance(address(fundVault), address(strategyTarget)), 0);
        assertTrue(executionManager.consumedExecutionCommitments(commitment));
        assertTrue(executionManager.consumedAuthorizationNonces(0));
        assertTrue(capitalManager.isExecutionConsumed(commitment));
        assertEq(executionManager.currentWindowSpend(TRADER, address(assetIn)), 100e6);
    }

    function testRootIsDelayedExecutorBoundCancellableAndEmergencyRevocable() public {
        bytes32 nextRoot = keccak256("second-executor-root");
        uint40 activateAfter = uint40(block.timestamp + 48 hours);

        vm.prank(ROOT_PROPOSER);
        executionManager.proposePolicyRoot(
            SECOND_EXECUTOR, nextRoot, keccak256("second artifact"), activateAfter
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.RootActivationNotReady.selector,
                activateAfter,
                block.timestamp
            )
        );
        executionManager.activatePolicyRoot(SECOND_EXECUTOR);

        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.UnauthorizedPolicyCancellation.selector, STRANGER
            )
        );
        executionManager.cancelPolicyRootProposal(SECOND_EXECUTOR);

        vm.prank(ROOT_GUARDIAN);
        executionManager.cancelPolicyRootProposal(SECOND_EXECUTOR);

        vm.prank(ROOT_PROPOSER);
        executionManager.proposePolicyRoot(
            SECOND_EXECUTOR, nextRoot, keccak256("second artifact"), activateAfter
        );
        vm.warp(activateAfter);
        executionManager.activatePolicyRoot(SECOND_EXECUTOR);
        (bytes32 activeRoot,, uint64 version) = executionManager.activePolicies(SECOND_EXECUTOR);
        assertEq(activeRoot, nextRoot);
        assertEq(version, 1);

        vm.prank(ROOT_GUARDIAN);
        executionManager.revokePolicyRoot(SECOND_EXECUTOR);
        (activeRoot,, version) = executionManager.activePolicies(SECOND_EXECUTOR);
        assertEq(activeRoot, bytes32(0));
        assertEq(version, 2);
        assertTrue(executionManager.paused());
    }

    function testRootProposalRequiresFullDelayAndCannotOverwritePendingRoot() public {
        uint40 earliest = uint40(block.timestamp + 48 hours);
        vm.prank(ROOT_PROPOSER);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.RootActivationTooEarly.selector,
                earliest - 1,
                earliest
            )
        );
        executionManager.proposePolicyRoot(
            SECOND_EXECUTOR, keccak256("root"), ARTIFACT_HASH, earliest - 1
        );

        vm.prank(ROOT_PROPOSER);
        executionManager.proposePolicyRoot(
            SECOND_EXECUTOR, keccak256("root"), ARTIFACT_HASH, earliest
        );
        vm.prank(ROOT_PROPOSER);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.PolicyRootAlreadyPending.selector, SECOND_EXECUTOR
            )
        );
        executionManager.proposePolicyRoot(
            SECOND_EXECUTOR, keccak256("replacement"), ARTIFACT_HASH, earliest
        );
    }

    function testPolicyRootInputsAndMissingStateFailClosed() public {
        uint40 activateAfter = uint40(block.timestamp + 48 hours);
        vm.startPrank(ROOT_PROPOSER);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.ZeroAddress.selector, bytes32("executor")
            )
        );
        executionManager.proposePolicyRoot(
            address(0), keccak256("root"), ARTIFACT_HASH, activateAfter
        );
        vm.expectRevert(AlphaEngineVaultExecutionManager.ZeroPolicyRoot.selector);
        executionManager.proposePolicyRoot(
            SECOND_EXECUTOR, bytes32(0), ARTIFACT_HASH, activateAfter
        );
        vm.expectRevert(AlphaEngineVaultExecutionManager.ZeroArtifactHash.selector);
        executionManager.proposePolicyRoot(
            SECOND_EXECUTOR, keccak256("root"), bytes32(0), activateAfter
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.PolicyRootUnchanged.selector, EXECUTOR, policyRoot
            )
        );
        executionManager.proposePolicyRoot(EXECUTOR, policyRoot, ARTIFACT_HASH, activateAfter);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.NoPendingPolicyRoot.selector, SECOND_EXECUTOR
            )
        );
        executionManager.activatePolicyRoot(SECOND_EXECUTOR);
        vm.prank(ROOT_GUARDIAN);
        vm.expectRevert(AlphaEngineVaultExecutionManager.ZeroPolicyRoot.selector);
        executionManager.revokePolicyRoot(SECOND_EXECUTOR);
    }

    function testRiskConfigurationRejectsMeaninglessOrAmbiguousUpdates() public {
        vm.prank(ROOT_GUARDIAN);
        executionManager.pause();

        AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[] memory inputs =
            new AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[](0);
        vm.expectRevert(AlphaEngineVaultExecutionManager.EmptyRiskLimitUpdate.selector);
        executionManager.setTraderAssetRiskLimits(TRADER, inputs);

        inputs = new AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[](17);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.TooManyRiskLimitUpdates.selector, 17, 16
            )
        );
        executionManager.setTraderAssetRiskLimits(TRADER, inputs);

        inputs = new AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[](1);
        inputs[0] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput({
            asset: STRANGER,
            maxSpendPerExecution: 1,
            maxSpendPer24Hours: 1
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.InvalidRiskAsset.selector, 0, STRANGER
            )
        );
        executionManager.setTraderAssetRiskLimits(TRADER, inputs);

        inputs[0] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput({
            asset: address(assetOut),
            maxSpendPerExecution: 2,
            maxSpendPer24Hours: 1
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.InvalidRiskLimit.selector, address(assetOut), 2, 1
            )
        );
        executionManager.setTraderAssetRiskLimits(TRADER, inputs);

        inputs[0] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput({
            asset: address(assetIn),
            maxSpendPerExecution: 200e6,
            maxSpendPer24Hours: 300e6
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.RiskLimitUnchanged.selector,
                TRADER,
                address(assetIn)
            )
        );
        executionManager.setTraderAssetRiskLimits(TRADER, inputs);

        inputs = new AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[](2);
        inputs[0] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput({
            asset: address(assetOut),
            maxSpendPerExecution: 1,
            maxSpendPer24Hours: 1
        });
        inputs[1] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput({
            asset: address(assetIn),
            maxSpendPerExecution: 1,
            maxSpendPer24Hours: 1
        });
        if (address(assetOut) < address(assetIn)) {
            inputs[0].asset = address(assetIn);
            inputs[1].asset = address(assetOut);
        }
        vm.expectPartialRevert(
            AlphaEngineVaultExecutionManager.RiskAssetsNotStrictlyAscending.selector
        );
        executionManager.setTraderAssetRiskLimits(SECOND_EXECUTOR, inputs);

        inputs = new AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[](1);
        inputs[0] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput({
            asset: address(assetIn),
            maxSpendPerExecution: 0,
            maxSpendPer24Hours: 0
        });
        executionManager.setTraderAssetRiskLimits(TRADER, inputs);
        (uint256 perExecution, uint256 perDay) =
            executionManager.traderAssetRiskLimits(TRADER, address(assetIn));
        assertEq(perExecution, 0);
        assertEq(perDay, 0);
    }

    function testAuthorizationDomainTimeAndPolicyAreCheckedBeforeAnyCall() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(100e6, 90e18, 100e6, 90e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("domain-time-policy"), 0, calls, limits);

        authorization.chainId += 1;
        vm.prank(EXECUTOR);
        vm.expectPartialRevert(AlphaEngineVaultExecutionManager.InvalidAuthorizationDomain.selector);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
        authorization.chainId = block.chainid;

        authorization.validAfter = uint40(block.timestamp + 1);
        vm.prank(EXECUTOR);
        vm.expectPartialRevert(AlphaEngineVaultExecutionManager.AuthorizationNotYetActive.selector);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
        authorization.validAfter = uint40(block.timestamp);

        authorization.deadline = uint40(block.timestamp);
        vm.prank(EXECUTOR);
        vm.expectPartialRevert(AlphaEngineVaultExecutionManager.AuthorizationExpired.selector);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
        authorization.deadline = uint40(block.timestamp + 1 hours);

        authorization.policyRoot = keccak256("stale root");
        vm.prank(EXECUTOR);
        vm.expectPartialRevert(AlphaEngineVaultExecutionManager.StalePolicy.selector);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
    }

    function testBundleShapeAndRiskCoverageFailBeforeVaultExecution() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(100e6, 90e18, 100e6, 90e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("proof-count"), 0, calls, limits);
        capitalManager.approve(authorization);
        bytes32[][] memory shortProofs = new bytes32[][](2);
        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.ProofCountMismatch.selector, 3, 2
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, shortProofs);

        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory emptyLimits =
            new AlphaEngineExecutionHashLib.AssetDeltaLimitV1[](0);
        authorization = _authorization(keccak256("empty-limits"), 1, calls, emptyLimits);
        capitalManager.approve(authorization);
        vm.prank(EXECUTOR);
        vm.expectRevert(AlphaEngineVaultExecutionManager.EmptyAssetLimits.selector);
        executionManager.executeCapitalIntent(authorization, calls, emptyLimits, proofs);

        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory outputOnly =
            new AlphaEngineExecutionHashLib.AssetDeltaLimitV1[](1);
        outputOnly[0] = AlphaEngineExecutionHashLib.AssetDeltaLimitV1({
            asset: address(assetOut),
            maxSpend: 0,
            minReceive: 90e18
        });
        authorization = _authorization(keccak256("approval-unbound"), 2, calls, outputOnly);
        capitalManager.approve(authorization);
        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.ApprovalAssetNotRiskBound.selector,
                0,
                address(assetIn)
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, outputOnly, proofs);

        limits[_inputLimitIndex(limits)].maxSpend = 99e6;
        authorization = _authorization(keccak256("approval-over-limit"), 3, calls, limits);
        capitalManager.approve(authorization);
        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.ApprovalAmountExceedsRiskLimit.selector,
                0,
                address(assetIn),
                100e6,
                99e6
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
    }

    function testMutatedCallAndInvalidProofFailBeforeCapitalConsumption() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(100e6, 90e18, 100e6, 90e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("intent-mutation"), 0, calls, limits);
        bytes32 commitment = capitalManager.approve(authorization);

        calls[1].targetData = abi.encodeCall(
            MockVaultStrategyTarget.swapExact, (address(assetIn), address(assetOut), 99e6, 90e18)
        );
        bytes32 mutatedHash = AlphaEngineExecutionHashLib.hashCalls(calls);
        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.CallsHashMismatch.selector,
                authorization.callsHash,
                mutatedHash
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
        assertFalse(capitalManager.isExecutionConsumed(commitment));

        calls[1].targetData = abi.encodeCall(
            MockVaultStrategyTarget.swapExact, (address(assetIn), address(assetOut), 100e6, 90e18)
        );
        proofs[1][0] = bytes32(uint256(proofs[1][0]) ^ 1);
        vm.prank(EXECUTOR);
        vm.expectPartialRevert(AlphaEngineVaultExecutionManager.InvalidManageProof.selector);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
        assertFalse(capitalManager.isExecutionConsumed(commitment));
    }

    function testTargetCodeHashChangeInvalidatesPreviouslyApprovedProof() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(100e6, 90e18, 100e6, 90e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("intent-code-hash-change"), 0, calls, limits);
        bytes32 commitment = capitalManager.approve(authorization);
        vm.etch(address(strategyTarget), hex"60006000f3");

        vm.prank(EXECUTOR);
        vm.expectPartialRevert(AlphaEngineVaultExecutionManager.InvalidManageProof.selector);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
        assertFalse(capitalManager.isExecutionConsumed(commitment));
    }

    function testNonzeroApprovalMustHaveCommittedReset() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(100e6, 90e18, 100e6, 90e18);
        AlphaEngineExecutionHashLib.CallV1[] memory shortCalls =
            new AlphaEngineExecutionHashLib.CallV1[](2);
        bytes32[][] memory shortProofs = new bytes32[][](2);
        shortCalls[0] = calls[0];
        shortCalls[1] = calls[1];
        shortProofs[0] = proofs[0];
        shortProofs[1] = proofs[1];
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("intent-no-reset"), 0, shortCalls, limits);
        bytes32 commitment = capitalManager.approve(authorization);

        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.ApprovalNotReset.selector,
                address(assetIn),
                address(strategyTarget),
                100e6
            )
        );
        executionManager.executeCapitalIntent(authorization, shortCalls, limits, shortProofs);
        assertFalse(capitalManager.isExecutionConsumed(commitment));
        assertEq(assetIn.allowance(address(fundVault), address(strategyTarget)), 0);
    }

    function testMultipleApprovalsCannotCollectivelyExceedCommittedSpend() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory baseCalls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory baseProofs
        ) = _bundle(60e6, 50e18, 100e6, 100e18);
        AlphaEngineExecutionHashLib.CallV1[] memory calls =
            new AlphaEngineExecutionHashLib.CallV1[](5);
        bytes32[][] memory proofs = new bytes32[][](5);
        calls[0] = baseCalls[0];
        calls[1] = baseCalls[1];
        calls[2] = baseCalls[0];
        calls[3] = baseCalls[1];
        calls[4] = baseCalls[2];
        proofs[0] = baseProofs[0];
        proofs[1] = baseProofs[1];
        proofs[2] = baseProofs[0];
        proofs[3] = baseProofs[1];
        proofs[4] = baseProofs[2];

        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("intent-cumulative-approval"), 0, calls, limits);
        bytes32 commitment = capitalManager.approve(authorization);

        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.CumulativeApprovalAmountExceedsRiskLimit.selector,
                2,
                address(assetIn),
                120e6,
                100e6
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        assertEq(assetIn.balanceOf(address(fundVault)), INITIAL_INPUT_BALANCE);
        assertEq(assetOut.balanceOf(address(fundVault)), 0);
        assertEq(assetIn.allowance(address(fundVault), address(strategyTarget)), 0);
        assertFalse(capitalManager.isExecutionConsumed(commitment));
        assertFalse(executionManager.consumedExecutionCommitments(commitment));
    }

    function testMinimumReceiptFailureRollsBackVaultCapitalAndManagerState() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(100e6, 90e18, 100e6, 91e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("intent-slippage"), 0, calls, limits);
        bytes32 commitment = capitalManager.approve(authorization);

        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.MinimumAssetReceiptNotMet.selector,
                address(assetOut),
                90e18,
                91e18
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        assertEq(assetIn.balanceOf(address(fundVault)), INITIAL_INPUT_BALANCE);
        assertEq(assetOut.balanceOf(address(fundVault)), 0);
        assertEq(assetIn.allowance(address(fundVault), address(strategyTarget)), 0);
        assertFalse(capitalManager.isExecutionConsumed(commitment));
        assertFalse(executionManager.consumedExecutionCommitments(commitment));
        assertFalse(executionManager.consumedAuthorizationNonces(0));
        assertEq(executionManager.currentWindowSpend(TRADER, address(assetIn)), 0);
    }

    function testTokenThatIgnoresResetCannotLeaveResidualVaultAllowance() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(90e6, 80e18, 100e6, 80e18);
        calls[0].targetData = abi.encodeCall(IERC20.approve, (address(strategyTarget), 100e6));
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("intent-sticky-allowance"), 0, calls, limits);
        bytes32 commitment = capitalManager.approve(authorization);
        MockStickyAllowanceERC20(address(assetIn)).setIgnoreZeroApproval(true);

        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.ResidualAllowance.selector,
                address(assetIn),
                address(strategyTarget),
                10e6
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        assertEq(assetIn.balanceOf(address(fundVault)), INITIAL_INPUT_BALANCE);
        assertEq(assetIn.allowance(address(fundVault), address(strategyTarget)), 0);
        assertFalse(capitalManager.isExecutionConsumed(commitment));
    }

    function testConfiguredPerExecutionLimitRejectsBroaderAuthorizationBeforeCalls() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(201e6, 180e18, 201e6, 180e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("intent-over-cap"), 0, calls, limits);
        bytes32 commitment = capitalManager.approve(authorization);

        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.PerExecutionRiskLimitExceeded.selector,
                TRADER,
                address(assetIn),
                201e6,
                200e6
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        assertEq(assetIn.balanceOf(address(fundVault)), INITIAL_INPUT_BALANCE);
        assertFalse(capitalManager.isExecutionConsumed(commitment));
    }

    function testTraderRiskLimitsAreIsolated() public {
        vm.prank(ROOT_GUARDIAN);
        executionManager.pause();
        _setRiskLimit(STRANGER, address(assetIn), 50e6, 100e6);
        executionManager.unpause();

        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(60e6, 50e18, 60e6, 50e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("other-trader-over-cap"), 0, calls, limits);
        authorization.trader = STRANGER;
        bytes32 commitment = capitalManager.approve(authorization);

        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.PerExecutionRiskLimitExceeded.selector,
                STRANGER,
                address(assetIn),
                60e6,
                50e6
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        assertFalse(capitalManager.isExecutionConsumed(commitment));
        assertEq(executionManager.currentWindowSpend(TRADER, address(assetIn)), 0);
        assertEq(executionManager.currentWindowSpend(STRANGER, address(assetIn)), 0);
    }

    function testExecutorPolicyRootsAreIsolated() public {
        bytes32 secondRoot = keccak256("second executor isolated root");
        _activateRoot(SECOND_EXECUTOR, secondRoot);
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(50e6, 40e18, 50e6, 40e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("second-executor-wrong-policy"), 0, calls, limits);
        authorization.executor = SECOND_EXECUTOR;
        authorization.policyRoot = secondRoot;
        authorization.policyVersion = 1;
        bytes32 commitment = capitalManager.approve(authorization);

        vm.prank(SECOND_EXECUTOR);
        vm.expectPartialRevert(AlphaEngineVaultExecutionManager.InvalidManageProof.selector);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        assertFalse(capitalManager.isExecutionConsumed(commitment));
        assertEq(assetIn.balanceOf(address(fundVault)), INITIAL_INPUT_BALANCE);
    }

    function testSpendWindowCapAccumulatesAndFailedExcessRollsBack() public {
        _execute(keccak256("first"), 0, 180e6, 160e18, 180e6, 160e18);
        assertEq(executionManager.currentWindowSpend(TRADER, address(assetIn)), 180e6);

        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(130e6, 110e18, 130e6, 110e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("second"), 1, calls, limits);
        bytes32 commitment = capitalManager.approve(authorization);
        uint256 inputBefore = assetIn.balanceOf(address(fundVault));
        uint256 outputBefore = assetOut.balanceOf(address(fundVault));

        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.SpendWindowLimitExceeded.selector,
                TRADER,
                address(assetIn),
                310e6,
                300e6
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        assertEq(assetIn.balanceOf(address(fundVault)), inputBefore);
        assertEq(assetOut.balanceOf(address(fundVault)), outputBefore);
        assertEq(executionManager.currentWindowSpend(TRADER, address(assetIn)), 180e6);
        assertFalse(capitalManager.isExecutionConsumed(commitment));
    }

    function testSpendWindowResetsAfterTwentyFourHours() public {
        _execute(keccak256("first-window"), 0, 200e6, 180e18, 200e6, 180e18);
        vm.warp(block.timestamp + 24 hours);
        assertEq(executionManager.currentWindowSpend(TRADER, address(assetIn)), 0);
        _execute(keccak256("second-window"), 1, 200e6, 180e18, 200e6, 180e18);
        assertEq(executionManager.currentWindowSpend(TRADER, address(assetIn)), 200e6);
    }

    function testRollingWindowCannotDoubleSpendAcrossAnOldResetBoundary() public {
        _execute(keccak256("rolling-first"), 0, 200e6, 180e18, 200e6, 180e18);
        vm.warp(block.timestamp + 23 hours);
        _execute(keccak256("rolling-second"), 1, 100e6, 90e18, 100e6, 90e18);
        vm.warp(block.timestamp + 2 hours);
        assertEq(executionManager.currentWindowSpend(TRADER, address(assetIn)), 100e6);
        _execute(keccak256("rolling-third"), 2, 200e6, 180e18, 200e6, 180e18);
        assertEq(executionManager.currentWindowSpend(TRADER, address(assetIn)), 300e6);
    }

    function testRollingSpendHistoryFailsClosedAtItsBoundAndPrunesExpiredRecords() public {
        RollingSpendHarness harness = new RollingSpendHarness();
        uint256 startedAt = 10 days;
        vm.warp(startedAt);
        for (uint256 i; i < 64; ++i) {
            assertEq(harness.consume(1), i + 1);
            vm.warp(startedAt + i + 1);
        }
        vm.expectPartialRevert(AlphaEngineRollingSpendLib.SpendRecordCapacityReached.selector);
        harness.consume(1);

        vm.warp(startedAt + 24 hours);
        assertEq(harness.current(), 63);
        assertEq(harness.consume(2), 65);
    }

    function testManagerRollsBackSixtyFifthDistinctSpendRecord() public {
        vm.prank(ROOT_GUARDIAN);
        executionManager.pause();
        _setRiskLimit(TRADER, address(assetIn), 1e6, 100e6);
        executionManager.unpause();

        uint256 startedAt = block.timestamp;
        for (uint64 i; i < 64; ++i) {
            _execute(keccak256(abi.encode("bounded-record", i)), i, 1e6, 1e18, 1e6, 1e18);
            vm.warp(startedAt + i + 1);
        }
        assertEq(executionManager.currentWindowSpend(TRADER, address(assetIn)), 64e6);

        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(1e6, 1e18, 1e6, 1e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("sixty-fifth-record"), 64, calls, limits);
        bytes32 commitment = capitalManager.approve(authorization);
        uint256 inputBefore = assetIn.balanceOf(address(fundVault));
        uint256 outputBefore = assetOut.balanceOf(address(fundVault));

        vm.prank(EXECUTOR);
        vm.expectPartialRevert(AlphaEngineRollingSpendLib.SpendRecordCapacityReached.selector);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        assertEq(assetIn.balanceOf(address(fundVault)), inputBefore);
        assertEq(assetOut.balanceOf(address(fundVault)), outputBefore);
        assertEq(executionManager.currentWindowSpend(TRADER, address(assetIn)), 64e6);
        assertFalse(capitalManager.isExecutionConsumed(commitment));
        assertFalse(executionManager.consumedExecutionCommitments(commitment));
    }

    function testReplayAndWrongExecutorAreRejected() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(100e6, 90e18, 100e6, 90e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("intent-replay"), 0, calls, limits);
        bytes32 commitment = capitalManager.approve(authorization);

        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.UnauthorizedExecutor.selector, STRANGER, EXECUTOR
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        vm.prank(EXECUTOR);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.ExecutionCommitmentAlreadyConsumed.selector,
                commitment
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
    }

    function testCapitalConsumptionMismatchRollsBackBothReplayDomains() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(100e6, 90e18, 100e6, 90e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("intent-bad-consumer"), 0, calls, limits);
        bytes32 commitment = capitalManager.approve(authorization);
        capitalManager.setReturnWrongCommitment(true);
        bytes32 wrongCommitment = bytes32(uint256(commitment) ^ 1);

        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.CapitalConsumptionMismatch.selector,
                wrongCommitment,
                commitment
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        assertFalse(capitalManager.isExecutionConsumed(commitment));
        assertFalse(executionManager.consumedExecutionCommitments(commitment));
        assertFalse(executionManager.consumedAuthorizationNonces(0));
    }

    function testPolicyAndRiskVersionChangesInvalidateOldAuthorization() public {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(100e6, 90e18, 100e6, 90e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("intent-stale-risk"), 0, calls, limits);
        capitalManager.approve(authorization);

        vm.prank(ROOT_GUARDIAN);
        executionManager.pause();
        _setRiskLimit(TRADER, address(assetIn), 150e6, 250e6);
        executionManager.unpause();
        uint64 currentRiskPolicyVersion = executionManager.riskPolicyVersion();

        vm.prank(EXECUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.StaleRiskPolicy.selector,
                authorization.riskPolicyVersion,
                currentRiskPolicyVersion
            )
        );
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
    }

    function testPauseAndFundVaultLinkGateExecution() public {
        vm.prank(ROOT_GUARDIAN);
        executionManager.pause();
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(100e6, 90e18, 100e6, 90e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("intent-paused"), 0, calls, limits);
        capitalManager.approve(authorization);
        vm.prank(EXECUTOR);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        AlphaEngineFundVault unlinkedVault = new AlphaEngineFundVault(address(this), assetIn);
        AlphaEngineVaultExecutionManager unlinkedManager = new AlphaEngineVaultExecutionManager(
            address(this),
            ROOT_PROPOSER,
            ROOT_GUARDIAN,
            capitalManager,
            IAlphaEngineFundVault(address(unlinkedVault))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.InvalidFundVaultLink.selector,
                address(0),
                address(unlinkedManager)
            )
        );
        unlinkedManager.unpause();
    }

    function testFuzzExactBalanceDeltas(uint96 rawInput, uint96 rawOutput) public {
        uint256 amountIn = bound(uint256(rawInput), 1, 200e6);
        uint256 amountOut = bound(uint256(rawOutput), 1, 200e18);
        _execute(keccak256("fuzz-exact-deltas"), 0, amountIn, amountOut, amountIn, amountOut);
        assertEq(assetIn.balanceOf(address(fundVault)), INITIAL_INPUT_BALANCE - amountIn);
        assertEq(assetOut.balanceOf(address(fundVault)), amountOut);
        assertEq(executionManager.currentWindowSpend(TRADER, address(assetIn)), amountIn);
    }

    function testFuzzAnyMutatedSwapAmountBreaksCallsHash(uint96 rawOriginal, uint96 rawMutated)
        public
    {
        uint256 original = bound(uint256(rawOriginal), 1, 200e6);
        uint256 mutated = bound(uint256(rawMutated), 1, 200e6);
        vm.assume(original != mutated);
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(original, 90e18, original, 90e18);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(keccak256("fuzz-call-mutation"), 0, calls, limits);
        capitalManager.approve(authorization);
        calls[1].targetData = abi.encodeCall(
            MockVaultStrategyTarget.swapExact, (address(assetIn), address(assetOut), mutated, 90e18)
        );

        vm.prank(EXECUTOR);
        vm.expectPartialRevert(AlphaEngineVaultExecutionManager.CallsHashMismatch.selector);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
    }

    function _execute(
        bytes32 intentId,
        uint64 nonce,
        uint256 amountIn,
        uint256 amountOut,
        uint256 maxSpend,
        uint256 minReceive
    ) private {
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(amountIn, amountOut, maxSpend, minReceive);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _authorization(intentId, nonce, calls, limits);
        capitalManager.approve(authorization);
        vm.prank(EXECUTOR);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);
    }

    function _bundle(uint256 amountIn, uint256 amountOut, uint256 maxSpend, uint256 minReceive)
        private
        view
        returns (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        )
    {
        calls = new AlphaEngineExecutionHashLib.CallV1[](3);
        calls[0] = AlphaEngineExecutionHashLib.CallV1({
            decoder: address(erc20Decoder),
            target: address(assetIn),
            value: 0,
            targetData: abi.encodeCall(IERC20.approve, (address(strategyTarget), amountIn))
        });
        calls[1] = AlphaEngineExecutionHashLib.CallV1({
            decoder: address(strategyDecoder),
            target: address(strategyTarget),
            value: 0,
            targetData: abi.encodeCall(
                MockVaultStrategyTarget.swapExact,
                (address(assetIn), address(assetOut), amountIn, amountOut)
            )
        });
        calls[2] = AlphaEngineExecutionHashLib.CallV1({
            decoder: address(erc20Decoder),
            target: address(assetIn),
            value: 0,
            targetData: abi.encodeCall(IERC20.approve, (address(strategyTarget), 0))
        });

        limits = new AlphaEngineExecutionHashLib.AssetDeltaLimitV1[](2);
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1 memory inputLimit =
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1({
            asset: address(assetIn),
            maxSpend: maxSpend,
            minReceive: 0
        });
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1 memory outputLimit =
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1({
            asset: address(assetOut),
            maxSpend: 0,
            minReceive: minReceive
        });
        if (address(assetIn) < address(assetOut)) {
            limits[0] = inputLimit;
            limits[1] = outputLimit;
        } else {
            limits[0] = outputLimit;
            limits[1] = inputLimit;
        }

        proofs = new bytes32[][](3);
        proofs[0] = _proof(strategyLeaf);
        proofs[1] = _proof(approvalLeaf);
        proofs[2] = _proof(strategyLeaf);
    }

    function _authorization(
        bytes32 intentId,
        uint64 nonce,
        AlphaEngineExecutionHashLib.CallV1[] memory calls,
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits
    ) private view returns (AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory) {
        (, bytes32 artifactHash, uint64 version) = executionManager.activePolicies(EXECUTOR);
        assertEq(artifactHash, ARTIFACT_HASH);
        return AlphaEngineExecutionHashLib.ExecutionCommitmentV1({
            chainId: block.chainid,
            capitalStrategyManager: address(capitalManager),
            vaultExecutionManager: address(executionManager),
            fundVault: address(fundVault),
            intentId: intentId,
            trader: TRADER,
            qualificationVersion: 1,
            executor: EXECUTOR,
            authorizationNonce: nonce,
            validAfter: uint40(block.timestamp),
            deadline: uint40(block.timestamp + 1 hours),
            policyRoot: policyRoot,
            policyVersion: version,
            callsHash: AlphaEngineExecutionHashLib.hashCalls(calls),
            riskEnvelopeHash: AlphaEngineExecutionHashLib.hashRiskEnvelope(limits),
            riskPolicyVersion: executionManager.riskPolicyVersion(),
            submissionPayloadHash: keccak256(abi.encode(intentId, "submission")),
            evaluationEvidenceHash: keccak256(abi.encode(intentId, "evaluation"))
        });
    }

    function _setRiskLimit(
        address trader,
        address asset,
        uint256 maxPerExecution,
        uint256 maxPer24Hours
    ) private {
        AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[] memory inputs =
            new AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[](1);
        inputs[0] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput({
            asset: asset,
            maxSpendPerExecution: maxPerExecution,
            maxSpendPer24Hours: maxPer24Hours
        });
        executionManager.setTraderAssetRiskLimits(trader, inputs);
    }

    function _policyLeaves()
        private
        view
        returns (bytes32 approveLeaf, bytes32 swapLeaf, bytes32 root)
    {
        bytes memory approveArguments = abi.encode(address(strategyTarget));
        approveLeaf = _leaf(
            address(erc20Decoder), address(assetIn), IERC20.approve.selector, approveArguments
        );
        bytes memory swapArguments = abi.encode(address(assetIn), address(assetOut));
        swapLeaf = _leaf(
            address(strategyDecoder),
            address(strategyTarget),
            MockVaultStrategyTarget.swapExact.selector,
            swapArguments
        );
        root = AlphaEngineManageLeafHashLib.hashPair(approveLeaf, swapLeaf);
    }

    function _leaf(address decoder, address target, bytes4 selector, bytes memory arguments)
        private
        view
        returns (bytes32)
    {
        return AlphaEngineManageLeafHashLib.hashManageLeaf(
            AlphaEngineManageLeafHashLib.ManageLeafV1({
                chainId: block.chainid,
                vaultExecutionManager: address(executionManager),
                fundVault: address(fundVault),
                decoder: decoder,
                decoderCodeHash: decoder.codehash,
                target: target,
                targetCodeHash: target.codehash,
                selector: selector,
                maxNativeValue: 0,
                sanitizedArguments: arguments
            })
        );
    }

    function _activateRoot(address executor, bytes32 root) private {
        uint40 activateAfter = uint40(block.timestamp + 48 hours);
        vm.prank(ROOT_PROPOSER);
        executionManager.proposePolicyRoot(executor, root, ARTIFACT_HASH, activateAfter);
        vm.warp(activateAfter);
        executionManager.activatePolicyRoot(executor);
    }

    function _proof(bytes32 sibling) private pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }

    function _inputLimitIndex(AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits)
        private
        view
        returns (uint256)
    {
        return limits[0].asset == address(assetIn) ? 0 : 1;
    }
}
