// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {AlphaEngineERC20DecoderAndSanitizer} from
    "src/decoders/AlphaEngineERC20DecoderAndSanitizer.sol";
import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";
import {AlphaEngineManageLeafHashLib} from "src/libraries/AlphaEngineManageLeafHashLib.sol";
import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {AlphaEngineVaultExecutionManager} from "src/vault/AlphaEngineVaultExecutionManager.sol";
import {VaultExecutionManagerInvariantHandler} from
    "test/handlers/VaultExecutionManagerInvariantHandler.sol";
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

        uint40 activateAfter = uint40(block.timestamp + 48 hours);
        vm.prank(ROOT_PROPOSER);
        executionManager.proposePolicyRoot(
            address(handler), policyRoot, ARTIFACT_HASH, activateAfter
        );
        vm.warp(activateAfter);
        executionManager.activatePolicyRoot(address(handler));
        (,, policyVersion) = executionManager.activePolicies(address(handler));
        executionManager.unpause();

        handler.executeValid(1e6);
        handler.attemptReplay();
        handler.attemptSlippage(1e6);
        handler.attemptInvalidProof(1e6);
        handler.attemptOverConfiguredCap(1e6);
        handler.executeExit(1e6);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.executeValid.selector;
        selectors[1] = handler.executeExit.selector;
        selectors[2] = handler.advanceHoldingTime.selector;
        selectors[3] = handler.attemptReplay.selector;
        selectors[4] = handler.attemptSlippage.selector;
        selectors[5] = handler.attemptInvalidProof.selector;
        selectors[6] = handler.attemptOverConfiguredCap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantSuccessfulBalancesMatchIndependentGhostLedger() public view {
        assertEq(
            assetIn.balanceOf(address(fundVault)),
            INITIAL_INPUT - handler.ghostSpent() + handler.ghostExitInputReceived()
        );
        assertEq(
            assetOut.balanceOf(address(fundVault)),
            handler.ghostReceived() - handler.ghostExitPositionSpent()
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
        assertEq(version, policyVersion);
        assertEq(fundVault.executionManager(), address(executionManager));
        assertEq(fundVault.totalSupply(), 0);
        assertEq(assetIn.balanceOf(address(executionManager)), 0);
        assertEq(assetOut.balanceOf(address(executionManager)), 0);
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
