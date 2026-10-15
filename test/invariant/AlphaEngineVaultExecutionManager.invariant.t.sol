// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {
    AlphaEngineERC20DecoderAndSanitizer
} from "src/decoders/AlphaEngineERC20DecoderAndSanitizer.sol";
import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";
import {AlphaEngineManageLeafHashLib} from "src/libraries/AlphaEngineManageLeafHashLib.sol";
import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {AlphaEngineVaultExecutionManager} from "src/vault/AlphaEngineVaultExecutionManager.sol";
import {
    VaultExecutionManagerInvariantHandler
} from "test/handlers/VaultExecutionManagerInvariantHandler.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockFundVaultCallTarget, MockRecoveryVault} from "test/mocks/MockFundVaultExecution.sol";
import {
    MockCapitalStrategyManagerStage16,
    MockStrategyActionDecoder,
    MockVaultStrategyTarget
} from "test/mocks/MockVaultExecutionStage16.sol";

contract AlphaEngineVaultExecutionManagerInvariantTest is StdInvariant, Test {
    address private constant ROOT_PROPOSER = address(0xA11CE);
    address private constant ROOT_GUARDIAN = address(0xB0B);
    address private constant TRADER = address(0x7A);
    uint256 private constant INITIAL_INPUT = 100_000_000e6;
    uint256 private constant INITIAL_OUTPUT = 100_000_000e18;
    bytes32 private constant ARTIFACT_HASH = keccak256("invariant policy artifact");

    MockERC20 private assetIn;
    MockERC20 private assetOut;
    MockCapitalStrategyManagerStage16 private capitalManager;
    AlphaEngineFundVault private fundVault;
    AlphaEngineVaultExecutionManager private executionManager;
    AlphaEngineERC20DecoderAndSanitizer private erc20Decoder;
    MockStrategyActionDecoder private strategyDecoder;
    MockVaultStrategyTarget private strategyTarget;
    VaultExecutionManagerInvariantHandler private handler;

    bytes32 private policyRoot;
    uint64 private policyVersion;

    function setUp() public {
        assetIn = new MockERC20("USD Coin", "USDC", 6);
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
        MockFundVaultCallTarget accountingManager = new MockFundVaultCallTarget();
        MockRecoveryVault recoveryVault = new MockRecoveryVault();

        fundVault.setUsdcManager(address(accountingManager));
        fundVault.setExecutionManager(address(executionManager));
        fundVault.setEmergencyConfiguration(ROOT_GUARDIAN, address(recoveryVault));
        fundVault.unpause();
        assetIn.mint(address(fundVault), INITIAL_INPUT);
        assetOut.mint(address(strategyTarget), INITIAL_OUTPUT);

        (
            bytes32 inputApprovalLeaf,
            bytes32 positionApprovalLeaf,
            bytes32 entryLeaf,
            bytes32 exitLeaf
        ) = _leaves();
        policyRoot = _fourLeafRoot(inputApprovalLeaf, positionApprovalLeaf, entryLeaf, exitLeaf);
        handler = new VaultExecutionManagerInvariantHandler(
            executionManager,
            capitalManager,
            address(fundVault),
            assetIn,
            assetOut,
            erc20Decoder,
            strategyDecoder,
            strategyTarget,
            TRADER,
            policyRoot,
            1,
            inputApprovalLeaf,
            positionApprovalLeaf,
            entryLeaf,
            exitLeaf
        );

        AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[] memory inputs =
            new AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[](2);
        AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput memory inputRisk =
            AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput({
                asset: address(assetIn),
                maxSpendPerExecution: handler.MAX_PER_EXECUTION(),
                maxSpendPer24Hours: handler.MAX_PER_24_HOURS()
            });
        AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput memory positionRisk =
            AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput({
                asset: address(assetOut),
                maxSpendPerExecution: handler.MAX_POSITION_PER_EXECUTION(),
                maxSpendPer24Hours: handler.MAX_POSITION_PER_24_HOURS()
            });
        if (address(assetIn) < address(assetOut)) {
            inputs[0] = inputRisk;
            inputs[1] = positionRisk;
        } else {
            inputs[0] = positionRisk;
            inputs[1] = inputRisk;
        }
        executionManager.setTraderAssetRiskLimits(TRADER, inputs);
        executionManager.setTraderAssetRiskLimits(handler.SECOND_TRADER(), inputs);
        executionManager.grantRole(executionManager.ROOT_PROPOSER_ROLE(), address(handler));
        executionManager.grantRole(executionManager.ROOT_GUARDIAN_ROLE(), address(handler));
        executionManager.grantRole(executionManager.PAUSER_ROLE(), address(handler));

        uint40 activateAfter = uint40(block.timestamp + 48 hours);
        vm.prank(ROOT_PROPOSER);
        executionManager.proposePolicyRoot(
            address(handler), policyRoot, ARTIFACT_HASH, activateAfter
        );
        address secondExecutor = address(handler.SECOND_EXECUTOR());
        vm.prank(ROOT_PROPOSER);
        executionManager.proposePolicyRoot(secondExecutor, policyRoot, ARTIFACT_HASH, activateAfter);
        vm.warp(activateAfter);
        executionManager.activatePolicyRoot(address(handler));
        executionManager.activatePolicyRoot(address(handler.SECOND_EXECUTOR()));
        (,, policyVersion) = executionManager.activePolicies(address(handler));
        executionManager.unpause();

        handler.executeValid(1e6);
        handler.attemptReplay();
        handler.attemptSlippage(1e6);
        handler.attemptInvalidProof(1e6);
        handler.attemptOverConfiguredCap(1e6);
        handler.executeExit(1e6);

        // Each seed is a real multi-step witness; randomized selections subsequently interleave them.
        handler.executeSecondTrader(2e6);
        handler.exerciseRollingBoundary(3e6);
        handler.exerciseSpendCapacity(4);
        handler.exerciseRootGovernance(5e6);
        handler.exerciseRiskGovernance(6e6);
        handler.exerciseCodeIdentity(7e6, false);
        handler.exerciseCodeIdentity(7e6, true);
        handler.exerciseApprovalOrdering(8e6, 0);
        handler.exerciseApprovalOrdering(8e6, 1);
        handler.exerciseApprovalOrdering(8e6, 2);
        handler.exerciseAggregateApprovals(8e6, false);
        handler.exerciseAggregateApprovals(8e6, true);
        handler.exerciseFacetIdentity(8e6, false);
        handler.exerciseFacetIdentity(8e6, true);
        handler.exerciseMaximumPreflight(8e6, false);
        handler.exerciseMaximumPreflight(8e6, true);
        handler.exerciseReentrantTarget(9e6);
        handler.exerciseDirectShareBurn(10e6, false);

        bytes4[] memory selectors = new bytes4[](19);
        selectors[0] = handler.executeValid.selector;
        selectors[1] = handler.executeExit.selector;
        selectors[2] = handler.advanceHoldingTime.selector;
        selectors[3] = handler.attemptReplay.selector;
        selectors[4] = handler.attemptSlippage.selector;
        selectors[5] = handler.attemptInvalidProof.selector;
        selectors[6] = handler.attemptOverConfiguredCap.selector;
        selectors[7] = handler.executeSecondTrader.selector;
        selectors[8] = handler.exerciseRollingBoundary.selector;
        selectors[9] = handler.exerciseSpendCapacity.selector;
        selectors[10] = handler.exerciseRootGovernance.selector;
        selectors[11] = handler.exerciseRiskGovernance.selector;
        selectors[12] = handler.exerciseCodeIdentity.selector;
        selectors[13] = handler.exerciseApprovalOrdering.selector;
        selectors[14] = handler.exerciseReentrantTarget.selector;
        selectors[15] = handler.exerciseDirectShareBurn.selector;
        selectors[16] = handler.exerciseAggregateApprovals.selector;
        selectors[17] = handler.exerciseFacetIdentity.selector;
        selectors[18] = handler.exerciseMaximumPreflight.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_EX_rollingBoundaryAndCapacityUseCurrentClock() public {
        uint256 started = vm.getBlockTimestamp();
        handler.exerciseRollingBoundary(3e6);
        assertEq(vm.getBlockTimestamp(), started + 48 hours + 1);
        handler.exerciseSpendCapacity(4);
        assertEq(vm.getBlockTimestamp(), started + 120 hours + 1);
        invariantSuccessfulBalancesMatchIndependentGhostLedger();
        invariantSpendWindowAndAllowanceRemainBounded();
        invariantExpectedFailuresAreAtomicAndReplayNeverSucceeds();
    }

    function invariantSuccessfulBalancesMatchIndependentGhostLedger() public view {
        assertEq(
            assetIn.balanceOf(address(fundVault)),
            INITIAL_INPUT - handler.ghostSpent() + handler.ghostExitInputReceived()
        );
        assertEq(
            assetOut.balanceOf(address(fundVault)),
            handler.ghostReceived() + handler.ghostCallbackReceipts()
                - handler.ghostExitPositionSpent()
        );
        assertEq(
            assetIn.balanceOf(address(strategyTarget)),
            handler.ghostSpent() - handler.ghostExitInputReceived()
        );
        assertEq(
            assetOut.balanceOf(address(strategyTarget)),
            INITIAL_OUTPUT - handler.ghostReceived() + handler.ghostExitPositionSpent()
        );
    }

    function invariantSpendWindowAndAllowanceRemainBounded() public view {
        assertEq(
            executionManager.currentWindowSpend(TRADER, address(assetIn)),
            handler.ghostInputWindowSpend()
        );
        assertEq(
            executionManager.currentWindowSpend(TRADER, address(assetOut)),
            handler.ghostPositionWindowSpend()
        );
        assertLe(
            executionManager.currentWindowSpend(TRADER, address(assetIn)),
            handler.MAX_PER_24_HOURS()
        );
        assertLe(
            executionManager.currentWindowSpend(TRADER, address(assetOut)),
            handler.MAX_POSITION_PER_24_HOURS()
        );
        assertEq(assetIn.allowance(address(fundVault), address(strategyTarget)), 0);
        assertEq(assetOut.allowance(address(fundVault), address(strategyTarget)), 0);
    }

    function invariantExpectedFailuresAreAtomicAndReplayNeverSucceeds() public view {
        assertGt(handler.successfulEntries(), 0);
        assertGt(handler.successfulExits(), 0);
        assertGt(handler.expectedFailures(), 0);
        assertFalse(handler.expectedFailureViolation());
        assertFalse(handler.replayViolation());
        assertFalse(handler.successfulExecutionViolation());
    }

    function invariantControlPlaneAndCustodyBoundariesDoNotMove() public view {
        (bytes32 root, bytes32 artifactHash, uint64 version) =
            executionManager.activePolicies(address(handler));
        assertEq(root, policyRoot);
        assertEq(artifactHash, ARTIFACT_HASH);
        assertGe(version, policyVersion);
        assertEq(fundVault.executionManager(), address(executionManager));
        assertEq(fundVault.totalSupply(), 0);
        assertEq(assetIn.balanceOf(address(executionManager)), 0);
        assertEq(assetOut.balanceOf(address(executionManager)), 0);
    }

    /// @notice EX-03/EX-04/EX-05/EX-06/EX-07/EX-08/EX-09/EX-13: governance and boundary witnesses stay reachable.
    function invariantLifecycleScenariosKeepDomainsAndCustodyIsolated() public view {
        uint256[9] memory ids = [uint256(3), 4, 5, 6, 7, 8, 9, 13, 18];
        for (uint256 i; i < ids.length; ++i) {
            assertGt(handler.scenarioRuns(ids[i]), 0);
        }
        assertEq(
            executionManager.currentWindowSpend(handler.SECOND_TRADER(), address(assetIn)),
            handler.ghostSecondInputWindowSpend()
        );
        assertEq(executionManager.currentWindowSpend(handler.SECOND_TRADER(), address(assetOut)), 0);
        (bytes32 secondRoot, bytes32 secondArtifact, uint64 secondVersion) =
            executionManager.activePolicies(address(handler.SECOND_EXECUTOR()));
        assertEq(secondRoot, policyRoot);
        assertEq(secondArtifact, ARTIFACT_HASH);
        assertEq(secondVersion, 1);
        assertEq(assetIn.balanceOf(address(handler.SECOND_EXECUTOR())), 0);
        assertEq(assetOut.balanceOf(address(handler.SECOND_EXECUTOR())), 0);
    }

    /// @notice EX-15: explicit direct-burn risk accounting is exercised; omission is reported separately.
    function invariantDirectShareBurnRequiresAnExplicitlyCompleteEconomicEnvelope_Exploratory()
        public
        view
    {
        assertGt(handler.scenarioRuns(15), 0);
        // EXPLORATORY: enabling ERC4626 policies without share limits is an owner decision.
        assertFalse(
            handler.exploratoryUntrackedShareBurn(),
            "EX-15: enabled direct burn bypassed omitted share risk"
        );
    }

    function _leaves()
        private
        view
        returns (
            bytes32 inputApprovalLeaf,
            bytes32 positionApprovalLeaf,
            bytes32 entryLeaf,
            bytes32 exitLeaf
        )
    {
        inputApprovalLeaf = _leaf(
            address(erc20Decoder),
            address(assetIn),
            IERC20.approve.selector,
            abi.encode(address(strategyTarget))
        );
        positionApprovalLeaf = _leaf(
            address(erc20Decoder),
            address(assetOut),
            IERC20.approve.selector,
            abi.encode(address(strategyTarget))
        );
        entryLeaf = _leaf(
            address(strategyDecoder),
            address(strategyTarget),
            MockVaultStrategyTarget.swapExact.selector,
            abi.encode(address(assetIn), address(assetOut))
        );
        exitLeaf = _leaf(
            address(strategyDecoder),
            address(strategyTarget),
            MockVaultStrategyTarget.swapExact.selector,
            abi.encode(address(assetOut), address(assetIn))
        );
    }

    function _fourLeafRoot(bytes32 a, bytes32 b, bytes32 c, bytes32 d)
        private
        pure
        returns (bytes32)
    {
        bytes32[4] memory leaves = [a, b, c, d];
        for (uint256 i; i < leaves.length; ++i) {
            for (uint256 j = i + 1; j < leaves.length; ++j) {
                if (uint256(leaves[j]) < uint256(leaves[i])) {
                    (leaves[i], leaves[j]) = (leaves[j], leaves[i]);
                }
            }
        }
        return AlphaEngineManageLeafHashLib.hashPair(
            AlphaEngineManageLeafHashLib.hashPair(leaves[0], leaves[1]),
            AlphaEngineManageLeafHashLib.hashPair(leaves[2], leaves[3])
        );
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
}
