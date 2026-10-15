// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Vm} from "forge-std/Vm.sol";
import {AlphaEngineUSDCVaultManager} from "src/vault/AlphaEngineUSDCVaultManager.sol";
import {
    AlphaEngineCompetitionStrategyManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
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

abstract contract CapitalVaultExecutionFixture is MockCoFheTest {
    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal revoker = makeAddr("revoker");
    address internal issuer = makeAddr("issuer");
    address internal evaluator = makeAddr("evaluator");
    address internal fheOperator = makeAddr("fheOperator");
    address internal rootProposer = makeAddr("rootProposer");
    address internal rootGuardian = makeAddr("rootGuardian");
    address internal executor = makeAddr("executor");
    address internal trader = makeAddr("trader");

    MockERC20 internal assetIn;
    MockERC20 internal assetOut;
    AlphaEngineTraderQualificationRegistry internal registry;
    AlphaEngineCapitalStrategyManager internal capitalManager;
    AlphaEngineFundVault internal fundVault;
    AlphaEngineVaultExecutionManager internal executionManager;
    AlphaEngineERC20DecoderAndSanitizer internal erc20Decoder;
    MockStrategyActionDecoder internal strategyDecoder;
    MockVaultStrategyTarget internal strategyTarget;
    bytes32 internal policyRoot;
    bytes32 internal approvalLeaf;
    bytes32 internal strategyLeaf;
    bytes32 internal positionApprovalLeaf;
    bytes32 internal exitLeaf;
    bytes32[4] internal sortedPolicyLeaves;
    AlphaEngineUSDCVaultManager internal accounting;
    address internal lp0 = makeAddr("lp0");
    address internal lp1 = makeAddr("lp1");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal navReporter = makeAddr("navReporter");

    function setUp() public virtual {
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
        accounting = new AlphaEngineUSDCVaultManager(
            admin,
            assetIn,
            IAlphaEngineFundVault(address(fundVault)),
            navReporter,
            feeRecipient,
            1 days,
            1000
        );
        MockRecoveryVault recoveryVault = new MockRecoveryVault();

        vm.startPrank(admin);
        registry.grantRole(registry.QUALIFICATION_ISSUER_ROLE(), issuer);
        capitalManager.grantRole(capitalManager.EVALUATOR_ROLE(), evaluator);
        capitalManager.setExecutionManagerAuthorization(address(executionManager), true);
        fundVault.setUsdcManager(address(accounting));
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
        accounting.unpause();
        vm.stopPrank();

        assetIn.mint(lp0, 1000e6);
        vm.prank(lp0);
        assetIn.approve(address(fundVault), type(uint256).max);
        vm.prank(lp1);
        assetIn.approve(address(fundVault), type(uint256).max);
        vm.prank(lp0);
        fundVault.approve(address(accounting), type(uint256).max);
        vm.prank(lp1);
        fundVault.approve(address(accounting), type(uint256).max);
        vm.prank(lp0);
        accounting.deposit(1000e6, lp0, 0);
        assetOut.mint(address(strategyTarget), 1000e18);
    }

    function _configureExecutionPolicy() internal {
        AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[] memory riskInputs =
            new AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[](2);
        riskInputs[0] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput({
            asset: address(assetIn), maxSpendPerExecution: 200e6, maxSpendPer24Hours: 500e6
        });
        riskInputs[1] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput({
            asset: address(assetOut), maxSpendPerExecution: 200e18, maxSpendPer24Hours: 500e18
        });
        if (address(assetIn) > address(assetOut)) {
            (riskInputs[0], riskInputs[1]) = (riskInputs[1], riskInputs[0]);
        }
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
        positionApprovalLeaf = _leaf(
            address(erc20Decoder),
            address(assetOut),
            IERC20.approve.selector,
            abi.encode(address(strategyTarget))
        );
        exitLeaf = _leaf(
            address(strategyDecoder),
            address(strategyTarget),
            MockVaultStrategyTarget.swapExact.selector,
            abi.encode(address(assetOut), address(assetIn))
        );
        sortedPolicyLeaves = [approvalLeaf, strategyLeaf, positionApprovalLeaf, exitLeaf];
        for (uint256 i; i < 4; ++i) {
            for (uint256 j = i + 1; j < 4; ++j) {
                if (uint256(sortedPolicyLeaves[j]) < uint256(sortedPolicyLeaves[i])) {
                    (sortedPolicyLeaves[i], sortedPolicyLeaves[j]) =
                    (sortedPolicyLeaves[j], sortedPolicyLeaves[i]);
                }
            }
        }
        policyRoot = AlphaEngineManageLeafHashLib.hashPair(
            AlphaEngineManageLeafHashLib.hashPair(sortedPolicyLeaves[0], sortedPolicyLeaves[1]),
            AlphaEngineManageLeafHashLib.hashPair(sortedPolicyLeaves[2], sortedPolicyLeaves[3])
        );
        uint40 activateAfter = uint40(block.timestamp + 48 hours);
        vm.prank(rootProposer);
        executionManager.proposePolicyRoot(
            executor, policyRoot, keccak256("reviewed policy artifact"), activateAfter
        );
        vm.warp(activateAfter);
        executionManager.activatePolicyRoot(executor);
    }

    function _submitCapitalIntent() internal returns (bytes32 intentId) {
        externalEuint128 encryptedMarket = createExternalEuint128(7, trader);
        externalEuint128[] memory components = new externalEuint128[](2);
        components[0] = createExternalEuint128(11, trader);
        components[1] = createExternalEuint128(22, trader);
        uint40 deadline = uint40(block.timestamp + 2 days);
        uint40 validUntil = registry.getQualification(trader).validUntil;
        if (deadline > validUntil) deadline = validUntil;
        vm.prank(trader);
        intentId = capitalManager.submitCapitalIntent(
            keccak256("1h"),
            deadline,
            encryptedMarket,
            components,
            _strategyProof(address(capitalManager), encryptedMarket, components)
        );
    }

    function _bundle(uint256 amountIn, uint256 amountOut)
        internal
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
        proofs[0] = _proof(approvalLeaf);
        proofs[1] = _proof(strategyLeaf);
        proofs[2] = _proof(approvalLeaf);
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

    function _proof(bytes32 leaf) internal view returns (bytes32[] memory proof) {
        uint256 index;
        while (index < 4 && sortedPolicyLeaves[index] != leaf) ++index;
        assertLt(index, 4, "unknown policy leaf");
        proof = new bytes32[](2);
        proof[0] = sortedPolicyLeaves[index ^ 1];
        uint256 other = index < 2 ? 2 : 0;
        proof[1] = AlphaEngineManageLeafHashLib.hashPair(
            sortedPolicyLeaves[other], sortedPolicyLeaves[other + 1]
        );
    }

    function _deployRegistry() internal returns (AlphaEngineTraderQualificationRegistry deployed) {
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

    function _deployCapitalManager() internal returns (AlphaEngineCapitalStrategyManager deployed) {
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

contract AlphaEngineCapitalVaultExecutionIntegrationTest is CapitalVaultExecutionFixture {
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
}

/// @notice XS-01/02/03/05/06, QC-12, EX-02/14/17: real managers and funded LP claims share one lifecycle.
/// @dev The exchange and mark price are explicit test fixtures, not Pendle or an AMM pricing oracle.
/// Reported NAV is tracked separately from unreported market P&L; no stale-NAV admission policy is invented.
contract CapitalVaultLifecycleHandler is CapitalVaultExecutionFixture {
    struct Prepared {
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 authorization;
        uint256 input;
        uint256 output;
        bool exiting;
    }

    Prepared[] private _prepared;
    uint64[] private _requests;
    mapping(uint64 => AlphaEngineUSDCVaultManager.RedemptionRequest) private _requestModel;
    mapping(address => uint256) private _shares;
    uint256 public ghostManaged;
    uint256 public ghostIdle;
    uint256 public ghostPositionTokens;
    uint256 public markPrice = 1e6;
    uint256 public ghostProtocolResidual;
    uint256 public ghostRecoveryUsdc;
    uint256 public ghostRecoveryPositions;
    uint256 public ghostExternalFunding = 1000e6;
    uint256 public ghostFeeShares;
    uint256 public ghostEscrowShares;
    uint256 public ghostSupply;
    uint256 public successfulEntries;
    uint256 public successfulExits;
    uint256 public successfulProfitReports;
    uint256 public successfulLossReports;
    uint256 public completedRequests;
    uint256 public rejectedExecutions;
    uint256 public rejectedCompletions;
    uint256 public competitionChains;
    uint256 public governanceChecks;
    uint256 public recoveryChecks;
    bool public feeEntitlementViolation;
    bool public incomingRoundingLossViolation;
    address private constant MARKET_LIQUIDITY_SINK = address(0x1111D17);
    AlphaEngineCompetitionStrategyManager private competitionManager;

    error MissingExpectedEvent(bytes32 signature);

    constructor() {
        CapitalVaultExecutionFixture.setUp();
        ghostManaged = 1000e6;
        ghostIdle = 1000e6;
        ghostSupply = 1000e18;
        _shares[lp0] = 1000e18;
        _deployCompetitionManager();
    }

    // Install the fixture once in construction; do not expose a second deployment/reset path in the handler runtime.
    function setUp() public override {}

    function deposit(uint256 actorSeed, uint96 amountSeed) public {
        if (fundVault.recoveryActivated()) return;
        _settle();
        address owner = _lp(actorSeed);
        uint256 assets = bound(uint256(amountSeed), 1, 1000e6);
        uint256 recognized = accounting.availableAssets();
        if (ghostSupply != 0 && recognized == 0) return; // Deposits into an insolvent recognized NAV are not promised.
        uint256 supplyBefore = ghostSupply;
        assetIn.mint(owner, assets);
        ghostExternalFunding += assets;
        uint256 expectedShares = Math.mulDiv(assets, supplyBefore + 1e12, recognized + 1);
        if (expectedShares == 0 || supplyBefore + expectedShares < accounting.MIN_SHARE_SUPPLY()) {
            bytes32 beforeHash = _stateHash();
            if (expectedShares == 0) {
                vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroShares.selector);
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        AlphaEngineUSDCVaultManager.InsufficientShareSupply.selector,
                        supplyBefore + expectedShares,
                        accounting.MIN_SHARE_SUPPLY()
                    )
                );
            }
            vm.prank(owner);
            accounting.deposit(assets, owner, 0);
            assertEq(_stateHash(), beforeHash);
            return;
        }
        vm.recordLogs();
        vm.prank(owner);
        uint256 minted = accounting.deposit(assets, owner, 0);
        if (supplyBefore != 0) {
            assertLe(minted * (recognized + 1), assets * (supplyBefore + 1e12));
            assertLt(assets * (supplyBefore + 1e12) - minted * (recognized + 1), recognized + 1);
            if (assets * (supplyBefore + 1e12) > minted * (recognized + 1) + supplyBefore + 1e12) {
                incomingRoundingLossViolation = true;
            }
        } else {
            assertEq(minted, assets * 1e12);
        }
        _shares[owner] += minted;
        ghostSupply += minted;
        ghostIdle += assets;
        ghostManaged += assets;
        Vm.Log memory entry = _event(
            vm.getRecordedLogs(),
            address(accounting),
            keccak256("Deposit(address,address,uint256,uint256)")
        );
        assertEq(entry.topics[1], bytes32(uint256(uint160(owner))));
        assertEq(entry.topics[2], bytes32(uint256(uint160(owner))));
        assertEq(entry.data, abi.encode(assets, minted));
    }

    function request(uint256 actorSeed, uint256 sharesSeed) public {
        if (fundVault.recoveryActivated()) return;
        address owner = _lp(actorSeed);
        uint256 balance = _shares[owner];
        if (balance == 0) return;
        uint256 shares = sharesSeed % 4 == 0
            ? balance
            : sharesSeed % 4 == 1 && balance > 1 ? balance - 1 : bound(sharesSeed, 1, balance);
        vm.recordLogs();
        vm.prank(owner);
        uint64 id = accounting.requestRedeem(shares, owner, 0);
        _requests.push(id);
        _requestModel[id] = AlphaEngineUSDCVaultManager.RedemptionRequest(
            owner, owner, shares, 0, AlphaEngineUSDCVaultManager.RedemptionStatus.Pending
        );
        _shares[owner] -= shares;
        ghostEscrowShares += shares;
        Vm.Log memory entry = _event(
            vm.getRecordedLogs(),
            address(accounting),
            keccak256("RedemptionRequested(uint64,address,address,uint256,uint256)")
        );
        assertEq(entry.topics[1], bytes32(uint256(id)));
        assertEq(entry.topics[2], bytes32(uint256(uint160(owner))));
        assertEq(entry.topics[3], bytes32(uint256(uint160(owner))));
        assertEq(entry.data, abi.encode(shares, uint256(0)));
    }

    function cancelRequest(uint256 seed) public {
        if (_requests.length == 0) return;
        uint64 id = _requests[seed % _requests.length];
        AlphaEngineUSDCVaultManager.RedemptionRequest storage expected = _requestModel[id];
        if (expected.status != AlphaEngineUSDCVaultManager.RedemptionStatus.Pending) return;
        vm.recordLogs();
        vm.prank(expected.owner);
        accounting.cancelRedeem(id);
        expected.status = AlphaEngineUSDCVaultManager.RedemptionStatus.Cancelled;
        _shares[expected.owner] += expected.shares;
        ghostEscrowShares -= expected.shares;
        Vm.Log memory entry = _event(
            vm.getRecordedLogs(),
            address(accounting),
            keccak256("RedemptionCancelled(uint64,address,uint256)")
        );
        assertEq(entry.topics[1], bytes32(uint256(id)));
        assertEq(entry.topics[2], bytes32(uint256(uint160(expected.owner))));
        assertEq(entry.data, abi.encode(expected.shares));
    }

    function completeRequest(uint256 seed) public {
        if (_requests.length == 0) return;
        _settle();
        uint64 id = _requests[seed % _requests.length];
        AlphaEngineUSDCVaultManager.RedemptionRequest storage expected = _requestModel[id];
        bytes32 beforeHash = _stateHash();
        uint256 remaining = accounting.remainingLockedProfit();
        uint256 assets = ghostSupply == 0
            ? 0
            : Math.mulDiv(expected.shares, ghostManaged - remaining + 1, ghostSupply + 1e12);
        uint256 required = expected.shares == ghostSupply ? ghostManaged : assets;
        bytes memory failure;
        if (expected.status != AlphaEngineUSDCVaultManager.RedemptionStatus.Pending) {
            failure = abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InvalidRedemptionStatus.selector, id, expected.status
            );
        } else if (
            expected.shares < ghostSupply
                && ghostSupply - expected.shares < accounting.MIN_SHARE_SUPPLY()
        ) {
            failure = abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientShareSupply.selector,
                ghostSupply - expected.shares,
                accounting.MIN_SHARE_SUPPLY()
            );
        } else if (expected.shares == ghostSupply && remaining != 0) {
            failure = abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.FinalRedemptionWhileProfitLocked.selector, remaining
            );
        } else if (required > ghostIdle) {
            failure = abi.encodeWithSelector(
                AlphaEngineUSDCVaultManager.InsufficientVaultLiquidity.selector, ghostIdle, required
            );
        }
        if (failure.length != 0) {
            vm.expectRevert(failure);
            accounting.completeRedeem(id);
            assertEq(_stateHash(), beforeHash);
            ++rejectedCompletions;
            return;
        }
        uint256 cashBefore = assetIn.balanceOf(expected.receiver);
        vm.recordLogs();
        uint256 paid = accounting.completeRedeem(id);
        assertEq(paid, assets);
        assertEq(assetIn.balanceOf(expected.receiver) - cashBefore, assets);
        ghostIdle -= required;
        ghostManaged -= required;
        ghostProtocolResidual += required - assets;
        ghostEscrowShares -= expected.shares;
        ghostSupply -= expected.shares;
        expected.status = AlphaEngineUSDCVaultManager.RedemptionStatus.Completed;
        Vm.Log memory entry = _event(
            vm.getRecordedLogs(),
            address(accounting),
            keccak256("RedemptionCompleted(uint64,address,uint256,uint256)")
        );
        assertEq(entry.topics[1], bytes32(uint256(id)));
        assertEq(entry.topics[2], bytes32(uint256(uint160(expected.receiver))));
        assertEq(entry.data, abi.encode(expected.shares, assets));
        ++completedRequests;
    }

    function prepareEntry(uint256 seed) public {
        _prepare(false, seed);
    }

    function prepareExit(uint256 seed) public {
        _prepare(true, seed);
    }

    function _prepare(bool exiting, uint256 seed) private {
        if (fundVault.recoveryActivated()) return;
        _ensureQualification();
        uint256 capacity = exiting ? ghostPositionTokens / 1e18 : ghostIdle / markPrice;
        if (capacity == 0) return;
        uint256 units = bound(seed, 1, Math.min(capacity, 100));
        uint256 input = exiting ? units * 1e18 : units * markPrice;
        uint256 output = exiting ? units * markPrice : units * 1e18;
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
        ) = _tradeBundle(exiting, input, output);
        bytes32 intentId = _submitCapitalIntent();
        AlphaEngineCapitalStrategyManager.CapitalIntentIdentity memory identity =
            capitalManager.getCapitalIntentIdentity(intentId);
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
            capitalManager.getCapitalIntentState(intentId);
        (bytes32 root,, uint64 version) = executionManager.activePolicies(executor);
        uint40 deadline = uint40(block.timestamp + 1 hours);
        if (deadline > state.deadline) deadline = state.deadline;
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1({
                chainId: block.chainid,
                capitalStrategyManager: address(capitalManager),
                vaultExecutionManager: address(executionManager),
                fundVault: address(fundVault),
                intentId: intentId,
                trader: trader,
                qualificationVersion: state.qualificationVersion,
                executor: executor,
                authorizationNonce: capitalManager.nextAuthorizationNonce(),
                validAfter: uint40(block.timestamp),
                deadline: deadline,
                policyRoot: root,
                policyVersion: version,
                callsHash: AlphaEngineExecutionHashLib.hashCalls(calls),
                riskEnvelopeHash: AlphaEngineExecutionHashLib.hashRiskEnvelope(limits),
                riskPolicyVersion: executionManager.riskPolicyVersion(),
                submissionPayloadHash: identity.payloadHash,
                evaluationEvidenceHash: keccak256(abi.encode("shared evaluation", intentId))
            });
        AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores = _capitalScores();
        vm.prank(evaluator);
        capitalManager.approveCapitalIntent(intentId, scores, authorization);
        _prepared.push(Prepared(authorization, input, output, exiting));
    }

    function executePrepared(uint256 seed) public {
        if (_prepared.length == 0 || fundVault.recoveryActivated()) return;
        Prepared memory prepared = _prepared[seed % _prepared.length];
        (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _tradeBundle(prepared.exiting, prepared.input, prepared.output);
        bytes32 beforeHash = _stateHash();
        bytes32 commitment =
            AlphaEngineExecutionHashLib.hashExecutionCommitment(prepared.authorization);
        bytes memory failure = _executionFailure(prepared, commitment);
        if (failure.length != 0) {
            vm.expectRevert(failure);
            vm.prank(executor);
            executionManager.executeCapitalIntent(prepared.authorization, calls, limits, proofs);
            assertEq(_stateHash(), beforeHash);
            ++rejectedExecutions;
            return;
        }
        uint256 beforeSupply = fundVault.totalSupply();
        uint256 beforeNav = accounting.managedAssets();
        uint256 bookBefore = ghostIdle + positionBook();
        bytes32 beforeClaims = _claimsHash();
        vm.recordLogs();
        vm.prank(executor);
        executionManager.executeCapitalIntent(prepared.authorization, calls, limits, proofs);
        if (prepared.exiting) {
            ghostPositionTokens -= prepared.input;
            ghostIdle += prepared.output;
            ++successfulExits;
        } else {
            ghostIdle -= prepared.input;
            ghostPositionTokens += prepared.output;
            ++successfulEntries;
        }
        uint256 bookAfter = ghostIdle + positionBook();
        if (bookAfter > bookBefore) {
            // A committed old quote may create real P&L after a mark change. Fund that simulated market liability explicitly.
            assetIn.mint(address(strategyTarget), bookAfter - bookBefore);
            ghostExternalFunding += bookAfter - bookBefore;
        }
        // EX-02: execution has no share or accounting ownership even with real funded LP requests.
        assertEq(fundVault.totalSupply(), beforeSupply);
        assertEq(accounting.managedAssets(), beforeNav);
        assertEq(_claimsHash(), beforeClaims);
        assertTrue(capitalManager.isExecutionConsumed(commitment));
        assertTrue(executionManager.consumedExecutionCommitments(commitment));
        assertTrue(
            capitalManager.consumedAuthorizationNonces(prepared.authorization.authorizationNonce)
        );
        assertTrue(
            executionManager.consumedAuthorizationNonces(prepared.authorization.authorizationNonce)
        );
        Vm.Log memory entry = _event(
            vm.getRecordedLogs(),
            address(executionManager),
            keccak256(
                "CapitalIntentExecuted(bytes32,address,bytes32,address,uint64,bytes32,bytes32)"
            )
        );
        assertEq(entry.topics[1], prepared.authorization.intentId);
        assertEq(entry.topics[2], bytes32(uint256(uint160(trader))));
        assertEq(entry.topics[3], commitment);
        assertEq(
            entry.data,
            abi.encode(
                executor,
                prepared.authorization.authorizationNonce,
                prepared.authorization.callsHash,
                prepared.authorization.riskEnvelopeHash
            )
        );
    }

    function markPosition(uint96 priceSeed) public {
        if (fundVault.recoveryActivated() || ghostPositionTokens == 0) return;
        uint256 oldBook = positionBook();
        markPrice = bound(uint256(priceSeed), 500_000, 2_000_000);
        uint256 newBook = positionBook();
        if (newBook > oldBook) {
            // Independent market reserves fund gains; idle vault cash is never fabricated by reporting.
            assetIn.mint(address(strategyTarget), newBook - oldBook);
            ghostExternalFunding += newBook - oldBook;
        }
        reportBook();
    }

    function reportBook() public {
        if (fundVault.recoveryActivated()) return;
        _settle();
        uint256 book = ghostIdle + positionBook();
        if (book == ghostManaged) return;
        uint256 idleBefore = assetIn.balanceOf(address(fundVault));
        uint64 epoch = accounting.reportEpoch() + 1;
        uint64 referenceBlock = accounting.lastReferenceBlock() + 1;
        if (block.number <= referenceBlock) vm.roll(uint256(referenceBlock) + 1);
        if (book > ghostManaged) {
            uint256 profit = book - ghostManaged;
            if (ghostSupply == 0) {
                bytes32 beforeHash = _stateHash();
                vm.expectRevert(AlphaEngineUSDCVaultManager.ZeroShares.selector);
                vm.prank(navReporter);
                accounting.reportProfit(
                    epoch, referenceBlock, profit, keccak256(abi.encode("position NAV", book))
                );
                assertEq(_stateHash(), beforeHash);
                return;
            }
            if (accounting.remainingLockedProfit() != 0) {
                bytes32 beforeHash = _stateHash();
                vm.expectRevert(
                    abi.encodeWithSelector(
                        AlphaEngineUSDCVaultManager.ProfitStillVesting.selector,
                        accounting.remainingLockedProfit()
                    )
                );
                vm.prank(navReporter);
                accounting.reportProfit(
                    epoch, referenceBlock, profit, keccak256(abi.encode("position NAV", book))
                );
                assertEq(_stateHash(), beforeHash);
                return;
            }
            uint256 recovery = Math.min(profit, accounting.lossToRecover());
            uint256 expectedFee =
                Math.mulDiv(profit - recovery, accounting.performanceFeeBps(), 10_000);
            uint256 expectedFeeShares =
                Math.mulDiv(expectedFee, ghostSupply + 1e12, ghostManaged + 1);
            uint256 feeBefore = fundVault.balanceOf(feeRecipient);
            vm.recordLogs();
            vm.prank(navReporter);
            accounting.reportProfit(
                epoch, referenceBlock, profit, keccak256(abi.encode("position NAV", book))
            );
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 minted = fundVault.balanceOf(feeRecipient) - feeBefore;
            assertEq(minted, expectedFeeShares);
            if (minted != 0) {
                Vm.Log memory feeEvent = _event(
                    logs,
                    address(accounting),
                    keccak256("PerformanceFeeMinted(address,uint256,uint256)")
                );
                assertEq(feeEvent.topics[1], bytes32(uint256(uint160(feeRecipient))));
                assertEq(feeEvent.data, abi.encode(expectedFee, minted));
                uint256 feeValue = Math.mulDiv(
                    minted, ghostManaged + expectedFee + 1, ghostSupply + minted + 1e12
                );
                if (feeValue > expectedFee || feeValue + 1 < expectedFee) {
                    feeEntitlementViolation = true;
                }
            }
            _observeFeeMint(feeBefore);
            Vm.Log memory entry = _event(
                logs,
                address(accounting),
                keccak256("ProfitReported(uint64,uint64,uint256,uint256,uint256,bytes32)")
            );
            assertEq(entry.topics[1], bytes32(uint256(epoch)));
            assertEq(entry.topics[2], bytes32(uint256(referenceBlock)));
            assertEq(
                entry.data,
                abi.encode(
                    profit, recovery, expectedFee, keccak256(abi.encode("position NAV", book))
                )
            );
            ghostManaged += profit;
            ++successfulProfitReports;
        } else {
            uint256 loss = ghostManaged - book;
            uint256 feeBefore = fundVault.balanceOf(feeRecipient);
            uint256 cancelledLocked = Math.min(loss, accounting.remainingLockedProfit());
            vm.recordLogs();
            vm.prank(navReporter);
            accounting.reportLoss(
                epoch, referenceBlock, loss, keccak256(abi.encode("position NAV", book))
            );
            assertEq(fundVault.balanceOf(feeRecipient), feeBefore);
            Vm.Log memory entry = _event(
                vm.getRecordedLogs(),
                address(accounting),
                keccak256("LossReported(uint64,uint64,uint256,uint256,bytes32)")
            );
            assertEq(entry.topics[1], bytes32(uint256(epoch)));
            assertEq(entry.topics[2], bytes32(uint256(referenceBlock)));
            assertEq(
                entry.data,
                abi.encode(loss, cancelledLocked, keccak256(abi.encode("position NAV", book)))
            );
            ghostManaged -= loss;
            ++successfulLossReports;
        }
        assertEq(accounting.reportEpoch(), epoch);
        assertEq(accounting.lastReferenceBlock(), referenceBlock);
        assertEq(assetIn.balanceOf(address(fundVault)), idleBefore);
    }

    function advanceTime(uint32 delta) public {
        vm.warp(block.timestamp + uint256(delta) % (3 days + 1));
        _settle();
    }

    function marketLiquidity(uint96 amountSeed, bool restore) public {
        uint256 balance =
            assetIn.balanceOf(restore ? MARKET_LIQUIDITY_SINK : address(strategyTarget));
        if (balance == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, balance);
        vm.prank(restore ? MARKET_LIQUIDITY_SINK : address(strategyTarget));
        assetIn.transfer(restore ? address(strategyTarget) : MARKET_LIQUIDITY_SINK, amount);
    }

    /// @dev QC-12/XS-03: qualification revocation fails inside real consumption; natural expiry also expires the bound authorization.
    function invalidateQualification(uint256 seed, bool expire) public {
        if (fundVault.recoveryActivated()) return;
        uint256 beforeCount = _prepared.length;
        _prepare(ghostIdle < markPrice, seed);
        if (_prepared.length == beforeCount) return;
        Prepared memory prepared = _prepared[beforeCount];
        if (expire) {
            vm.warp(registry.getQualification(trader).validUntil);
        } else {
            vm.prank(revoker);
            registry.revokeTrader(trader, keccak256("between approval and real execution"));
        }
        uint256 failures = rejectedExecutions;
        executePrepared(beforeCount);
        assertEq(rejectedExecutions, failures + 1);
        bytes32 commitment =
            AlphaEngineExecutionHashLib.hashExecutionCommitment(prepared.authorization);
        assertFalse(capitalManager.isExecutionConsumed(commitment));
        assertFalse(executionManager.consumedExecutionCommitments(commitment));
        assertFalse(
            capitalManager.consumedAuthorizationNonces(prepared.authorization.authorizationNonce)
        );
        assertFalse(
            executionManager.consumedAuthorizationNonces(prepared.authorization.authorizationNonce)
        );
        _ensureQualification();
        executePrepared(beforeCount); // Same wallet with a new version cannot revive the old approval.
        uint256 fresh = _prepared.length;
        _prepare(ghostIdle < markPrice, seed);
        if (_prepared.length != fresh) executePrepared(fresh);
    }

    /// @dev XS-03/EX-17: policy/risk changes invalidate old approvals; a fresh approval is required to continue.
    function invalidatePolicyOrRisk(uint256 seed, bool revokeRoot) public {
        if (fundVault.recoveryActivated()) return;
        uint256 index = _prepared.length;
        _prepare(ghostIdle < markPrice, seed);
        if (_prepared.length == index) return;
        if (revokeRoot) {
            vm.prank(rootGuardian);
            executionManager.revokePolicyRoot(executor);
            vm.prank(admin);
            executionManager.unpause();
            executePrepared(index);
            uint40 activateAfter = uint40(block.timestamp + 48 hours);
            vm.prank(rootProposer);
            executionManager.proposePolicyRoot(
                executor, policyRoot, keccak256("restored reviewed policy"), activateAfter
            );
            vm.warp(activateAfter);
            executionManager.activatePolicyRoot(executor);
        } else {
            vm.prank(rootGuardian);
            executionManager.pause();
            _changeRiskVersion();
            vm.prank(admin);
            executionManager.unpause();
            executePrepared(index);
        }
        uint256 fresh = _prepared.length;
        _prepare(ghostIdle < markPrice, seed);
        if (_prepared.length != fresh) executePrepared(fresh);
        ++governanceChecks;
    }

    /// @dev XS-05: pause each real boundary, remove evaluator authority, and pause the registry with live approvals/LP requests.
    function governanceCycle(uint256 seed, uint8 mode) public {
        if (fundVault.recoveryActivated()) return;
        uint256 index = _prepared.length;
        _prepare(ghostIdle < markPrice, seed);
        if (_prepared.length == index) return;
        mode %= 4;
        if (mode == 0) {
            vm.prank(pauser);
            capitalManager.pause();
            executePrepared(index);
            vm.prank(admin);
            capitalManager.unpause();
        } else if (mode == 1) {
            vm.prank(rootGuardian);
            executionManager.pause();
            executePrepared(index);
            vm.prank(admin);
            executionManager.unpause();
        } else if (mode == 2) {
            vm.prank(rootGuardian);
            fundVault.pause();
            executePrepared(index);
            vm.prank(admin);
            fundVault.unpause();
        } else {
            bytes32 evaluatorRole = capitalManager.EVALUATOR_ROLE();
            vm.prank(admin);
            capitalManager.revokeRole(evaluatorRole, evaluator);
            AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory scores =
                _capitalScores();
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector,
                    evaluator,
                    evaluatorRole
                )
            );
            vm.prank(evaluator);
            capitalManager.rejectCapitalIntent(
                _prepared[index].authorization.intentId,
                scores,
                keccak256("evidence"),
                keccak256("reason")
            );
            vm.prank(admin);
            capitalManager.grantRole(evaluatorRole, evaluator);
            vm.prank(pauser);
            registry.pause();
            bytes32 beforeHash = _stateHash();
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(issuer);
            registry.qualifyTrader(
                trader,
                uint40(block.timestamp + 90 days),
                keccak256("source"),
                keccak256("evidence")
            );
            assertEq(_stateHash(), beforeHash);
            // Registry pause blocks issuance, not active-version reads or an already approved execution.
            executePrepared(index);
            vm.prank(admin);
            registry.unpause();
        }
        if (mode != 3) executePrepared(index);
        ++governanceChecks;
    }

    /// @dev EX-17: a loss is real NAV, while a temporarily unfunded unwind must fail and preserve the position/claims.
    function stressUnwind(uint256 seed) public {
        if (fundVault.recoveryActivated() || ghostPositionTokens == 0) return;
        uint256 nextPrice =
            markPrice > 500_000 ? markPrice - Math.min(markPrice - 500_000, 100_000) : 500_000;
        markPosition(uint96(nextPrice));
        uint256 reserves = assetIn.balanceOf(address(strategyTarget));
        if (reserves != 0) {
            vm.prank(address(strategyTarget));
            assetIn.transfer(MARKET_LIQUIDITY_SINK, reserves);
        }
        uint256 index = _prepared.length;
        _prepare(true, seed);
        if (_prepared.length == index) return;
        executePrepared(index);
        vm.prank(rootGuardian);
        executionManager.pause();
        _changeRiskVersion();
        vm.prank(admin);
        executionManager.unpause();
        executePrepared(index);
        _restoreMarketLiquidity();
        vm.warp(block.timestamp + 1 days + 1);
        uint256 fresh = _prepared.length;
        _prepare(true, seed);
        executePrepared(fresh);
    }

    /// @dev XS-01: a superseded competition entry cannot rank/qualify; its replacement can lead to real capital execution.
    function competitionToCapital(uint128 market, uint128 component) public {
        if (fundVault.recoveryActivated()) return;
        vm.warp(block.timestamp + competitionManager.submissionWindowSeconds());
        bytes32 id = competitionManager.createCompetition(
            AlphaEngineCompetitionStrategyManager.CompetitionConfig({
                rulesHash: keccak256(
                    abi.encode("shared competition", market, component, competitionChains)
                ),
                submissionDeadline: uint40(block.timestamp + 1 hours),
                evaluationDeadline: uint40(block.timestamp + 2 hours),
                qualificationValidUntil: uint40(block.timestamp + 60 days),
                qualificationSlots: 1
            })
        );
        bytes32 old = _competitionSubmission(id, market, component);
        bytes32 latest = _competitionSubmission(id, market, component ^ 1);
        assertEq(competitionManager.activeSubmissionByTrader(id, trader), latest);
        assertEq(
            uint8(competitionManager.getSubmissionState(old).status),
            uint8(AlphaEngineCompetitionStrategyManager.SubmissionStatus.Superseded)
        );
        vm.warp(competitionManager.getCompetition(id).submissionDeadline);
        competitionManager.beginEvaluation(id);
        AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission memory scores =
            _withScoreProof(
                address(competitionManager),
                AlphaEngineCompetitionStrategyManager.EvaluationScoreSubmission(
                    createExternalEuint32(90, address(this)),
                    createExternalEuint32(80, address(this)),
                    createExternalEuint32(70, address(this)),
                    ""
                )
            );
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.SubmissionNotSubmitted.selector,
                old,
                AlphaEngineCompetitionStrategyManager.SubmissionStatus.Superseded
            )
        );
        competitionManager.recordEvaluation(old, scores, 1, keccak256("old evidence"));
        competitionManager.recordEvaluation(latest, scores, 1, keccak256("new evidence"));
        competitionManager.finalizeCompetition(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.SubmissionNotEligible.selector,
                old,
                uint16(0),
                uint16(1)
            )
        );
        competitionManager.publishTraderQualification(old);
        competitionManager.publishTraderQualification(latest);
        assertEq(registry.getQualification(trader).sourceCompetitionId, id);
        assertEq(registry.getQualification(trader).evidenceHash, keccak256("new evidence"));
        if (ghostIdle < markPrice) deposit(1, 10e6);
        uint256 index = _prepared.length;
        _prepare(false, 1);
        if (_prepared.length != index) executePrepared(index);
        ++competitionChains;
    }

    /// @dev FV-29/EX-14/XS-06: recovery moves assets only to the configured recipient and leaves source claim records intact.
    /// Completing claims in a replacement vault still requires an owner-approved migration policy.
    function recoveryCheckpoint() public {
        if (fundVault.recoveryActivated() || (ghostIdle == 0 && ghostPositionTokens == 0)) return;
        if (_shares[lp1] == 0) deposit(1, 100e6);
        uint256 ownerSeed = _shares[lp1] != 0 ? 1 : 0;
        if (_shares[_lp(ownerSeed)] == 0) return;
        request(ownerSeed, 0);
        uint256 pendingAssets =
            accounting.previewRedeem(_requestModel[_requests[_requests.length - 1]].shares);
        bytes32 beforeClaims = _claimsHash();
        address recipient = fundVault.recoveryVault();
        uint256 recoveryUsdcBefore = assetIn.balanceOf(recipient);
        uint256 recoveryPositionBefore = assetOut.balanceOf(recipient);
        vm.prank(rootGuardian);
        fundVault.pause();
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.UnauthorizedEmergencyAuthority.selector, address(this)
            )
        );
        fundVault.recoverAsset(assetIn);
        if (ghostIdle != 0) {
            vm.recordLogs();
            vm.prank(rootGuardian);
            fundVault.recoverAsset(assetIn);
            Vm.Log memory entry = _event(
                vm.getRecordedLogs(),
                address(fundVault),
                keccak256("AssetRecovered(address,address,uint256)")
            );
            assertEq(entry.topics[1], bytes32(uint256(uint160(address(assetIn)))));
            assertEq(entry.topics[2], bytes32(uint256(uint160(recipient))));
            assertEq(entry.data, abi.encode(ghostIdle));
        }
        if (ghostPositionTokens != 0) {
            vm.recordLogs();
            vm.prank(rootGuardian);
            fundVault.recoverAsset(assetOut);
            Vm.Log memory entry = _event(
                vm.getRecordedLogs(),
                address(fundVault),
                keccak256("AssetRecovered(address,address,uint256)")
            );
            assertEq(entry.topics[1], bytes32(uint256(uint160(address(assetOut)))));
            assertEq(entry.topics[2], bytes32(uint256(uint160(recipient))));
            assertEq(entry.data, abi.encode(ghostPositionTokens));
        }
        ghostRecoveryUsdc += ghostIdle;
        ghostRecoveryPositions += ghostPositionTokens;
        ghostIdle = 0;
        ghostPositionTokens = 0;
        assertEq(assetIn.balanceOf(recipient) - recoveryUsdcBefore, ghostRecoveryUsdc);
        assertEq(assetOut.balanceOf(recipient) - recoveryPositionBefore, ghostRecoveryPositions);
        assertEq(_claimsHash(), beforeClaims);
        vm.expectRevert(AlphaEngineFundVault.RecoveryAlreadyActivated.selector);
        vm.prank(admin);
        fundVault.unpause();
        uint256 failures = rejectedCompletions;
        completeRequest(_requests.length - 1);
        if (pendingAssets != 0) assertEq(rejectedCompletions, failures + 1);
        ++recoveryChecks;
    }

    /// @dev Bounded liveness witness: explicitly authorized partial/full unwind returns actual USDC before pending exits drain.
    function drain() public {
        if (fundVault.recoveryActivated()) return;
        _restoreMarketLiquidity();
        for (uint256 i; i < 40 && ghostPositionTokens != 0; ++i) {
            // The optimizer may cache block.timestamp across warp calls in this loop.
            vm.warp(vm.getBlockTimestamp() + 1 days + 1);
            uint256 index = _prepared.length;
            _prepare(true, 100);
            executePrepared(index);
        }
        assertEq(ghostPositionTokens, 0, "bounded position drain failed");
        reportBook();
        if (vm.getBlockTimestamp() < accounting.profitUnlockTimestamp()) {
            vm.warp(accounting.profitUnlockTimestamp());
        }
        _settle();
        for (uint256 i; i < _requests.length; ++i) {
            if (
                _requestModel[_requests[i]].status
                    == AlphaEngineUSDCVaultManager.RedemptionStatus.Pending
            ) {
                uint256 remainingSupply = ghostSupply - _requestModel[_requests[i]].shares;
                if (remainingSupply != 0 && remainingSupply < accounting.MIN_SHARE_SUPPLY()) {
                    completeRequest(i); // Must reject atomically under the minimum-supply rule.
                    continue;
                }
                completeRequest(i);
                assertEq(
                    uint8(_requestModel[_requests[i]].status),
                    uint8(AlphaEngineUSDCVaultManager.RedemptionStatus.Completed),
                    "eligible shared request did not drain"
                );
            }
        }
    }

    function _changeRiskVersion() private {
        (uint256 current,) = executionManager.traderAssetRiskLimits(trader, address(assetIn));
        AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[] memory updates =
            new AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[](1);
        updates[0] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput(
            address(assetIn), current == 200e6 ? 201e6 : 200e6, 500e6
        );
        vm.prank(admin);
        executionManager.setTraderAssetRiskLimits(trader, updates);
    }

    function _restoreMarketLiquidity() private {
        uint256 amount = assetIn.balanceOf(MARKET_LIQUIDITY_SINK);
        if (amount != 0) {
            vm.prank(MARKET_LIQUIDITY_SINK);
            assetIn.transfer(address(strategyTarget), amount);
        }
    }

    function _competitionSubmission(bytes32 id, uint128 market, uint128 component)
        private
        returns (bytes32)
    {
        externalEuint128 encryptedMarket = createExternalEuint128(market, trader);
        externalEuint128[] memory components = new externalEuint128[](1);
        components[0] = createExternalEuint128(component, trader);
        bytes memory proof =
            _strategyProof(address(competitionManager), encryptedMarket, components);
        vm.prank(trader);
        return competitionManager.submitCompetitionStrategy(
            id, keccak256("1h"), encryptedMarket, components, proof
        );
    }

    function property_independentFundBookAndClaims() external view {
        assertEq(accounting.managedAssets(), ghostManaged);
        assertEq(assetIn.balanceOf(address(fundVault)), ghostIdle);
        assertEq(assetOut.balanceOf(address(fundVault)), ghostPositionTokens);
        assertEq(fundVault.totalSupply(), ghostSupply);
        assertEq(fundVault.balanceOf(lp0), _shares[lp0]);
        assertEq(fundVault.balanceOf(lp1), _shares[lp1]);
        assertEq(fundVault.balanceOf(feeRecipient), ghostFeeShares);
        assertEq(fundVault.balanceOf(address(fundVault)), ghostEscrowShares);
        assertEq(ghostSupply, _shares[lp0] + _shares[lp1] + ghostFeeShares + ghostEscrowShares);
        assertEq(assetIn.balanceOf(fundVault.recoveryVault()), ghostRecoveryUsdc);
        assertEq(assetOut.balanceOf(fundVault.recoveryVault()), ghostRecoveryPositions);
        uint256 physicalCash = assetIn.balanceOf(lp0) + assetIn.balanceOf(lp1) + ghostIdle
            + assetIn.balanceOf(address(strategyTarget)) + ghostRecoveryUsdc
            + assetIn.balanceOf(MARKET_LIQUIDITY_SINK) + ghostProtocolResidual;
        assertEq(assetIn.balanceOf(feeRecipient), ghostProtocolResidual);
        assertEq(physicalCash, ghostExternalFunding);
        assertEq(assetIn.allowance(address(fundVault), address(strategyTarget)), 0);
        assertEq(assetOut.allowance(address(fundVault), address(strategyTarget)), 0);
        assertEq(assetIn.balanceOf(address(executionManager)), 0);
        assertEq(assetOut.balanceOf(address(executionManager)), 0);
        assertEq(assetIn.balanceOf(address(capitalManager)), 0);
        assertEq(assetIn.balanceOf(address(accounting)), 0);
        for (uint256 i; i < _requests.length; ++i) {
            assertEq(
                keccak256(abi.encode(accounting.getRedemption(_requests[i]))),
                keccak256(abi.encode(_requestModel[_requests[i]]))
            );
        }
        for (uint256 i; i < _prepared.length; ++i) {
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _prepared[i].authorization;
            bytes32 commitment = AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);
            bool consumed = capitalManager.getCapitalIntentState(authorization.intentId).status
                == AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Consumed;
            assertEq(capitalManager.isExecutionConsumed(commitment), consumed);
            assertEq(executionManager.consumedExecutionCommitments(commitment), consumed);
            assertEq(
                capitalManager.consumedAuthorizationNonces(authorization.authorizationNonce),
                consumed
            );
            assertEq(
                executionManager.consumedAuthorizationNonces(authorization.authorizationNonce),
                consumed
            );
        }
    }

    function preparedCount() external view returns (uint256) {
        return _prepared.length;
    }

    function requestCount() external view returns (uint256) {
        return _requests.length;
    }

    function positionBook() public view returns (uint256) {
        return Math.mulDiv(ghostPositionTokens, markPrice, 1e18);
    }

    function _settle() private {
        uint256 feeBefore = fundVault.balanceOf(feeRecipient);
        assertEq(accounting.settleFinishedProfit(), 0);
        assertEq(fundVault.balanceOf(feeRecipient), feeBefore);
    }

    function _observeFeeMint(uint256 previousBalance) private {
        uint256 minted = fundVault.balanceOf(feeRecipient) - previousBalance;
        ghostFeeShares += minted;
        ghostSupply += minted;
    }

    function _lp(uint256 seed) private view returns (address) {
        return seed % 2 == 0 ? lp0 : lp1;
    }

    function _ensureQualification() private {
        if (registry.isQualified(trader)) return;
        vm.prank(issuer);
        registry.qualifyTrader(
            trader,
            uint40(block.timestamp + 30 days),
            keccak256("fresh competition"),
            keccak256("fresh qualification")
        );
    }

    function _capitalScores()
        private
        returns (AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission memory)
    {
        return _withScoreProof(
            address(capitalManager),
            AlphaEngineCapitalStrategyManager.EvaluationScoreSubmission({
                realSisterScore: createExternalEuint32(88, evaluator),
                perturbationP25Score: createExternalEuint32(77, evaluator),
                stressP25Score: createExternalEuint32(66, evaluator),
                inputProof: ""
            })
        );
    }

    function _tradeBundle(bool exiting, uint256 input, uint256 output)
        private
        view
        returns (
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        )
    {
        if (!exiting) return _bundle(input, output);
        calls = new AlphaEngineExecutionHashLib.CallV1[](3);
        calls[0] = AlphaEngineExecutionHashLib.CallV1(
            address(erc20Decoder),
            address(assetOut),
            0,
            abi.encodeCall(IERC20.approve, (address(strategyTarget), input))
        );
        calls[1] = AlphaEngineExecutionHashLib.CallV1(
            address(strategyDecoder),
            address(strategyTarget),
            0,
            abi.encodeCall(
                MockVaultStrategyTarget.swapExact,
                (address(assetOut), address(assetIn), input, output)
            )
        );
        calls[2] = AlphaEngineExecutionHashLib.CallV1(
            address(erc20Decoder),
            address(assetOut),
            0,
            abi.encodeCall(IERC20.approve, (address(strategyTarget), 0))
        );
        limits = new AlphaEngineExecutionHashLib.AssetDeltaLimitV1[](2);
        limits[0] = AlphaEngineExecutionHashLib.AssetDeltaLimitV1(address(assetOut), input, 0);
        limits[1] = AlphaEngineExecutionHashLib.AssetDeltaLimitV1(address(assetIn), 0, output);
        if (address(assetOut) > address(assetIn)) (limits[0], limits[1]) = (limits[1], limits[0]);
        proofs = new bytes32[][](3);
        proofs[0] = _proof(positionApprovalLeaf);
        proofs[1] = _proof(exitLeaf);
        proofs[2] = _proof(positionApprovalLeaf);
    }

    function _event(Vm.Log[] memory logs, address emitter, bytes32 signature)
        private
        pure
        returns (Vm.Log memory)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length != 0
                    && logs[i].topics[0] == signature
            ) return logs[i];
        }
        revert MissingExpectedEvent(signature);
    }

    function _claimsHash() private view returns (bytes32 result) {
        result = keccak256(
            abi.encode(
                fundVault.totalSupply(),
                fundVault.balanceOf(lp0),
                fundVault.balanceOf(lp1),
                fundVault.balanceOf(feeRecipient),
                fundVault.balanceOf(address(fundVault)),
                accounting.managedAssets()
            )
        );
        for (uint256 i; i < _requests.length; ++i) {
            result = keccak256(abi.encode(result, accounting.getRedemption(_requests[i])));
        }
    }

    function _stateHash() private view returns (bytes32 result) {
        result = keccak256(
            abi.encode(
                _claimsHash(),
                assetIn.balanceOf(address(fundVault)),
                assetOut.balanceOf(address(fundVault)),
                assetIn.balanceOf(address(strategyTarget)),
                assetOut.balanceOf(address(strategyTarget)),
                assetIn.allowance(address(fundVault), address(strategyTarget)),
                assetOut.allowance(address(fundVault), address(strategyTarget)),
                accounting.reportEpoch(),
                registry.getQualification(trader),
                executionManager.currentWindowSpend(trader, address(assetIn)),
                executionManager.currentWindowSpend(trader, address(assetOut)),
                capitalManager.traderNonces(trader),
                capitalManager.nextAuthorizationNonce()
            )
        );
        for (uint256 i; i < _prepared.length; ++i) {
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
            _prepared[i].authorization;
            bytes32 commitment = AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);
            result = keccak256(
                abi.encode(
                    result,
                    capitalManager.getCapitalIntentState(authorization.intentId),
                    capitalManager.isExecutionConsumed(commitment),
                    executionManager.consumedExecutionCommitments(commitment),
                    capitalManager.consumedAuthorizationNonces(authorization.authorizationNonce),
                    executionManager.consumedAuthorizationNonces(authorization.authorizationNonce)
                )
            );
        }
    }

    function _executionFailure(Prepared memory prepared, bytes32 commitment)
        private
        view
        returns (bytes memory)
    {
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
        prepared.authorization;
        if (executionManager.paused()) {
            return abi.encodeWithSelector(Pausable.EnforcedPause.selector);
        }
        if (block.timestamp >= authorization.deadline) {
            return abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.AuthorizationExpired.selector,
                authorization.deadline,
                block.timestamp
            );
        }
        if (authorization.riskPolicyVersion != executionManager.riskPolicyVersion()) {
            return abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.StaleRiskPolicy.selector,
                authorization.riskPolicyVersion,
                executionManager.riskPolicyVersion()
            );
        }
        (bytes32 root,, uint64 version) = executionManager.activePolicies(executor);
        if (
            root == bytes32(0) || root != authorization.policyRoot
                || version != authorization.policyVersion
        ) {
            return abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.StalePolicy.selector,
                executor,
                authorization.policyRoot,
                root,
                authorization.policyVersion,
                version
            );
        }
        if (executionManager.consumedExecutionCommitments(commitment)) {
            return abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.ExecutionCommitmentAlreadyConsumed.selector,
                commitment
            );
        }
        if (capitalManager.paused()) {
            return abi.encodeWithSelector(Pausable.EnforcedPause.selector);
        }
        AlphaEngineCapitalStrategyManager.CapitalIntentState memory intent =
            capitalManager.getCapitalIntentState(authorization.intentId);
        if (intent.status != AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Approved) {
            return abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.InvalidCapitalIntentStatus.selector,
                authorization.intentId,
                intent.status
            );
        }
        if (!registry.isQualifiedAtVersion(trader, authorization.qualificationVersion)) {
            return abi.encodeWithSelector(
                AlphaEngineCapitalStrategyManager.QualificationVersionNotActive.selector,
                trader,
                authorization.qualificationVersion
            );
        }
        if (fundVault.paused()) return abi.encodeWithSelector(Pausable.EnforcedPause.selector);
        MockERC20 input = prepared.exiting ? assetOut : assetIn;
        MockERC20 output = prepared.exiting ? assetIn : assetOut;
        uint256 have = input.balanceOf(address(fundVault));
        if (have < prepared.input) {
            return _balanceFailure(address(fundVault), have, prepared.input);
        }
        have = output.balanceOf(address(strategyTarget));
        if (have < prepared.output) {
            return _balanceFailure(address(strategyTarget), have, prepared.output);
        }
        (, uint256 maximum) = executionManager.traderAssetRiskLimits(trader, address(input));
        uint256 spent = executionManager.currentWindowSpend(trader, address(input)) + prepared.input;
        if (spent > maximum) {
            return abi.encodeWithSelector(
                AlphaEngineVaultExecutionManager.SpendWindowLimitExceeded.selector,
                trader,
                address(input),
                spent,
                maximum
            );
        }
        return "";
    }

    function _balanceFailure(address account, uint256 available, uint256 required)
        private
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            AlphaEngineFundVault.BatchCallFailed.selector,
            uint256(1),
            address(strategyTarget),
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, account, available, required
            )
        );
    }

    function _deployCompetitionManager() private {
        AlphaEngineCompetitionStrategyManager implementation =
            new AlphaEngineCompetitionStrategyManager();
        competitionManager = AlphaEngineCompetitionStrategyManager(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    admin,
                    abi.encodeCall(
                        AlphaEngineCompetitionStrategyManager.initialize,
                        (AlphaEngineCompetitionStrategyManager.InitializationParams(
                                admin, pauser, fheOperator, address(registry)
                            ))
                    )
                )
            )
        );
        vm.startPrank(admin);
        registry.grantRole(registry.QUALIFICATION_ISSUER_ROLE(), address(competitionManager));
        competitionManager.grantRole(competitionManager.COMPETITION_CREATOR_ROLE(), address(this));
        competitionManager.grantRole(competitionManager.EVALUATOR_ROLE(), address(this));
        competitionManager.grantRole(competitionManager.FINALIZER_ROLE(), address(this));
        competitionManager.grantRole(competitionManager.QUALIFIER_ROLE(), address(this));
        competitionManager.unpause();
        vm.stopPrank();
    }
}

contract AlphaEngineCapitalVaultLifecycleInvariantTest is StdInvariant, MockCoFheTest {
    CapitalVaultLifecycleHandler private handler;

    function setUp() public {
        handler = new CapitalVaultLifecycleHandler();
        // Concrete witnesses establish real invested capital, a pending LP exit, profit then immediate loss,
        // partial unwinds, fee minting, terminal redemption, and independently rejected executions.
        handler.deposit(1, 200e6);
        for (uint256 i; i < 3; ++i) {
            handler.prepareEntry(100);
            handler.executePrepared(i);
        }
        handler.request(0, 0);
        handler.completeRequest(0);
        handler.markPosition(1_200_000);
        handler.markPosition(1_100_000);
        handler.advanceTime(1 days);
        handler.prepareExit(100);
        handler.executePrepared(3);
        handler.prepareExit(20);
        handler.executePrepared(4);
        handler.completeRequest(0);
        handler.request(1, 10e18 + 2);
        handler.invalidateQualification(1, false);
        handler.competitionToCapital(7, 11);
        handler.governanceCycle(1, 2);

        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.request.selector;
        selectors[2] = handler.cancelRequest.selector;
        selectors[3] = handler.completeRequest.selector;
        selectors[4] = handler.prepareEntry.selector;
        selectors[5] = handler.prepareExit.selector;
        selectors[6] = handler.executePrepared.selector;
        selectors[7] = handler.markPosition.selector;
        selectors[8] = handler.reportBook.selector;
        selectors[9] = handler.advanceTime.selector;
        selectors[10] = handler.marketLiquidity.selector;
        selectors[11] = handler.invalidateQualification.selector;
        selectors[12] = handler.invalidatePolicyOrRisk.selector;
        selectors[13] = handler.governanceCycle.selector;
        selectors[14] = handler.competitionToCapital.selector;
        selectors[15] = handler.stressUnwind.selector;
        selectors[16] = handler.recoveryCheckpoint.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_XS_independentPositionBookInvestorClaimsAndReplayDomains() public view {
        handler.property_independentFundBookAndClaims();
    }

    function invariant_XS_fundedLifecycleWitnessesAreNonVacuous() public view {
        assertGt(handler.successfulEntries(), 0);
        assertGt(handler.successfulExits(), 0);
        assertGt(handler.successfulProfitReports(), 0);
        assertGt(handler.successfulLossReports(), 0);
        assertGt(handler.completedRequests(), 0);
        assertGt(handler.rejectedExecutions(), 0);
        assertGt(handler.rejectedCompletions(), 0);
        assertGt(handler.competitionChains(), 0);
        assertGt(handler.governanceChecks(), 0);
    }

    function invariant_XS_assetDenominatedRoundingAndEarnedFees() public {
        uint256 snapshot = vm.snapshotState();
        handler.drain();
        bool roundingViolation = handler.incomingRoundingLossViolation();
        bool feeViolation = handler.feeEntitlementViolation();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        assertFalse(roundingViolation);
        assertFalse(feeViolation);
    }

    function afterInvariant() public {
        handler.drain();
        handler.property_independentFundBookAndClaims();
    }

    function test_XS_drainReplaysSpendWindowCounterexample() public {
        handler.deposit(17_505, type(uint96).max);
        handler.governanceCycle(5187, 19);
        handler.governanceCycle(11_934, 77);
        handler.governanceCycle(64_000_000, 60);
        handler.invalidatePolicyOrRisk(6884, false);
        handler.invalidatePolicyOrRisk(1_189_315_241, true);
        uint256 started = vm.getBlockTimestamp();
        handler.drain();
        assertGt(vm.getBlockTimestamp(), started);
        assertEq(handler.ghostPositionTokens(), 0);
        handler.property_independentFundBookAndClaims();
        assertFalse(handler.incomingRoundingLossViolation());
        assertFalse(handler.feeEntitlementViolation());
    }

    function testFuzz_XS01_competitionReplacementToRealCapitalExecution(
        uint128 market,
        uint128 component
    ) public {
        uint256 chains = handler.competitionChains();
        handler.competitionToCapital(market, component);
        assertEq(handler.competitionChains(), chains + 1);
        handler.property_independentFundBookAndClaims();
    }

    function testFuzz_QC12_realExecutionRollbackOnRevocationAndNaturalExpiry(uint16 seed) public {
        uint256 rejected = handler.rejectedExecutions();
        handler.invalidateQualification(seed, false);
        handler.invalidateQualification(seed, true);
        assertGe(handler.rejectedExecutions(), rejected + 4);
        handler.property_independentFundBookAndClaims();
    }

    function testFuzz_XS02_XS03_XS05_positionPnlPolicyChangesAndAuthorizedDrain(
        uint96 mark,
        uint16 seed
    ) public {
        handler.markPosition(mark);
        handler.invalidatePolicyOrRisk(seed, false);
        handler.invalidatePolicyOrRisk(seed, true);
        for (uint8 mode; mode < 4; ++mode) {
            handler.governanceCycle(seed, mode);
        }
        handler.stressUnwind(seed);
        handler.drain();
        handler.property_independentFundBookAndClaims();
        invariant_XS_assetDenominatedRoundingAndEarnedFees();
    }

    function test_XS06_EX14_FV29_fixedRecoveryRetainsSourceClaimsAndEventParity() public {
        handler.recoveryCheckpoint();
        assertEq(handler.recoveryChecks(), 1);
        handler.property_independentFundBookAndClaims();
    }
}
