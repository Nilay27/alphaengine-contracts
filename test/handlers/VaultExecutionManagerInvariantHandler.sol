// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";
import {IAlphaEngineDecoderAndSanitizer} from "src/interfaces/IAlphaEngineDecoderAndSanitizer.sol";
import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {
    AlphaEnginePendleV4PtDecoderAndSanitizer
} from "src/decoders/AlphaEnginePendleV4PtDecoderAndSanitizer.sol";
import {IAlphaEnginePendleRouterV4} from "src/interfaces/IAlphaEnginePendleRouterV4.sol";
import {
    AlphaEngineERC4626DecoderAndSanitizer
} from "src/decoders/AlphaEngineERC4626DecoderAndSanitizer.sol";
import {AlphaEngineRollingSpendLib} from "src/libraries/AlphaEngineRollingSpendLib.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {
    AlphaEngineERC20DecoderAndSanitizer
} from "src/decoders/AlphaEngineERC20DecoderAndSanitizer.sol";
import {
    IAlphaEngineVaultExecutionManager
} from "src/interfaces/IAlphaEngineVaultExecutionManager.sol";
import {AlphaEngineExecutionHashLib} from "src/libraries/AlphaEngineExecutionHashLib.sol";
import {AlphaEngineManageLeafHashLib} from "src/libraries/AlphaEngineManageLeafHashLib.sol";
import {AlphaEngineVaultExecutionManager} from "src/vault/AlphaEngineVaultExecutionManager.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {
    MockCapitalStrategyManagerStage16,
    MockStrategyActionDecoder,
    MockVaultStrategyTarget
} from "test/mocks/MockVaultExecutionStage16.sol";

contract VaultExecutionManagerInvariantHandler {
    uint256 public constant MAX_PER_EXECUTION = 1000e6;
    uint256 public constant MAX_PER_24_HOURS = 1_000_000_000e6;
    uint256 public constant POSITION_SCALE = 1e12;
    uint256 public constant MAX_POSITION_PER_EXECUTION = MAX_PER_EXECUTION * POSITION_SCALE;
    uint256 public constant MAX_POSITION_PER_24_HOURS = MAX_PER_24_HOURS * POSITION_SCALE;

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct GhostSpendRecord {
        uint256 amount;
        uint40 timestamp;
    }

    AlphaEngineVaultExecutionManager public immutable MANAGER;
    MockCapitalStrategyManagerStage16 public immutable CAPITAL_MANAGER;
    address public immutable FUND_VAULT;
    MockERC20 public immutable ASSET_IN;
    MockERC20 public immutable ASSET_OUT;
    AlphaEngineERC20DecoderAndSanitizer public immutable ERC20_DECODER;
    MockStrategyActionDecoder public immutable STRATEGY_DECODER;
    MockVaultStrategyTarget public immutable STRATEGY_TARGET;
    address public immutable TRADER;
    bytes32 public immutable POLICY_ROOT;
    uint64 public immutable POLICY_VERSION;
    bytes32 public immutable INPUT_APPROVAL_LEAF;
    bytes32 public immutable POSITION_APPROVAL_LEAF;
    bytes32 public immutable ENTRY_LEAF;
    bytes32 public immutable EXIT_LEAF;

    bytes32[4] private _sortedLeaves;
    GhostSpendRecord[] private _inputSpendRecords;
    GhostSpendRecord[] private _positionSpendRecords;
    uint256 private _inputSpendHead;
    uint256 private _positionSpendHead;

    uint64 public nextNonce;
    uint256 public ghostSpent;
    uint256 public ghostReceived;
    uint256 public ghostExitPositionSpent;
    uint256 public ghostExitInputReceived;
    uint256 public ghostInputWindowSpend;
    uint256 public ghostPositionWindowSpend;
    uint256 public successfulExecutions;
    uint256 public successfulEntries;
    uint256 public successfulExits;
    uint256 public holdingTransitions;
    uint256 public expectedFailures;
    uint256 public lastSuccessfulAmount;
    uint64 public lastSuccessfulNonce;
    bytes32 public lastSuccessfulIntent;
    uint40 public lastSuccessfulValidAfter;
    uint40 public lastSuccessfulDeadline;

    bool public successfulExecutionViolation;
    bool public expectedFailureViolation;
    bool public replayViolation;
    address public immutable GOVERNANCE;
    address public constant SECOND_TRADER = address(0x7B);
    bytes32 private constant ARTIFACT_HASH = keccak256("invariant policy artifact");
    ExecutionInvariantRelay public immutable SECOND_EXECUTOR;
    GhostSpendRecord[] private _secondInputRecords;
    uint256 private _secondInputHead;
    uint256 public ghostSecondInputWindowSpend;
    uint256 public ghostCallbackReceipts;
    uint256[19] public scenarioRuns;
    bool public exploratoryUntrackedShareBurn;
    AlphaEngineExecutionHashLib.ExecutionCommitmentV1 private _lastSuccessfulAuthorization;

    constructor(
        AlphaEngineVaultExecutionManager manager,
        MockCapitalStrategyManagerStage16 capitalManager,
        address fundVault,
        MockERC20 assetIn,
        MockERC20 assetOut,
        AlphaEngineERC20DecoderAndSanitizer erc20Decoder,
        MockStrategyActionDecoder strategyDecoder,
        MockVaultStrategyTarget strategyTarget,
        address trader,
        bytes32 policyRoot,
        uint64 policyVersion,
        bytes32 inputApprovalLeaf,
        bytes32 positionApprovalLeaf,
        bytes32 entryLeaf,
        bytes32 exitLeaf
    ) {
        MANAGER = manager;
        GOVERNANCE = manager.defaultAdmin();
        SECOND_EXECUTOR = new ExecutionInvariantRelay(manager);
        CAPITAL_MANAGER = capitalManager;
        FUND_VAULT = fundVault;
        ASSET_IN = assetIn;
        ASSET_OUT = assetOut;
        ERC20_DECODER = erc20Decoder;
        STRATEGY_DECODER = strategyDecoder;
        STRATEGY_TARGET = strategyTarget;
        TRADER = trader;
        POLICY_ROOT = policyRoot;
        POLICY_VERSION = policyVersion;
        INPUT_APPROVAL_LEAF = inputApprovalLeaf;
        POSITION_APPROVAL_LEAF = positionApprovalLeaf;
        ENTRY_LEAF = entryLeaf;
        EXIT_LEAF = exitLeaf;

        bytes32[4] memory leaves = [inputApprovalLeaf, positionApprovalLeaf, entryLeaf, exitLeaf];
        for (uint256 i; i < leaves.length; ++i) {
            for (uint256 j = i + 1; j < leaves.length; ++j) {
                if (uint256(leaves[j]) < uint256(leaves[i])) {
                    (leaves[i], leaves[j]) = (leaves[j], leaves[i]);
                }
            }
            _sortedLeaves[i] = leaves[i];
        }
    }

    function executeValid(uint96 rawAmount) public {
        uint256 available = ASSET_IN.balanceOf(FUND_VAULT);
        if (available == 0) return;
        uint256 maximum = available < MAX_PER_EXECUTION ? available : MAX_PER_EXECUTION;
        uint256 amountIn = (uint256(rawAmount) % maximum) + 1;
        uint256 amountOut = amountIn * 1e12;
        uint64 nonce = _takeNonce();
        bytes32 intentId = keccak256(abi.encode("valid", nonce));
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _authorization(intentId, nonce, amountIn, amountOut, amountIn, amountOut);
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);

        uint256 inputBefore = ASSET_IN.balanceOf(FUND_VAULT);
        uint256 outputBefore = ASSET_OUT.balanceOf(FUND_VAULT);
        MANAGER.executeCapitalIntent(authorization, calls, limits, proofs);
        if (
            ASSET_IN.balanceOf(FUND_VAULT) != inputBefore - amountIn
                || ASSET_OUT.balanceOf(FUND_VAULT) != outputBefore + amountOut
                || ASSET_IN.allowance(FUND_VAULT, address(STRATEGY_TARGET)) != 0
                || !MANAGER.consumedExecutionCommitments(commitment)
                || !CAPITAL_MANAGER.isExecutionConsumed(commitment)
        ) {
            successfulExecutionViolation = true;
        }

        _recordGhostSpend(true, amountIn);
        ghostSpent += amountIn;
        ghostReceived += amountOut;
        successfulExecutions += 1;
        successfulEntries += 1;
        lastSuccessfulAmount = amountIn;
        lastSuccessfulNonce = nonce;
        lastSuccessfulIntent = intentId;
        lastSuccessfulValidAfter = authorization.validAfter;
        lastSuccessfulDeadline = authorization.deadline;
        _lastSuccessfulAuthorization = authorization;
        ++scenarioRuns[1];
    }

    function executeExit(uint96 rawAmount) public {
        uint256 availablePosition = ASSET_OUT.balanceOf(FUND_VAULT) / POSITION_SCALE;
        uint256 availableInputLiquidity = ASSET_IN.balanceOf(address(STRATEGY_TARGET));
        uint256 maximum = availablePosition < availableInputLiquidity
            ? availablePosition
            : availableInputLiquidity;
        if (maximum > MAX_PER_EXECUTION) maximum = MAX_PER_EXECUTION;
        if (maximum == 0) return;

        uint256 inputAmountOut = (uint256(rawAmount) % maximum) + 1;
        uint256 positionAmountIn = inputAmountOut * POSITION_SCALE;
        uint64 nonce = _takeNonce();
        bytes32 intentId = keccak256(abi.encode("exit", nonce));
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _exitAuthorization(
            intentId, nonce, positionAmountIn, inputAmountOut, positionAmountIn, inputAmountOut
        );
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);

        uint256 inputBefore = ASSET_IN.balanceOf(FUND_VAULT);
        uint256 positionBefore = ASSET_OUT.balanceOf(FUND_VAULT);
        MANAGER.executeCapitalIntent(authorization, calls, limits, proofs);
        if (
            ASSET_IN.balanceOf(FUND_VAULT) != inputBefore + inputAmountOut
                || ASSET_OUT.balanceOf(FUND_VAULT) != positionBefore - positionAmountIn
                || ASSET_OUT.allowance(FUND_VAULT, address(STRATEGY_TARGET)) != 0
                || !MANAGER.consumedExecutionCommitments(commitment)
                || !CAPITAL_MANAGER.isExecutionConsumed(commitment)
        ) {
            successfulExecutionViolation = true;
        }

        _recordGhostSpend(false, positionAmountIn);
        ghostExitPositionSpent += positionAmountIn;
        ghostExitInputReceived += inputAmountOut;
        successfulExecutions += 1;
        successfulExits += 1;
        ++scenarioRuns[1];
    }

    function advanceHoldingTime(uint32 rawSeconds) external {
        uint256 elapsed = uint256(rawSeconds) % (48 hours + 1);
        VM.warp(VM.getBlockTimestamp() + elapsed);
        _pruneGhostWindows();
        holdingTransitions += 1;
    }

    function attemptReplay() external {
        if (successfulExecutions == 0) return;
        uint256 amountIn = lastSuccessfulAmount;
        uint256 amountOut = amountIn * 1e12;
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _authorization(
            lastSuccessfulIntent, lastSuccessfulNonce, amountIn, amountOut, amountIn, amountOut
        );
        authorization = _lastSuccessfulAuthorization;
        bytes32 commitment = AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);
        uint256 inputBefore = ASSET_IN.balanceOf(FUND_VAULT);
        uint256 outputBefore = ASSET_OUT.balanceOf(FUND_VAULT);

        (bool success, bytes memory revertData) = address(MANAGER)
            .call(
                abi.encodeCall(
                    IAlphaEngineVaultExecutionManager.executeCapitalIntent,
                    (authorization, calls, limits, proofs)
                )
            );
        (,, uint64 activeVersion) = MANAGER.activePolicies(address(this));
        bytes4 expectedSelector =
            AlphaEngineVaultExecutionManager.ExecutionCommitmentAlreadyConsumed.selector;
        if (authorization.policyVersion != activeVersion) {
            expectedSelector = AlphaEngineVaultExecutionManager.StalePolicy.selector;
        }
        if (authorization.riskPolicyVersion != MANAGER.riskPolicyVersion()) {
            expectedSelector = AlphaEngineVaultExecutionManager.StaleRiskPolicy.selector;
        }
        if (VM.getBlockTimestamp() >= lastSuccessfulDeadline) {
            expectedSelector = AlphaEngineVaultExecutionManager.AuthorizationExpired.selector;
        }
        if (
            success || _selector(revertData) != expectedSelector
                || ASSET_IN.balanceOf(FUND_VAULT) != inputBefore
                || ASSET_OUT.balanceOf(FUND_VAULT) != outputBefore
                || !MANAGER.consumedExecutionCommitments(commitment)
        ) {
            replayViolation = true;
        }
        expectedFailures += 1;
        ++scenarioRuns[11];
    }

    function attemptSlippage(uint96 rawAmount) external {
        uint256 available = ASSET_IN.balanceOf(FUND_VAULT);
        if (available == 0) return;
        uint256 maximum = available < MAX_PER_EXECUTION ? available : MAX_PER_EXECUTION;
        uint256 amountIn = (uint256(rawAmount) % maximum) + 1;
        uint256 amountOut = amountIn * 1e12;
        uint64 nonce = _takeNonce();
        bytes32 intentId = keccak256(abi.encode("slippage", nonce));
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _authorization(intentId, nonce, amountIn, amountOut, amountIn, amountOut + 1);
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        _expectFailure(
            authorization,
            calls,
            limits,
            proofs,
            commitment,
            AlphaEngineVaultExecutionManager.MinimumAssetReceiptNotMet.selector
        );
    }

    function attemptInvalidProof(uint96 rawAmount) external {
        uint256 available = ASSET_IN.balanceOf(FUND_VAULT);
        if (available == 0) return;
        uint256 maximum = available < MAX_PER_EXECUTION ? available : MAX_PER_EXECUTION;
        uint256 amountIn = (uint256(rawAmount) % maximum) + 1;
        uint256 amountOut = amountIn * 1e12;
        uint64 nonce = _takeNonce();
        bytes32 intentId = keccak256(abi.encode("bad-proof", nonce));
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _authorization(intentId, nonce, amountIn, amountOut, amountIn, amountOut);
        proofs[1][0] = bytes32(uint256(proofs[1][0]) ^ 1);
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        _expectFailure(
            authorization,
            calls,
            limits,
            proofs,
            commitment,
            AlphaEngineVaultExecutionManager.InvalidManageProof.selector
        );
    }

    function attemptOverConfiguredCap(uint96 rawAmount) external {
        uint256 available = ASSET_IN.balanceOf(FUND_VAULT);
        if (available == 0) return;
        uint256 amountIn = (uint256(rawAmount) % MAX_PER_EXECUTION) + 1;
        uint256 amountOut = amountIn * 1e12;
        uint64 nonce = _takeNonce();
        bytes32 intentId = keccak256(abi.encode("over-cap", nonce));
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _authorization(intentId, nonce, amountIn, amountOut, MAX_PER_EXECUTION + 1, amountOut);
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        _expectFailure(
            authorization,
            calls,
            limits,
            proofs,
            commitment,
            AlphaEngineVaultExecutionManager.PerExecutionRiskLimitExceeded.selector
        );
    }

    function _expectFailure(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
        AlphaEngineExecutionHashLib.CallV1[] memory calls,
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
        bytes32[][] memory proofs,
        bytes32 commitment,
        bytes4 expectedSelector
    ) private {
        uint256 inputBefore = ASSET_IN.balanceOf(FUND_VAULT);
        uint256 outputBefore = ASSET_OUT.balanceOf(FUND_VAULT);
        uint256 spendBefore = MANAGER.currentWindowSpend(authorization.trader, address(ASSET_IN));
        uint256 positionSpendBefore =
            MANAGER.currentWindowSpend(authorization.trader, address(ASSET_OUT));
        bool nonceBefore = MANAGER.consumedAuthorizationNonces(authorization.authorizationNonce);
        uint256 targetInputBefore = ASSET_IN.balanceOf(address(STRATEGY_TARGET));
        uint256 targetOutputBefore = ASSET_OUT.balanceOf(address(STRATEGY_TARGET));
        (bool success, bytes memory revertData) = address(MANAGER)
            .call(
                abi.encodeCall(
                    IAlphaEngineVaultExecutionManager.executeCapitalIntent,
                    (authorization, calls, limits, proofs)
                )
            );
        if (
            success || _selector(revertData) != expectedSelector
                || ASSET_IN.balanceOf(FUND_VAULT) != inputBefore
                || ASSET_OUT.balanceOf(FUND_VAULT) != outputBefore
                || ASSET_IN.allowance(FUND_VAULT, address(STRATEGY_TARGET)) != 0
                || MANAGER.currentWindowSpend(authorization.trader, address(ASSET_IN))
                    != spendBefore
                || MANAGER.currentWindowSpend(authorization.trader, address(ASSET_OUT))
                    != positionSpendBefore
                || ASSET_OUT.allowance(FUND_VAULT, address(STRATEGY_TARGET)) != 0
                || ASSET_IN.balanceOf(address(STRATEGY_TARGET)) != targetInputBefore
                || ASSET_OUT.balanceOf(address(STRATEGY_TARGET)) != targetOutputBefore
                || MANAGER.consumedAuthorizationNonces(authorization.authorizationNonce)
                    != nonceBefore || MANAGER.consumedExecutionCommitments(commitment)
                || CAPITAL_MANAGER.isExecutionConsumed(commitment)
        ) {
            expectedFailureViolation = true;
        }
        expectedFailures += 1;
        ++scenarioRuns[10];
    }

    function _authorization(
        bytes32 intentId,
        uint64 nonce,
        uint256 amountIn,
        uint256 amountOut,
        uint256 maxSpend,
        uint256 minReceive
    )
        private
        view
        returns (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        )
    {
        return _authorizationFor(
            intentId,
            nonce,
            address(ASSET_IN),
            address(ASSET_OUT),
            amountIn,
            amountOut,
            maxSpend,
            minReceive,
            INPUT_APPROVAL_LEAF,
            ENTRY_LEAF
        );
    }

    function _exitAuthorization(
        bytes32 intentId,
        uint64 nonce,
        uint256 amountIn,
        uint256 amountOut,
        uint256 maxSpend,
        uint256 minReceive
    )
        private
        view
        returns (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        )
    {
        return _authorizationFor(
            intentId,
            nonce,
            address(ASSET_OUT),
            address(ASSET_IN),
            amountIn,
            amountOut,
            maxSpend,
            minReceive,
            POSITION_APPROVAL_LEAF,
            EXIT_LEAF
        );
    }

    function _authorizationFor(
        bytes32 intentId,
        uint64 nonce,
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 maxSpend,
        uint256 minReceive,
        bytes32 approvalLeaf,
        bytes32 strategyLeaf
    )
        private
        view
        returns (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        )
    {
        calls = _calls(assetIn, assetOut, amountIn, amountOut);
        limits = _limits(assetIn, assetOut, maxSpend, minReceive);
        proofs = _proofs(approvalLeaf, strategyLeaf);
        authorization = AlphaEngineExecutionHashLib.ExecutionCommitmentV1({
            chainId: block.chainid,
            capitalStrategyManager: address(CAPITAL_MANAGER),
            vaultExecutionManager: address(MANAGER),
            fundVault: FUND_VAULT,
            intentId: intentId,
            trader: TRADER,
            qualificationVersion: 1,
            executor: address(this),
            authorizationNonce: nonce,
            validAfter: uint40(VM.getBlockTimestamp()),
            deadline: uint40(VM.getBlockTimestamp() + 1 hours),
            policyRoot: POLICY_ROOT,
            policyVersion: _activeVersion(address(this)),
            callsHash: AlphaEngineExecutionHashLib.hashCalls(calls),
            riskEnvelopeHash: AlphaEngineExecutionHashLib.hashRiskEnvelope(limits),
            riskPolicyVersion: MANAGER.riskPolicyVersion(),
            submissionPayloadHash: keccak256(abi.encode(intentId, "submission")),
            evaluationEvidenceHash: keccak256(abi.encode(intentId, "evaluation"))
        });
    }

    function _calls(address assetIn, address assetOut, uint256 amountIn, uint256 amountOut)
        private
        view
        returns (AlphaEngineExecutionHashLib.CallV1[] memory calls)
    {
        calls = new AlphaEngineExecutionHashLib.CallV1[](3);
        calls[0] = AlphaEngineExecutionHashLib.CallV1({
            decoder: address(ERC20_DECODER),
            target: assetIn,
            value: 0,
            targetData: abi.encodeCall(IERC20.approve, (address(STRATEGY_TARGET), amountIn))
        });
        calls[1] = AlphaEngineExecutionHashLib.CallV1({
            decoder: address(STRATEGY_DECODER),
            target: address(STRATEGY_TARGET),
            value: 0,
            targetData: abi.encodeCall(
                MockVaultStrategyTarget.swapExact, (assetIn, assetOut, amountIn, amountOut)
            )
        });
        calls[2] = AlphaEngineExecutionHashLib.CallV1({
            decoder: address(ERC20_DECODER),
            target: assetIn,
            value: 0,
            targetData: abi.encodeCall(IERC20.approve, (address(STRATEGY_TARGET), 0))
        });
    }

    function _limits(address assetIn, address assetOut, uint256 maxSpend, uint256 minReceive)
        private
        pure
        returns (AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits)
    {
        limits = new AlphaEngineExecutionHashLib.AssetDeltaLimitV1[](2);
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1 memory inputLimit =
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1({
                asset: assetIn, maxSpend: maxSpend, minReceive: 0
            });
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1 memory outputLimit =
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1({
                asset: assetOut, maxSpend: 0, minReceive: minReceive
            });
        if (assetIn < assetOut) {
            limits[0] = inputLimit;
            limits[1] = outputLimit;
        } else {
            limits[0] = outputLimit;
            limits[1] = inputLimit;
        }
    }

    function _proofs(bytes32 approvalLeaf, bytes32 strategyLeaf)
        private
        view
        returns (bytes32[][] memory proofs)
    {
        proofs = new bytes32[][](3);
        proofs[0] = _proofFor(approvalLeaf);
        proofs[1] = _proofFor(strategyLeaf);
        proofs[2] = _proofFor(approvalLeaf);
    }

    function _proofFor(bytes32 leaf) private view returns (bytes32[] memory proof) {
        uint256 index = type(uint256).max;
        for (uint256 i; i < _sortedLeaves.length; ++i) {
            if (_sortedLeaves[i] == leaf) {
                index = i;
                break;
            }
        }
        if (index == type(uint256).max) revert();

        proof = new bytes32[](2);
        proof[0] = index % 2 == 0 ? _sortedLeaves[index + 1] : _sortedLeaves[index - 1];
        proof[1] = index < 2
            ? AlphaEngineManageLeafHashLib.hashPair(_sortedLeaves[2], _sortedLeaves[3])
            : AlphaEngineManageLeafHashLib.hashPair(_sortedLeaves[0], _sortedLeaves[1]);
    }

    function _recordGhostSpend(bool inputAsset, uint256 amount) private {
        _pruneGhostWindows();
        GhostSpendRecord[] storage records = inputAsset ? _inputSpendRecords : _positionSpendRecords;
        uint256 length = records.length;
        if (length != 0 && records[length - 1].timestamp == VM.getBlockTimestamp()) {
            records[length - 1].amount += amount;
        } else {
            records.push(
                GhostSpendRecord({amount: amount, timestamp: uint40(VM.getBlockTimestamp())})
            );
        }
        if (inputAsset) ghostInputWindowSpend += amount;
        else ghostPositionWindowSpend += amount;
    }

    function _pruneGhostWindows() private {
        (_inputSpendHead, ghostInputWindowSpend) =
            _pruneGhostWindow(_inputSpendRecords, _inputSpendHead, ghostInputWindowSpend);
        (_positionSpendHead, ghostPositionWindowSpend) =
            _pruneGhostWindow(_positionSpendRecords, _positionSpendHead, ghostPositionWindowSpend);
        (_secondInputHead, ghostSecondInputWindowSpend) =
            _pruneGhostWindow(_secondInputRecords, _secondInputHead, ghostSecondInputWindowSpend);
    }

    function _pruneGhostWindow(GhostSpendRecord[] storage records, uint256 head, uint256 total)
        private
        view
        returns (uint256 newHead, uint256 newTotal)
    {
        newHead = head;
        newTotal = total;
        while (
            newHead < records.length
                && uint256(records[newHead].timestamp) + 24 hours <= VM.getBlockTimestamp()
        ) {
            newTotal -= records[newHead].amount;
            ++newHead;
        }
    }

    /// @notice EX-03/EX-11: a second executor/trader has independent root and spend domains.
    function executeSecondTrader(uint96 rawAmount) external {
        uint256 maximum = ASSET_IN.balanceOf(FUND_VAULT);
        if (maximum == 0) return;
        if (maximum > MAX_PER_EXECUTION) maximum = MAX_PER_EXECUTION;
        uint256 amount = uint256(rawAmount) % maximum + 1;
        uint64 nonce = _takeNonce();
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _authorization(
            keccak256(abi.encode("second", nonce)),
            nonce,
            amount,
            amount * POSITION_SCALE,
            amount,
            amount * POSITION_SCALE
        );
        authorization.trader = SECOND_TRADER;
        authorization.executor = address(SECOND_EXECUTOR);
        authorization.policyVersion = _activeVersion(address(SECOND_EXECUTOR));
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        uint256 firstSpend = MANAGER.currentWindowSpend(TRADER, address(ASSET_IN));
        _expectFailure(
            authorization,
            calls,
            limits,
            proofs,
            commitment,
            AlphaEngineVaultExecutionManager.UnauthorizedExecutor.selector
        );
        SECOND_EXECUTOR.execute(authorization, calls, limits, proofs);
        assert(MANAGER.currentWindowSpend(TRADER, address(ASSET_IN)) == firstSpend);
        assert(MANAGER.consumedExecutionCommitments(commitment));
        assert(CAPITAL_MANAGER.isExecutionConsumed(commitment));
        _pruneGhostWindows();
        uint256 length = _secondInputRecords.length;
        if (length != 0 && _secondInputRecords[length - 1].timestamp == VM.getBlockTimestamp()) {
            _secondInputRecords[length - 1].amount += amount;
        } else {
            _secondInputRecords.push(GhostSpendRecord(amount, uint40(VM.getBlockTimestamp())));
        }
        ghostSecondInputWindowSpend += amount;
        ghostSpent += amount;
        ghostReceived += amount * POSITION_SCALE;
        ++scenarioRuns[3];
    }

    /// @notice EX-04: equal repeated spends at 24h-1, 24h, 24h+1 are independently valued.
    function exerciseRollingBoundary(uint32 rawAmount) external {
        // Cheatcode time jumps require fresh reads; block.timestamp is transaction-constant to solc.
        VM.warp(VM.getBlockTimestamp() + 24 hours);
        _pruneGhostWindows();
        uint256 start = VM.getBlockTimestamp();
        uint96 seed = uint96(uint256(rawAmount) % 1e6);
        executeValid(seed);
        executeValid(seed);
        uint256 firstAmount = lastSuccessfulAmount;
        VM.warp(start + 24 hours - 1);
        _pruneGhostWindows();
        assert(MANAGER.currentWindowSpend(TRADER, address(ASSET_IN)) == 2 * firstAmount);
        executeValid(seed);
        VM.warp(start + 24 hours);
        _pruneGhostWindows();
        assert(ghostInputWindowSpend == firstAmount);
        assert(MANAGER.currentWindowSpend(TRADER, address(ASSET_IN)) == firstAmount);
        executeValid(seed);
        VM.warp(start + 24 hours + 1);
        _pruneGhostWindows();
        assert(ghostInputWindowSpend == 2 * firstAmount);
        assert(MANAGER.currentWindowSpend(TRADER, address(ASSET_IN)) == ghostInputWindowSpend);
        ++scenarioRuns[4];
    }

    /// @notice EX-05: the 65th distinct record fails atomically and pruning permits a fresh retry.
    function exerciseSpendCapacity(uint16 rawAmount) external {
        VM.warp(VM.getBlockTimestamp() + 24 hours);
        _pruneGhostWindows();
        uint256 start = VM.getBlockTimestamp();
        uint96 seed = uint96(rawAmount);
        for (uint256 i; i < 64; ++i) {
            executeValid(seed);
            VM.warp(VM.getBlockTimestamp() + 1);
            _pruneGhostWindows();
        }
        uint256 amount = uint256(seed) + 1;
        uint64 nonce = _takeNonce();
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _authorization(
            keccak256(abi.encode("capacity", nonce)),
            nonce,
            amount,
            amount * POSITION_SCALE,
            amount,
            amount * POSITION_SCALE
        );
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        _expectFailure(
            authorization,
            calls,
            limits,
            proofs,
            commitment,
            AlphaEngineRollingSpendLib.SpendRecordCapacityReached.selector
        );
        VM.warp(start + 24 hours);
        _pruneGhostWindows();
        assert(ghostInputWindowSpend == 63 * amount);
        executeValid(seed);
        assert(ghostInputWindowSpend == 64 * amount);
        VM.warp(VM.getBlockTimestamp() + 24 hours);
        _pruneGhostWindows();
        ++scenarioRuns[5];
    }

    /// @notice EX-06: proposal cancellation, exact activation edge, stale approval and revocation.
    function exerciseRootGovernance(uint32 rawAmount) external {
        executeValid(uint96(rawAmount));
        bytes32 nextRoot = keccak256(abi.encode("rotated root", nextNonce, rawAmount));
        uint40 activateAfter = uint40(VM.getBlockTimestamp() + 48 hours);
        uint64 versionBefore = _activeVersion(address(this));
        MANAGER.proposePolicyRoot(address(this), nextRoot, ARTIFACT_HASH, activateAfter);
        MANAGER.cancelPolicyRootProposal(address(this));
        (bytes32 pending,,) = MANAGER.pendingPolicies(address(this));
        assert(pending == bytes32(0) && _activeVersion(address(this)) == versionBefore);
        MANAGER.proposePolicyRoot(address(this), nextRoot, ARTIFACT_HASH, activateAfter);
        _expectControlFailure(
            abi.encodeCall(MANAGER.activatePolicyRoot, (address(this))),
            AlphaEngineVaultExecutionManager.RootActivationNotReady.selector
        );
        VM.warp(activateAfter);
        _pruneGhostWindows();
        MANAGER.activatePolicyRoot(address(this));
        assert(_activeVersion(address(this)) == versionBefore + 1);
        _attemptStaleRoot();
        MANAGER.revokePolicyRoot(address(this));
        assert(MANAGER.paused());
        (bytes32 revokedRoot,, uint64 revokedVersion) = MANAGER.activePolicies(address(this));
        assert(revokedRoot == bytes32(0) && revokedVersion == versionBefore + 2);
        _installRoot(POLICY_ROOT);
        VM.prank(GOVERNANCE);
        MANAGER.unpause();
        executeValid(uint96(rawAmount));
        ++scenarioRuns[6];
    }

    /// @notice EX-07: stale, lower, remove and restored limits preserve historical spend.
    function exerciseRiskGovernance(uint32 rawAmount) external {
        executeValid(uint96(rawAmount));
        uint256 spendBefore = MANAGER.currentWindowSpend(TRADER, address(ASSET_IN));
        uint64 nonce = _takeNonce();
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _authorization(
            keccak256(abi.encode("risk", nonce)), nonce, 1, POSITION_SCALE, 1, POSITION_SCALE
        );
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        MANAGER.pause();
        _setInputRisk(1, 1);
        VM.prank(GOVERNANCE);
        MANAGER.unpause();
        _expectFailure(
            authorization,
            calls,
            limits,
            proofs,
            commitment,
            AlphaEngineVaultExecutionManager.StaleRiskPolicy.selector
        );
        authorization.riskPolicyVersion = MANAGER.riskPolicyVersion();
        commitment = CAPITAL_MANAGER.approve(authorization);
        _expectFailure(
            authorization,
            calls,
            limits,
            proofs,
            commitment,
            AlphaEngineVaultExecutionManager.SpendWindowLimitExceeded.selector
        );
        assert(MANAGER.currentWindowSpend(TRADER, address(ASSET_IN)) == spendBefore);
        MANAGER.pause();
        _setInputRisk(0, 0);
        VM.prank(GOVERNANCE);
        MANAGER.unpause();
        authorization.riskPolicyVersion = MANAGER.riskPolicyVersion();
        commitment = CAPITAL_MANAGER.approve(authorization);
        _expectFailure(
            authorization,
            calls,
            limits,
            proofs,
            commitment,
            AlphaEngineVaultExecutionManager.MissingTraderRiskLimit.selector
        );
        MANAGER.pause();
        _setInputRisk(MAX_PER_EXECUTION, MAX_PER_24_HOURS);
        VM.prank(GOVERNANCE);
        MANAGER.unpause();
        assert(MANAGER.currentWindowSpend(TRADER, address(ASSET_IN)) == spendBefore);
        executeValid(uint96(rawAmount));
        ++scenarioRuns[7];
    }

    /// @notice EX-08: live target and decoder code identities are rechecked after approval.
    function exerciseCodeIdentity(uint32 rawAmount, bool mutateDecoder) external {
        uint256 amount = uint256(rawAmount) % 1e6 + 1;
        uint64 nonce = _takeNonce();
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _authorization(
            keccak256(abi.encode("code", nonce)),
            nonce,
            amount,
            amount * POSITION_SCALE,
            amount,
            amount * POSITION_SCALE
        );
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        address changed = mutateDecoder ? address(STRATEGY_DECODER) : address(STRATEGY_TARGET);
        bytes memory original = changed.code;
        VM.etch(changed, bytes.concat(original, hex"00"));
        _expectFailure(
            authorization,
            calls,
            limits,
            proofs,
            commitment,
            AlphaEngineVaultExecutionManager.InvalidManageProof.selector
        );
        VM.etch(changed, original);
        executeValid(uint96(rawAmount));
        ++scenarioRuns[8];
    }

    /// @notice EX-09: reordered and repeated approvals never hide cumulative exposure/reset loss.
    function exerciseApprovalOrdering(uint32 rawAmount, uint8 rawMutation) external {
        uint256 amount = uint256(rawAmount) % 1e6 + 1;
        uint64 nonce = _takeNonce();
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory ordinary,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory ordinaryProofs
        ) = _authorization(
            keccak256(abi.encode("approvals", nonce)),
            nonce,
            amount,
            amount * POSITION_SCALE,
            amount,
            amount * POSITION_SCALE
        );
        uint256 mutation = rawMutation % 3;
        uint256 count = mutation == 0 ? 4 : 3;
        AlphaEngineExecutionHashLib.CallV1[] memory calls =
            new AlphaEngineExecutionHashLib.CallV1[](count);
        bytes32[][] memory proofs = new bytes32[][](count);
        if (mutation == 0) {
            calls[0] = ordinary[0];
            calls[1] = ordinary[0];
            calls[2] = ordinary[1];
            calls[3] = ordinary[2];
            proofs[0] = ordinaryProofs[0];
            proofs[1] = ordinaryProofs[0];
            proofs[2] = ordinaryProofs[1];
            proofs[3] = ordinaryProofs[2];
        } else {
            calls[0] = ordinary[2];
            calls[1] = ordinary[1];
            calls[2] = ordinary[0];
            proofs[0] = ordinaryProofs[2];
            proofs[1] = ordinaryProofs[1];
            proofs[2] = ordinaryProofs[0];
            if (mutation == 2) {
                // A reset before use is valid only when the subsequent approval is also reset.
                calls[0] = ordinary[0];
                calls[1] = ordinary[2];
                calls[2] = ordinary[1];
                proofs[0] = ordinaryProofs[0];
                proofs[1] = ordinaryProofs[2];
                proofs[2] = ordinaryProofs[1];
            }
        }
        authorization.callsHash = AlphaEngineExecutionHashLib.hashCalls(calls);
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        bytes4 expected = mutation == 0
            ? AlphaEngineVaultExecutionManager.CumulativeApprovalAmountExceedsRiskLimit.selector
            : mutation == 1
                ? AlphaEngineVaultExecutionManager.ApprovalNotReset.selector
                : AlphaEngineFundVault.BatchCallFailed.selector;
        _expectFailure(authorization, calls, limits, proofs, commitment, expected);
        executeValid(uint96(rawAmount));
        ++scenarioRuns[9];
    }

    /// @notice EX-09: repeated exact approvals aggregate correctly in either asset direction.
    function exerciseAggregateApprovals(uint32 rawAmount, bool exitAsset) external {
        uint256 baseAmount = uint256(rawAmount) % 1e6 + 2;
        uint256 amount = exitAsset ? baseAmount * POSITION_SCALE : baseAmount;
        address input = exitAsset ? address(ASSET_OUT) : address(ASSET_IN);
        address output = exitAsset ? address(ASSET_IN) : address(ASSET_OUT);
        uint256 received = exitAsset ? baseAmount : baseAmount * POSITION_SCALE;
        // Genuine liquidity precondition: exits cannot consume more position or strategy cash.
        if (
            IERC20(input).balanceOf(FUND_VAULT) < amount
                || IERC20(output).balanceOf(address(STRATEGY_TARGET)) < received
        ) return;
        uint256 first = amount / 2;
        uint256 firstReceipt = exitAsset ? baseAmount / 2 : first * POSITION_SCALE;
        uint64 nonce = _takeNonce();
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
        ) = _authorizationFor(
            keccak256(abi.encode("aggregate", nonce)),
            nonce,
            input,
            output,
            amount,
            received,
            amount,
            received,
            exitAsset ? POSITION_APPROVAL_LEAF : INPUT_APPROVAL_LEAF,
            exitAsset ? EXIT_LEAF : ENTRY_LEAF
        );
        AlphaEngineExecutionHashLib.CallV1[] memory calls =
            new AlphaEngineExecutionHashLib.CallV1[](5);
        calls[0] = AlphaEngineExecutionHashLib.CallV1(
            address(ERC20_DECODER),
            input,
            0,
            abi.encodeCall(IERC20.approve, (address(STRATEGY_TARGET), first))
        );
        calls[1] = AlphaEngineExecutionHashLib.CallV1(
            address(STRATEGY_DECODER),
            address(STRATEGY_TARGET),
            0,
            abi.encodeCall(MockVaultStrategyTarget.swapExact, (input, output, first, firstReceipt))
        );
        calls[2] = AlphaEngineExecutionHashLib.CallV1(
            address(ERC20_DECODER),
            input,
            0,
            abi.encodeCall(IERC20.approve, (address(STRATEGY_TARGET), amount - first))
        );
        calls[3] = AlphaEngineExecutionHashLib.CallV1(
            address(STRATEGY_DECODER),
            address(STRATEGY_TARGET),
            0,
            abi.encodeCall(
                MockVaultStrategyTarget.swapExact,
                (input, output, amount - first, received - firstReceipt)
            )
        );
        calls[4] = AlphaEngineExecutionHashLib.CallV1(
            address(ERC20_DECODER),
            input,
            0,
            abi.encodeCall(IERC20.approve, (address(STRATEGY_TARGET), 0))
        );
        bytes32[][] memory proofs = new bytes32[][](5);
        for (uint256 i; i < 5; ++i) {
            proofs[i] = _proofFor(
                i % 2 == 0
                    ? (exitAsset ? POSITION_APPROVAL_LEAF : INPUT_APPROVAL_LEAF)
                    : (exitAsset ? EXIT_LEAF : ENTRY_LEAF)
            );
        }
        authorization.callsHash = AlphaEngineExecutionHashLib.hashCalls(calls);
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        MANAGER.executeCapitalIntent(authorization, calls, limits, proofs);
        assert(
            MANAGER.consumedExecutionCommitments(commitment)
                && CAPITAL_MANAGER.isExecutionConsumed(commitment)
        );
        assert(IERC20(input).allowance(FUND_VAULT, address(STRATEGY_TARGET)) == 0);
        _recordGhostSpend(!exitAsset, amount);
        if (exitAsset) {
            ghostExitPositionSpent += amount;
            ghostExitInputReceived += received;
        } else {
            ghostSpent += amount;
            ghostReceived += received;
        }
        ++scenarioRuns[9];
    }

    /// @notice EX-08: a mutable selector mapping/facet invalidates the pinned Pendle decoder before execution.
    function exerciseFacetIdentity(uint32 rawAmount, bool mutateCode) external {
        FacetIdentityRouter router = new FacetIdentityRouter();
        FacetIdentityCode facet = new FacetIdentityCode();
        router.setFacet(address(facet));
        AlphaEnginePendleV4PtDecoderAndSanitizer decoder = new AlphaEnginePendleV4PtDecoderAndSanitizer(
            FUND_VAULT, IAlphaEnginePendleRouterV4(address(router)), address(facet)
        );
        uint64 nonce = _takeNonce();
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
        ) = _authorization(
            keccak256(abi.encode("facet", nonce)), nonce, 1, POSITION_SCALE, 1, POSITION_SCALE
        );
        IAlphaEnginePendleRouterV4.TokenOutput memory output;
        output.tokenOut = address(ASSET_IN);
        output.tokenRedeemSy = address(ASSET_IN);
        output.minTokenOut = 1;
        IAlphaEnginePendleRouterV4.LimitOrderData memory noOrders;
        noOrders.normalFills = new IAlphaEnginePendleRouterV4.FillOrderParams[](0);
        noOrders.flashFills = new IAlphaEnginePendleRouterV4.FillOrderParams[](0);
        AlphaEngineExecutionHashLib.CallV1[] memory calls =
            new AlphaEngineExecutionHashLib.CallV1[](1);
        calls[0] = AlphaEngineExecutionHashLib.CallV1(
            address(decoder),
            address(router),
            0,
            abi.encodeCall(
                IAlphaEnginePendleRouterV4.swapExactPtForToken,
                (FUND_VAULT, address(0xCAFE), uint256(rawAmount) + 1, output, noOrders)
            )
        );
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        authorization.callsHash = AlphaEngineExecutionHashLib.hashCalls(calls);
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        if (mutateCode) VM.etch(address(facet), bytes.concat(address(facet).code, hex"00"));
        else router.setFacet(address(new FacetIdentityCode()));
        _expectFailure(
            authorization,
            calls,
            limits,
            proofs,
            commitment,
            mutateCode
                ? AlphaEnginePendleV4PtDecoderAndSanitizer.DependencyCodeHashChanged.selector
                : AlphaEnginePendleV4PtDecoderAndSanitizer.UnexpectedSelectorFacet.selector
        );
        ++scenarioRuns[8];
    }

    /// @notice EX-18: the full 16-call limit is usable; malformed/invalid last calls preflight atomically.
    function exerciseMaximumPreflight(uint32 rawValue, bool malformed) external {
        uint64 nonce = _takeNonce();
        (AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,,,) = _authorization(
            keccak256(abi.encode("max batch", nonce)), nonce, 1, POSITION_SCALE, 1, POSITION_SCALE
        );
        AlphaEngineExecutionHashLib.CallV1[] memory calls =
            new AlphaEngineExecutionHashLib.CallV1[](16);
        bytes32[][] memory proofs = new bytes32[][](16);
        for (uint256 i; i < 16; ++i) {
            calls[i] = AlphaEngineExecutionHashLib.CallV1(
                address(ERC20_DECODER),
                address(ASSET_IN),
                0,
                abi.encodeCall(IERC20.approve, (address(STRATEGY_TARGET), 0))
            );
            proofs[i] = _proofFor(INPUT_APPROVAL_LEAF);
        }
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits =
            new AlphaEngineExecutionHashLib.AssetDeltaLimitV1[](1);
        limits[0] = AlphaEngineExecutionHashLib.AssetDeltaLimitV1(
            address(ASSET_IN), uint256(rawValue) % MAX_PER_EXECUTION + 1, 0
        );
        authorization.callsHash = AlphaEngineExecutionHashLib.hashCalls(calls);
        authorization.riskEnvelopeHash = AlphaEngineExecutionHashLib.hashRiskEnvelope(limits);
        CAPITAL_MANAGER.approve(authorization);
        MANAGER.executeCapitalIntent(authorization, calls, limits, proofs);
        ++scenarioRuns[18];
        nonce = _takeNonce();
        authorization.intentId = keccak256(abi.encode("invalid last", nonce));
        authorization.authorizationNonce = nonce;
        if (malformed) calls[15].targetData = hex"01";
        else calls[15].target = address(0xBAD);
        authorization.callsHash = AlphaEngineExecutionHashLib.hashCalls(calls);
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        _expectFailure(
            authorization,
            calls,
            limits,
            proofs,
            commitment,
            malformed
                ? AlphaEngineVaultExecutionManager.CallDataTooShort.selector
                : AlphaEngineVaultExecutionManager.InvalidCallContract.selector
        );
        calls[15].target = address(ASSET_IN);
        calls[15].targetData = abi.encodeCall(IERC20.approve, (address(STRATEGY_TARGET), 0));
        authorization.callsHash = AlphaEngineExecutionHashLib.hashCalls(calls);
        CAPITAL_MANAGER.approve(authorization);
        MANAGER.executeCapitalIntent(authorization, calls, limits, proofs);
        assert(
            MANAGER.consumedExecutionCommitments(
                AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization)
            )
        );
    }

    /// @notice EX-13: a Merkle-allowed target cannot reenter execution or custody control paths.
    function exerciseReentrantTarget(uint32 rawReceipt) external {
        uint256 amount = uint256(rawReceipt) % 1e6 + 1;
        ExecutionCallbackProbe probe =
            new ExecutionCallbackProbe(MANAGER, IAlphaEngineFundVault(FUND_VAULT), ASSET_OUT);
        bytes32 callbackLeaf =
            _customLeaf(address(probe), address(probe), probe.probe.selector, bytes(""));
        _installRoot(callbackLeaf);
        uint64 nonce = _takeNonce();
        (AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,,,) =
            _authorization(keccak256(abi.encode("callback", nonce)), nonce, 1, 1, 1, 1);
        AlphaEngineExecutionHashLib.CallV1[] memory calls =
            new AlphaEngineExecutionHashLib.CallV1[](1);
        calls[0] = AlphaEngineExecutionHashLib.CallV1(
            address(probe), address(probe), 0, abi.encodeCall(probe.probe, (amount))
        );
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits =
            new AlphaEngineExecutionHashLib.AssetDeltaLimitV1[](1);
        limits[0] = AlphaEngineExecutionHashLib.AssetDeltaLimitV1(address(ASSET_OUT), 0, amount);
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        authorization.policyRoot = callbackLeaf;
        authorization.callsHash = AlphaEngineExecutionHashLib.hashCalls(calls);
        authorization.riskEnvelopeHash = AlphaEngineExecutionHashLib.hashRiskEnvelope(limits);
        CAPITAL_MANAGER.approve(authorization);
        MANAGER.executeCapitalIntent(authorization, calls, limits, proofs);
        assert(probe.checkedSelectors() == 4);
        ghostCallbackReceipts += amount;
        _installRoot(POLICY_ROOT);
        ++scenarioRuns[13];
    }

    /// @notice EX-15: explicit share risk catches direct-burn over-spend; omitted coverage is an exploratory lead.
    function exerciseDirectShareBurn(uint32 rawAssets, bool omitShareRisk) external {
        uint256 assets = uint256(rawAssets) % 1e6 + 2;
        MockERC20 token = new MockERC20("Scenario asset", "SCA", 6);
        DirectBurnPosition position = new DirectBurnPosition(token);
        AlphaEngineERC4626DecoderAndSanitizer decoder =
            new AlphaEngineERC4626DecoderAndSanitizer(FUND_VAULT);
        token.mint(address(this), assets);
        token.approve(address(position), assets);
        uint256 shares = position.deposit(assets, FUND_VAULT);
        bytes32 leaf = _customLeaf(
            address(decoder),
            address(position),
            IERC4626.redeem.selector,
            abi.encode(FUND_VAULT, FUND_VAULT)
        );
        _installRoot(leaf);
        uint64 nonce = _takeNonce();
        (AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,,,) =
            _authorization(keccak256(abi.encode("direct burn", nonce)), nonce, 1, 1, 1, 1);
        AlphaEngineExecutionHashLib.CallV1[] memory calls =
            new AlphaEngineExecutionHashLib.CallV1[](1);
        calls[0] = AlphaEngineExecutionHashLib.CallV1(
            address(decoder),
            address(position),
            0,
            abi.encodeCall(IERC4626.redeem, (shares, FUND_VAULT, FUND_VAULT))
        );
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits =
            new AlphaEngineExecutionHashLib.AssetDeltaLimitV1[](omitShareRisk ? 1 : 2);
        limits[0] = AlphaEngineExecutionHashLib.AssetDeltaLimitV1(address(token), 0, assets);
        if (!omitShareRisk) {
            MANAGER.pause();
            AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[] memory risk =
                new AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[](1);
            risk[0] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput(
                address(position), shares, shares
            );
            VM.prank(GOVERNANCE);
            MANAGER.setTraderAssetRiskLimits(TRADER, risk);
            VM.prank(GOVERNANCE);
            MANAGER.unpause();
            limits[1] =
                AlphaEngineExecutionHashLib.AssetDeltaLimitV1(address(position), shares - 1, 0);
            if (limits[0].asset > limits[1].asset) (limits[0], limits[1]) = (limits[1], limits[0]);
        }
        authorization.riskPolicyVersion = MANAGER.riskPolicyVersion();
        authorization.policyRoot = leaf;
        authorization.callsHash = AlphaEngineExecutionHashLib.hashCalls(calls);
        authorization.riskEnvelopeHash = AlphaEngineExecutionHashLib.hashRiskEnvelope(limits);
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        if (omitShareRisk) {
            MANAGER.executeCapitalIntent(authorization, calls, limits, proofs);
            assert(position.balanceOf(FUND_VAULT) == 0 && token.balanceOf(FUND_VAULT) == assets);
            assert(MANAGER.currentWindowSpend(TRADER, address(position)) == 0);
            exploratoryUntrackedShareBurn = true;
        } else {
            _expectFailure(
                authorization,
                calls,
                limits,
                proofs,
                commitment,
                AlphaEngineVaultExecutionManager.AssetSpendExceeded.selector
            );
            assert(position.balanceOf(FUND_VAULT) == shares && token.balanceOf(FUND_VAULT) == 0);
            for (uint256 i; i < limits.length; ++i) {
                if (limits[i].asset == address(position)) limits[i].maxSpend = shares;
            }
            authorization.riskEnvelopeHash = AlphaEngineExecutionHashLib.hashRiskEnvelope(limits);
            CAPITAL_MANAGER.approve(authorization);
            MANAGER.executeCapitalIntent(authorization, calls, limits, proofs);
            assert(position.balanceOf(FUND_VAULT) == 0 && token.balanceOf(FUND_VAULT) == assets);
            assert(MANAGER.currentWindowSpend(TRADER, address(position)) == shares);
        }
        _installRoot(POLICY_ROOT);
        ++scenarioRuns[15];
    }

    function _customLeaf(address decoder, address target, bytes4 selector, bytes memory arguments)
        private
        view
        returns (bytes32)
    {
        return AlphaEngineManageLeafHashLib.hashManageLeaf(
            AlphaEngineManageLeafHashLib.ManageLeafV1({
                chainId: block.chainid,
                vaultExecutionManager: address(MANAGER),
                fundVault: FUND_VAULT,
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

    function _attemptStaleRoot() private {
        uint64 nonce = _takeNonce();
        (
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization,
            AlphaEngineExecutionHashLib.CallV1[] memory calls,
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] memory limits,
            bytes32[][] memory proofs
        ) = _authorization(
            keccak256(abi.encode("stale root", nonce)), nonce, 1, POSITION_SCALE, 1, POSITION_SCALE
        );
        // Fresh time/risk but an old reviewed root/version isolates the root validation guard.
        authorization.policyVersion -= 1;
        bytes32 commitment = CAPITAL_MANAGER.approve(authorization);
        _expectFailure(
            authorization,
            calls,
            limits,
            proofs,
            commitment,
            AlphaEngineVaultExecutionManager.StalePolicy.selector
        );
    }

    function _setInputRisk(uint256 perExecution, uint256 perDay) private {
        AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[] memory risk =
            new AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput[](1);
        risk[0] = AlphaEngineVaultExecutionManager.TraderAssetRiskLimitInput(
            address(ASSET_IN), perExecution, perDay
        );
        VM.prank(GOVERNANCE);
        MANAGER.setTraderAssetRiskLimits(TRADER, risk);
    }

    function _installRoot(bytes32 root) private {
        uint40 activateAfter = uint40(VM.getBlockTimestamp() + 48 hours);
        MANAGER.proposePolicyRoot(address(this), root, ARTIFACT_HASH, activateAfter);
        VM.warp(activateAfter);
        _pruneGhostWindows();
        MANAGER.activatePolicyRoot(address(this));
    }

    function _activeVersion(address executor) private view returns (uint64 version) {
        (,, version) = MANAGER.activePolicies(executor);
    }

    function _policySnapshot() private view returns (bytes32) {
        (bytes32 root, bytes32 artifact, uint64 version) = MANAGER.activePolicies(address(this));
        (bytes32 pending, bytes32 pendingArtifact, uint40 activateAfter) =
            MANAGER.pendingPolicies(address(this));
        return
            keccak256(abi.encode(root, artifact, version, pending, pendingArtifact, activateAfter));
    }

    function _expectControlFailure(bytes memory data, bytes4 expected) private {
        bytes32 beforeState = _policySnapshot();
        (bool ok, bytes memory reason) = address(MANAGER).call(data);
        assert(!ok && _selector(reason) == expected);
        bytes32 afterState = _policySnapshot();
        assert(beforeState == afterState);
    }

    function _takeNonce() private returns (uint64 nonce) {
        nonce = nextNonce;
        nextNonce = nonce + 1;
    }

    function _selector(bytes memory revertData) private pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(revertData, 0x20))
        }
    }
}

/// @dev Distinct msg.sender for executor-bound policy and replay isolation.
contract ExecutionInvariantRelay {
    AlphaEngineVaultExecutionManager private immutable MANAGER;

    constructor(AlphaEngineVaultExecutionManager manager) {
        MANAGER = manager;
    }

    function execute(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization,
        AlphaEngineExecutionHashLib.CallV1[] calldata calls,
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] calldata limits,
        bytes32[][] calldata proofs
    ) external {
        MANAGER.executeCapitalIntent(authorization, calls, limits, proofs);
    }
}

contract DirectBurnPosition is ERC4626 {
    constructor(IERC20 underlying) ERC20("Scenario position", "SCP") ERC4626(underlying) {}
}

contract ExecutionCallbackProbe is IAlphaEngineDecoderAndSanitizer {
    AlphaEngineVaultExecutionManager private immutable MANAGER;
    IAlphaEngineFundVault private immutable VAULT;
    MockERC20 private immutable RECEIPT;
    uint256 public checkedSelectors;

    constructor(
        AlphaEngineVaultExecutionManager manager,
        IAlphaEngineFundVault vault,
        MockERC20 receipt
    ) {
        MANAGER = manager;
        VAULT = vault;
        RECEIPT = receipt;
    }

    function sanitize(bytes calldata data) external pure returns (bytes memory) {
        if (data.length != 36) revert CalldataTooShort(data.length);
        if (bytes4(data[:4]) != ExecutionCallbackProbe.probe.selector) {
            revert UnsupportedSelector(bytes4(data[:4]));
        }
        return bytes("");
    }

    function probe(uint256 amount) external {
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory emptyAuthorization;
        _denied(
            address(MANAGER),
            abi.encodeCall(
                IAlphaEngineVaultExecutionManager.executeCapitalIntent,
                (
                    emptyAuthorization,
                    new AlphaEngineExecutionHashLib.CallV1[](0),
                    new AlphaEngineExecutionHashLib.AssetDeltaLimitV1[](0),
                    new bytes32[][](0)
                )
            ),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );
        _denied(
            address(VAULT),
            abi.encodeCall(
                IAlphaEngineFundVault.settleDeposit, (address(this), address(this), 1, 1)
            ),
            AlphaEngineFundVault.UnauthorizedUSDCManager.selector
        );
        _denied(
            address(VAULT),
            abi.encodeCall(IAlphaEngineFundVault.recoverAsset, (IERC20(address(RECEIPT)))),
            AlphaEngineFundVault.UnauthorizedEmergencyAuthority.selector
        );
        _denied(
            address(VAULT),
            abi.encodeCall(
                IAlphaEngineFundVault.executeBatch,
                (new address[](0), new uint256[](0), new bytes[](0))
            ),
            AlphaEngineFundVault.UnauthorizedExecutionManager.selector
        );
        RECEIPT.mint(address(VAULT), amount);
    }

    function _denied(address target, bytes memory data, bytes4 expected) private {
        (bool success, bytes memory reason) = target.call(data);
        assert(!success && reason.length >= 4 && bytes4(reason) == expected);
        ++checkedSelectors;
    }
}

contract FacetIdentityCode {}

contract FacetIdentityRouter {
    address private _facet;

    function setFacet(address facet) external {
        _facet = facet;
    }

    function selectorToFacet(bytes4) external view returns (address) {
        return _facet;
    }
}
