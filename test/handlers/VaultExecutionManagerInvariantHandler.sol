// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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

    function executeValid(uint96 rawAmount) external {
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
    }

    function executeExit(uint96 rawAmount) external {
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
    }

    function advanceHoldingTime(uint32 rawSeconds) external {
        uint256 elapsed = uint256(rawSeconds) % (48 hours + 1);
        VM.warp(block.timestamp + elapsed);
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
        authorization.validAfter = lastSuccessfulValidAfter;
        authorization.deadline = lastSuccessfulDeadline;
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
        bytes4 expectedSelector = block.timestamp >= lastSuccessfulDeadline
            ? AlphaEngineVaultExecutionManager.AuthorizationExpired.selector
            : AlphaEngineVaultExecutionManager.ExecutionCommitmentAlreadyConsumed.selector;
        if (
            success || _selector(revertData) != expectedSelector
                || ASSET_IN.balanceOf(FUND_VAULT) != inputBefore
                || ASSET_OUT.balanceOf(FUND_VAULT) != outputBefore
                || !MANAGER.consumedExecutionCommitments(commitment)
        ) {
            replayViolation = true;
        }
        expectedFailures += 1;
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
        uint256 spendBefore = MANAGER.currentWindowSpend(TRADER, address(ASSET_IN));
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
                || MANAGER.currentWindowSpend(TRADER, address(ASSET_IN)) != spendBefore
                || MANAGER.consumedExecutionCommitments(commitment)
                || CAPITAL_MANAGER.isExecutionConsumed(commitment)
        ) {
            expectedFailureViolation = true;
        }
        expectedFailures += 1;
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
            validAfter: uint40(block.timestamp),
            deadline: uint40(block.timestamp + 1 hours),
            policyRoot: POLICY_ROOT,
            policyVersion: POLICY_VERSION,
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
        if (length != 0 && records[length - 1].timestamp == block.timestamp) {
            records[length - 1].amount += amount;
        } else {
            records.push(GhostSpendRecord({amount: amount, timestamp: uint40(block.timestamp)}));
        }
        if (inputAsset) ghostInputWindowSpend += amount;
        else ghostPositionWindowSpend += amount;
    }

    function _pruneGhostWindows() private {
        (_inputSpendHead, ghostInputWindowSpend) =
            _pruneGhostWindow(_inputSpendRecords, _inputSpendHead, ghostInputWindowSpend);
        (_positionSpendHead, ghostPositionWindowSpend) =
            _pruneGhostWindow(_positionSpendRecords, _positionSpendHead, ghostPositionWindowSpend);
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
                && uint256(records[newHead].timestamp) + 24 hours <= block.timestamp
        ) {
            newTotal -= records[newHead].amount;
            ++newHead;
        }
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
