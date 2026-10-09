// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {externalEuint32, externalEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {
    AlphaEngineERC20DecoderAndSanitizer
} from "src/decoders/AlphaEngineERC20DecoderAndSanitizer.sol";
import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";
import {AlphaEngineExecutionHashLib} from "src/libraries/AlphaEngineExecutionHashLib.sol";
import {AlphaEngineManageLeafHashLib} from "src/libraries/AlphaEngineManageLeafHashLib.sol";
import {
    AlphaEngineCapitalStrategyManager
} from "src/strategy/AlphaEngineCapitalStrategyManager.sol";
import {
    AlphaEngineTraderQualificationRegistry
} from "src/strategy/AlphaEngineTraderQualificationRegistry.sol";
import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {AlphaEngineVaultExecutionManager} from "src/vault/AlphaEngineVaultExecutionManager.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockFundVaultCallTarget, MockRecoveryVault} from "test/mocks/MockFundVaultExecution.sol";
import {
    MockStrategyActionDecoder,
    MockVaultStrategyTarget
} from "test/mocks/MockVaultExecutionStage16.sol";

contract AlphaEngineCapitalVaultExecutionIntegrationTest is MockCoFheTest {
    address private admin = makeAddr("admin");
    address private pauser = makeAddr("pauser");
    address private revoker = makeAddr("revoker");
    address private issuer = makeAddr("issuer");
    address private evaluator = makeAddr("evaluator");
    address private fheOperator = makeAddr("fheOperator");
    address private rootProposer = makeAddr("rootProposer");
    address private rootGuardian = makeAddr("rootGuardian");
    address private executor = makeAddr("executor");
    address private trader = makeAddr("trader");

    MockERC20 private assetIn;
    MockERC20 private assetOut;
    AlphaEngineTraderQualificationRegistry private registry;
    AlphaEngineCapitalStrategyManager private capitalManager;
    AlphaEngineFundVault private fundVault;
    AlphaEngineVaultExecutionManager private executionManager;
    AlphaEngineERC20DecoderAndSanitizer private erc20Decoder;
    MockStrategyActionDecoder private strategyDecoder;
    MockVaultStrategyTarget private strategyTarget;
    bytes32 private policyRoot;
    bytes32 private approvalLeaf;
    bytes32 private strategyLeaf;

    function setUp() public {
        _installMockTaskManager();
        assetIn = new MockERC20("USD Coin", "USDC", 6);
        assetOut = new MockERC20("Position Token", "PT", 18);
        registry = _deployRegistry();
        capitalManager = _deployCapitalManager();
        fundVault = new AlphaEngineFundVault(admin, assetIn);
        executionManager = new AlphaEngineVaultExecutionManager(
            admin,
            rootProposer,
            rootGuardian,
            capitalManager,
            IAlphaEngineFundVault(address(fundVault))
        );
        erc20Decoder = new AlphaEngineERC20DecoderAndSanitizer();
        strategyDecoder = new MockStrategyActionDecoder();
        strategyTarget = new MockVaultStrategyTarget();
        MockFundVaultCallTarget accountingManager = new MockFundVaultCallTarget();
        MockRecoveryVault recoveryVault = new MockRecoveryVault();

        vm.startPrank(admin);
        registry.grantRole(registry.QUALIFICATION_ISSUER_ROLE(), issuer);
        capitalManager.grantRole(capitalManager.EVALUATOR_ROLE(), evaluator);
        capitalManager.setExecutionManagerAuthorization(address(executionManager), true);
        fundVault.setUsdcManager(address(accountingManager));
        fundVault.setExecutionManager(address(executionManager));
        fundVault.setEmergencyConfiguration(rootGuardian, address(recoveryVault));
        registry.unpause();
        vm.stopPrank();

        vm.prank(issuer);
        registry.qualifyTrader(
            trader,
            uint40(block.timestamp + 30 days),
            keccak256("competition"),
            keccak256("qualification evidence")
        );

        _configureExecutionPolicy();
        vm.startPrank(admin);
        capitalManager.unpause();
        executionManager.unpause();
        fundVault.unpause();
        vm.stopPrank();

        assetIn.mint(address(fundVault), 1000e6);
        assetOut.mint(address(strategyTarget), 1000e18);
    }

    function testApprovedConfidentialCapitalIntentExecutesThroughMerkleVaultBoundary() public {
        bytes32 intentId = _submitCapitalIntent();
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _bundle(100e6, 90e18);
        AlphaEngineCapitalStrategyManager.CapitalIntentIdentity memory identity =
            capitalManager.getCapitalIntentIdentity(intentId);
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory intentState =
            capitalManager.getCapitalIntentState(intentId);
        (,, uint64 policyVersion) = executionManager.activePolicies(executor);
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1({
                chainId: block.chainid,
                capitalStrategyManager: address(capitalManager),
                vaultExecutionManager: address(executionManager),
                fundVault: address(fundVault),
                intentId: intentId,
                trader: trader,
                qualificationVersion: intentState.qualificationVersion,
                executor: executor,
                authorizationNonce: capitalManager.nextAuthorizationNonce(),
                validAfter: uint40(block.timestamp),
                deadline: uint40(block.timestamp + 1 hours),
                policyRoot: policyRoot,
                policyVersion: policyVersion,
                callsHash: AlphaEngineExecutionHashLib.hashCalls(calls),
                riskEnvelopeHash: AlphaEngineExecutionHashLib.hashRiskEnvelope(limits),
                riskPolicyVersion: executionManager.riskPolicyVersion(),
                submissionPayloadHash: identity.payloadHash,
                evaluationEvidenceHash: keccak256("evaluation evidence")
            });

        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores = _withScoreProof(
            address(capitalManager),
            AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission({
                realSisterScore: createExternalEuint32(88, evaluator),
                perturbationP25Score: createExternalEuint32(77, evaluator),
                stressP25Score: createExternalEuint32(66, evaluator),
                inputProof: ""
            })
        );
        vm.prank(evaluator);
        bytes32 commitment = capitalManager.approveCapitalIntent(intentId, scores, authorization);

        vm.prank(executor);
        executionManager.executeCapitalIntent(authorization, calls, limits, proofs);

        intentState = capitalManager.getCapitalIntentState(intentId);
        assertEq(
            uint256(intentState.status),
            uint256(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Consumed)
        );
        assertTrue(capitalManager.isExecutionConsumed(commitment));
        assertTrue(executionManager.consumedExecutionCommitments(commitment));
        assertEq(assetIn.balanceOf(address(fundVault)), 900e6);
        assertEq(assetOut.balanceOf(address(fundVault)), 90e18);
        assertEq(assetIn.allowance(address(fundVault), address(strategyTarget)), 0);
    }

    function _configureExecutionPolicy() private {
        AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[] memory riskInputs =
            new AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[](1);
        riskInputs[0] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput({
            asset: address(assetIn), maxSpendPerExecution: 200e6, maxSpendPer24Hours: 500e6
        });
        vm.prank(admin);
        executionManager.setTraderAssetRiskLimits(trader, riskInputs);

        approvalLeaf = _leaf(
            address(erc20Decoder),
            address(assetIn),
            IERC20.approve.selector,
            abi.encode(address(strategyTarget))
        );
        strategyLeaf = _leaf(
            address(strategyDecoder),
            address(strategyTarget),
            MockVaultStrategyTarget.swapExact.selector,
            abi.encode(address(assetIn), address(assetOut))
        );
        policyRoot = AlphaEngineManageLeafHashLib.hashPair(approvalLeaf, strategyLeaf);
        uint40 activateAfter = uint40(block.timestamp + 48 hours);
        vm.prank(rootProposer);
        executionManager.proposePolicyRoot(
            executor, policyRoot, keccak256("reviewed policy artifact"), activateAfter
        );
        vm.warp(activateAfter);
        executionManager.activatePolicyRoot(executor);
    }

    function _submitCapitalIntent() private returns (bytes32 intentId) {
        externalEuint128 encryptedMarket = createExternalEuint128(7, trader);
        externalEuint128[] memory components = new externalEuint128[](2);
        components[0] = createExternalEuint128(11, trader);
        components[1] = createExternalEuint128(22, trader);
        vm.prank(trader);
        intentId = capitalManager.submitCapitalIntent(
            keccak256("1h"),
            uint40(block.timestamp + 2 days),
            encryptedMarket,
            components,
            _strategyProof(address(capitalManager), encryptedMarket, components)
        );
    }

    function _bundle(uint256 amountIn, uint256 amountOut)
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
                asset: address(assetIn), maxSpend: amountIn, minReceive: 0
            });
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1 memory outputLimit =
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1({
                asset: address(assetOut), maxSpend: 0, minReceive: amountOut
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

    function _proof(bytes32 sibling) private pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }

    function _deployRegistry() private returns (AlphaEngineTraderQualificationRegistry deployed) {
        AlphaEngineTraderQualificationRegistry implementation =
            new AlphaEngineTraderQualificationRegistry();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin,
            abi.encodeCall(
                AlphaEngineTraderQualificationRegistry.initialize, (admin, pauser, revoker)
            )
        );
        deployed = AlphaEngineTraderQualificationRegistry(address(proxy));
    }

    function _deployCapitalManager() private returns (AlphaEngineCapitalStrategyManager deployed) {
        AlphaEngineCapitalStrategyManager implementation = new AlphaEngineCapitalStrategyManager();
        AlphaEngineCapitalStrategyManager.InitializationParams memory params =
            AlphaEngineCapitalStrategyManager.InitializationParams({
                initialDefaultAdmin: admin,
                initialPauser: pauser,
                initialFheOperator: fheOperator,
                qualificationRegistry: address(registry)
            });
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin,
            abi.encodeCall(AlphaEngineCapitalStrategyManager.initialize, (params))
        );
        deployed = AlphaEngineCapitalStrategyManager(address(proxy));
    }
}
