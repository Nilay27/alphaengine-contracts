// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {
    IAlphaEngineCapitalStrategyManager
} from "../interfaces/IAlphaEngineCapitalStrategyManager.sol";
import {IAlphaEngineDecoderAndSanitizer} from "../interfaces/IAlphaEngineDecoderAndSanitizer.sol";
import {IAlphaEngineFundVault} from "../interfaces/IAlphaEngineFundVault.sol";
import {
    IAlphaEngineVaultExecutionManager
} from "../interfaces/IAlphaEngineVaultExecutionManager.sol";
import {AlphaEngineExecutionHashLib} from "../libraries/AlphaEngineExecutionHashLib.sol";
import {AlphaEngineManageLeafHashLib} from "../libraries/AlphaEngineManageLeafHashLib.sol";
import {AlphaEngineRollingSpendLib} from "../libraries/AlphaEngineRollingSpendLib.sol";

/// @title AlphaEngineVaultExecutionManager
/// @notice Verifies an evaluated capital authorization and its Merkle-constrained call bundle
///         before atomically asking the FundVault to execute it.
/// @dev This contract is deliberately not a custodian. It cannot mint fund shares, settle users,
///      report NAV, or bypass the FundVault's one-time execution-manager boundary.
contract AlphaEngineVaultExecutionManager is
    AccessControlDefaultAdminRules,
    Pausable,
    ReentrancyGuard,
    IAlphaEngineVaultExecutionManager
{
    using AlphaEngineRollingSpendLib for AlphaEngineRollingSpendLib.SpendWindow;

    uint48 public constant DEFAULT_ADMIN_DELAY = 48 hours;
    uint40 public constant MINIMUM_ROOT_DELAY = 48 hours;
    uint256 public constant MAX_CALL_COUNT = 16;
    uint256 public constant MAX_ASSET_LIMIT_COUNT = 16;

    bytes32 public constant ROOT_PROPOSER_ROLE = keccak256("ROOT_PROPOSER_ROLE");
    bytes32 public constant ROOT_GUARDIAN_ROLE = keccak256("ROOT_GUARDIAN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    struct ActivePolicy {
        bytes32 root;
        bytes32 artifactHash;
        uint64 version;
    }

    struct PendingPolicy {
        bytes32 root;
        bytes32 artifactHash;
        uint40 activateAfter;
    }

    struct TraderAssetRiskLimit {
        uint256 maxSpendPerExecution;
        uint256 maxSpendPer24Hours;
    }

    struct TraderAssetRiskLimitInput {
        address asset;
        uint256 maxSpendPerExecution;
        uint256 maxSpendPer24Hours;
    }

    struct ApprovalPair {
        address asset;
        address spender;
        uint256 finalAmount;
    }

    IAlphaEngineCapitalStrategyManager public immutable CAPITAL_MANAGER;
    IAlphaEngineFundVault public immutable FUND_VAULT;

    uint64 public riskPolicyVersion;

    mapping(address executor => ActivePolicy policy) public activePolicies;
    mapping(address executor => PendingPolicy policy) public pendingPolicies;
    mapping(address trader => mapping(address asset => TraderAssetRiskLimit limit)) public
        traderAssetRiskLimits;
    mapping(
        address trader => mapping(address asset => AlphaEngineRollingSpendLib.SpendWindow window)
    ) private _spendWindows;
    mapping(bytes32 executionCommitment => bool consumed) public consumedExecutionCommitments;
    mapping(uint64 authorizationNonce => bool consumed) public consumedAuthorizationNonces;

    error ZeroAddress(bytes32 field);
    error InvalidContract(bytes32 field, address account);
    error PolicyRootAlreadyPending(address executor);
    error NoPendingPolicyRoot(address executor);
    error ZeroPolicyRoot();
    error ZeroArtifactHash();
    error PolicyRootUnchanged(address executor, bytes32 root);
    error RootActivationTooEarly(uint40 supplied, uint40 earliest);
    error RootActivationNotReady(uint40 activateAfter, uint256 currentTimestamp);
    error PolicyVersionExhausted(address executor);
    error UnauthorizedPolicyCancellation(address actor);
    error InvalidFundVaultLink(address linkedManager, address expectedManager);
    error EmptyRiskLimitUpdate();
    error TooManyRiskLimitUpdates(uint256 supplied, uint256 maximum);
    error RiskAssetsNotStrictlyAscending(uint256 index, address previousAsset, address asset);
    error InvalidRiskAsset(uint256 index, address asset);
    error InvalidRiskLimit(address asset, uint256 maxPerExecution, uint256 maxPer24Hours);
    error RiskLimitUnchanged(address trader, address asset);
    error RiskPolicyVersionExhausted();
    error UnauthorizedExecutor(address actor, address expectedExecutor);
    error InvalidAuthorizationDomain(
        uint256 chainId,
        address capitalStrategyManager,
        address vaultExecutionManager,
        address fundVault
    );
    error AuthorizationNotYetActive(uint40 validAfter, uint256 currentTimestamp);
    error AuthorizationExpired(uint40 deadline, uint256 currentTimestamp);
    error StalePolicy(
        address executor,
        bytes32 suppliedRoot,
        bytes32 activeRoot,
        uint64 suppliedVersion,
        uint64 activeVersion
    );
    error StaleRiskPolicy(uint64 suppliedVersion, uint64 activeVersion);
    error CallsHashMismatch(bytes32 supplied, bytes32 computed);
    error RiskEnvelopeHashMismatch(bytes32 supplied, bytes32 computed);
    error ApprovedCommitmentMismatch(bytes32 computed, bytes32 approved);
    error ExecutionCommitmentAlreadyConsumed(bytes32 executionCommitment);
    error AuthorizationNonceAlreadyConsumed(uint64 authorizationNonce);
    error ProofCountMismatch(uint256 calls, uint256 proofs);
    error InvalidCallContract(uint256 index, address decoder, address target);
    error CallDataTooShort(uint256 index, uint256 length);
    error InvalidManageProof(uint256 index, bytes32 leaf, bytes32 root);
    error EmptyAssetLimits();
    error EmptyAssetLimit(uint256 index, address asset);
    error MissingTraderRiskLimit(address trader, address asset);
    error PerExecutionRiskLimitExceeded(
        address trader, address asset, uint256 authorized, uint256 maximum
    );
    error AssetBalanceCheckFailed(address asset);
    error AssetSpendExceeded(address asset, uint256 spent, uint256 maximum);
    error MinimumAssetReceiptNotMet(address asset, uint256 received, uint256 minimum);
    error SpendWindowLimitExceeded(address trader, address asset, uint256 spent, uint256 maximum);
    error ApprovalAssetNotRiskBound(uint256 callIndex, address asset);
    error ApprovalAmountExceedsRiskLimit(
        uint256 callIndex, address asset, uint256 amount, uint256 maximum
    );
    error CumulativeApprovalAmountExceedsRiskLimit(
        uint256 callIndex, address asset, uint256 cumulativeAmount, uint256 maximum
    );
    error ApprovalNotReset(address asset, address spender, uint256 finalAmount);
    error AllowanceCheckFailed(address asset, address spender);
    error ResidualAllowance(address asset, address spender, uint256 allowance);
    error CapitalConsumptionMismatch(bytes32 returnedCommitment, bytes32 expectedCommitment);

    event PolicyRootProposed(
        address indexed executor,
        bytes32 indexed root,
        bytes32 indexed artifactHash,
        uint40 activateAfter
    );
    event PolicyRootProposalCancelled(
        address indexed executor, bytes32 indexed root, bytes32 indexed artifactHash
    );
    event PolicyRootActivated(
        address indexed executor, bytes32 indexed root, bytes32 indexed artifactHash, uint64 version
    );
    event PolicyRootRevoked(address indexed executor, bytes32 indexed previousRoot, uint64 version);
    event TraderAssetRiskLimitUpdated(
        address indexed trader,
        address indexed asset,
        uint64 indexed riskPolicyVersion,
        uint256 maxSpendPerExecution,
        uint256 maxSpendPer24Hours
    );
    event CapitalIntentExecuted(
        bytes32 indexed intentId,
        address indexed trader,
        bytes32 indexed executionCommitment,
        address executor,
        uint64 authorizationNonce,
        bytes32 callsHash,
        bytes32 riskEnvelopeHash
    );
    event AssetDeltaEnforced(
        bytes32 indexed intentId,
        address indexed asset,
        uint256 spent,
        uint256 received,
        uint256 windowSpend
    );

    constructor(
        address initialDefaultAdmin,
        address initialRootProposer,
        address initialRootGuardian,
        IAlphaEngineCapitalStrategyManager capitalManager,
        IAlphaEngineFundVault fundVault
    ) AccessControlDefaultAdminRules(DEFAULT_ADMIN_DELAY, initialDefaultAdmin) {
        if (initialDefaultAdmin == address(0)) revert ZeroAddress("initialDefaultAdmin");
        if (initialRootProposer == address(0)) revert ZeroAddress("initialRootProposer");
        if (initialRootGuardian == address(0)) revert ZeroAddress("initialRootGuardian");
        if (address(capitalManager) == address(0) || address(capitalManager).code.length == 0) {
            revert InvalidContract("capitalManager", address(capitalManager));
        }
        if (address(fundVault) == address(0) || address(fundVault).code.length == 0) {
            revert InvalidContract("fundVault", address(fundVault));
        }

        CAPITAL_MANAGER = capitalManager;
        FUND_VAULT = fundVault;
        _grantRole(ROOT_PROPOSER_ROLE, initialRootProposer);
        _grantRole(ROOT_GUARDIAN_ROLE, initialRootGuardian);
        _grantRole(PAUSER_ROLE, initialRootGuardian);
        _pause();
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address linkedManager = FUND_VAULT.executionManager();
        if (linkedManager != address(this)) {
            revert InvalidFundVaultLink(linkedManager, address(this));
        }
        _unpause();
    }

    function proposePolicyRoot(
        address executor,
        bytes32 root,
        bytes32 artifactHash,
        uint40 activateAfter
    ) external onlyRole(ROOT_PROPOSER_ROLE) {
        if (executor == address(0)) revert ZeroAddress("executor");
        if (root == bytes32(0)) revert ZeroPolicyRoot();
        if (artifactHash == bytes32(0)) revert ZeroArtifactHash();
        if (pendingPolicies[executor].root != bytes32(0)) {
            revert PolicyRootAlreadyPending(executor);
        }
        if (activePolicies[executor].root == root) revert PolicyRootUnchanged(executor, root);

        uint40 earliest = SafeCast.toUint40(block.timestamp + MINIMUM_ROOT_DELAY);
        if (activateAfter < earliest) revert RootActivationTooEarly(activateAfter, earliest);
        pendingPolicies[executor] =
            PendingPolicy({root: root, artifactHash: artifactHash, activateAfter: activateAfter});
        emit PolicyRootProposed(executor, root, artifactHash, activateAfter);
    }

    function cancelPolicyRootProposal(address executor) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(ROOT_GUARDIAN_ROLE, msg.sender)) {
            revert UnauthorizedPolicyCancellation(msg.sender);
        }
        PendingPolicy memory pending = pendingPolicies[executor];
        if (pending.root == bytes32(0)) revert NoPendingPolicyRoot(executor);
        delete pendingPolicies[executor];
        emit PolicyRootProposalCancelled(executor, pending.root, pending.artifactHash);
    }

    function activatePolicyRoot(address executor) external {
        PendingPolicy memory pending = pendingPolicies[executor];
        if (pending.root == bytes32(0)) revert NoPendingPolicyRoot(executor);
        if (block.timestamp < pending.activateAfter) {
            revert RootActivationNotReady(pending.activateAfter, block.timestamp);
        }

        uint64 previousVersion = activePolicies[executor].version;
        if (previousVersion == type(uint64).max) revert PolicyVersionExhausted(executor);
        uint64 newVersion = previousVersion + 1;
        activePolicies[executor] = ActivePolicy({
            root: pending.root, artifactHash: pending.artifactHash, version: newVersion
        });
        delete pendingPolicies[executor];
        emit PolicyRootActivated(executor, pending.root, pending.artifactHash, newVersion);
    }

    function revokePolicyRoot(address executor) external onlyRole(ROOT_GUARDIAN_ROLE) {
        ActivePolicy storage policy = activePolicies[executor];
        bytes32 previousRoot = policy.root;
        if (previousRoot == bytes32(0)) revert ZeroPolicyRoot();
        if (policy.version == type(uint64).max) revert PolicyVersionExhausted(executor);

        uint64 newVersion = policy.version + 1;
        policy.root = bytes32(0);
        policy.artifactHash = bytes32(0);
        policy.version = newVersion;
        delete pendingPolicies[executor];
        if (!paused()) _pause();
        emit PolicyRootRevoked(executor, previousRoot, newVersion);
    }

    function setTraderAssetRiskLimits(address trader, TraderAssetRiskLimitInput[] calldata inputs)
        external
        whenPaused
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (trader == address(0)) revert ZeroAddress("trader");
        uint256 count = inputs.length;
        if (count == 0) revert EmptyRiskLimitUpdate();
        if (count > MAX_ASSET_LIMIT_COUNT) {
            revert TooManyRiskLimitUpdates(count, MAX_ASSET_LIMIT_COUNT);
        }
        if (riskPolicyVersion == type(uint64).max) revert RiskPolicyVersionExhausted();
        uint64 newVersion = riskPolicyVersion + 1;

        address previousAsset;
        for (uint256 i; i < count; ++i) {
            TraderAssetRiskLimitInput calldata input = inputs[i];
            address asset = input.asset;
            if (asset == address(0) || asset.code.length == 0) {
                revert InvalidRiskAsset(i, asset);
            }
            if (i != 0 && uint160(previousAsset) >= uint160(asset)) {
                revert RiskAssetsNotStrictlyAscending(i, previousAsset, asset);
            }
            bool removing = input.maxSpendPerExecution == 0 && input.maxSpendPer24Hours == 0;
            if (
                !removing
                    && (input.maxSpendPerExecution == 0
                        || input.maxSpendPer24Hours == 0
                        || input.maxSpendPerExecution > input.maxSpendPer24Hours)
            ) {
                revert InvalidRiskLimit(asset, input.maxSpendPerExecution, input.maxSpendPer24Hours);
            }

            TraderAssetRiskLimit storage current = traderAssetRiskLimits[trader][asset];
            if (
                current.maxSpendPerExecution == input.maxSpendPerExecution
                    && current.maxSpendPer24Hours == input.maxSpendPer24Hours
            ) {
                revert RiskLimitUnchanged(trader, asset);
            }
            current.maxSpendPerExecution = input.maxSpendPerExecution;
            current.maxSpendPer24Hours = input.maxSpendPer24Hours;
            previousAsset = asset;

            emit TraderAssetRiskLimitUpdated(
                trader, asset, newVersion, input.maxSpendPerExecution, input.maxSpendPer24Hours
            );
        }
        riskPolicyVersion = newVersion;
    }

    function currentWindowSpend(address trader, address asset) external view returns (uint256) {
        return _spendWindows[trader][asset].current();
    }

    function executeCapitalIntent(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization,
        AlphaEngineExecutionHashLib.CallV1[] calldata calls,
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] calldata limits,
        bytes32[][] calldata proofs
    ) external whenNotPaused nonReentrant {
        _validateAuthorizationDomain(authorization);
        ActivePolicy memory policy = _validateActivePolicy(authorization);

        bytes32 callsHash = AlphaEngineExecutionHashLib.hashCalls(calls);
        if (authorization.callsHash != callsHash) {
            revert CallsHashMismatch(authorization.callsHash, callsHash);
        }
        bytes32 riskEnvelopeHash = AlphaEngineExecutionHashLib.hashRiskEnvelope(limits);
        if (authorization.riskEnvelopeHash != riskEnvelopeHash) {
            revert RiskEnvelopeHashMismatch(authorization.riskEnvelopeHash, riskEnvelopeHash);
        }

        bytes32 executionCommitment =
            AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization);
        bytes32 approvedCommitment =
            CAPITAL_MANAGER.getApprovedExecutionCommitment(authorization.intentId);
        if (approvedCommitment != executionCommitment) {
            revert ApprovedCommitmentMismatch(executionCommitment, approvedCommitment);
        }
        if (consumedExecutionCommitments[executionCommitment]) {
            revert ExecutionCommitmentAlreadyConsumed(executionCommitment);
        }
        if (consumedAuthorizationNonces[authorization.authorizationNonce]) {
            revert AuthorizationNonceAlreadyConsumed(authorization.authorizationNonce);
        }

        (ApprovalPair[] memory approvals, uint256 approvalCount) =
            _validateCalls(authorization.trader, calls, limits, proofs, policy.root);
        uint256[] memory balancesBefore = _snapshotBalances(limits);

        consumedExecutionCommitments[executionCommitment] = true;
        consumedAuthorizationNonces[authorization.authorizationNonce] = true;

        bytes32 consumed = CAPITAL_MANAGER.consumeCapitalExecution(authorization);
        if (consumed != executionCommitment) {
            revert CapitalConsumptionMismatch(consumed, executionCommitment);
        }

        (address[] memory targets, uint256[] memory values, bytes[] memory targetData) =
            _vaultBatch(calls);
        FUND_VAULT.executeBatch(targets, values, targetData);

        _enforceAssetDeltas(authorization.intentId, authorization.trader, limits, balancesBefore);
        _enforceZeroAllowances(approvals, approvalCount);

        emit CapitalIntentExecuted(
            authorization.intentId,
            authorization.trader,
            executionCommitment,
            authorization.executor,
            authorization.authorizationNonce,
            callsHash,
            riskEnvelopeHash
        );
    }

    function _validateAuthorizationDomain(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization
    ) private view {
        if (msg.sender != authorization.executor) {
            revert UnauthorizedExecutor(msg.sender, authorization.executor);
        }
        if (
            authorization.chainId != block.chainid
                || authorization.capitalStrategyManager != address(CAPITAL_MANAGER)
                || authorization.vaultExecutionManager != address(this)
                || authorization.fundVault != address(FUND_VAULT)
        ) {
            revert InvalidAuthorizationDomain(
                authorization.chainId,
                authorization.capitalStrategyManager,
                authorization.vaultExecutionManager,
                authorization.fundVault
            );
        }
        if (block.timestamp < authorization.validAfter) {
            revert AuthorizationNotYetActive(authorization.validAfter, block.timestamp);
        }
        if (block.timestamp >= authorization.deadline) {
            revert AuthorizationExpired(authorization.deadline, block.timestamp);
        }
        if (authorization.riskPolicyVersion != riskPolicyVersion) {
            revert StaleRiskPolicy(authorization.riskPolicyVersion, riskPolicyVersion);
        }
    }

    function _validateActivePolicy(
        AlphaEngineExecutionHashLib.ExecutionCommitmentV1 calldata authorization
    ) private view returns (ActivePolicy memory policy) {
        policy = activePolicies[authorization.executor];
        if (
            policy.root == bytes32(0) || authorization.policyRoot != policy.root
                || authorization.policyVersion != policy.version
        ) {
            revert StalePolicy(
                authorization.executor,
                authorization.policyRoot,
                policy.root,
                authorization.policyVersion,
                policy.version
            );
        }
    }

    function _validateCalls(
        address trader,
        AlphaEngineExecutionHashLib.CallV1[] calldata calls,
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] calldata limits,
        bytes32[][] calldata proofs,
        bytes32 policyRoot
    ) private view returns (ApprovalPair[] memory approvals, uint256 approvalCount) {
        uint256 callCount = calls.length;
        if (proofs.length != callCount) revert ProofCountMismatch(callCount, proofs.length);
        _validateRiskLimits(trader, limits);

        approvals = new ApprovalPair[](callCount);
        uint256[] memory approvedAmountsByLimit = new uint256[](limits.length);
        for (uint256 i; i < callCount; ++i) {
            AlphaEngineExecutionHashLib.CallV1 calldata call_ = calls[i];
            if (call_.decoder.code.length == 0 || call_.target.code.length == 0) {
                revert InvalidCallContract(i, call_.decoder, call_.target);
            }
            if (call_.targetData.length < 4) revert CallDataTooShort(i, call_.targetData.length);

            bytes memory sanitizedArguments =
                IAlphaEngineDecoderAndSanitizer(call_.decoder).sanitize(call_.targetData);
            bytes4 selector = bytes4(call_.targetData[:4]);
            bytes32 leaf = AlphaEngineManageLeafHashLib.hashManageLeaf(
                AlphaEngineManageLeafHashLib.ManageLeafV1({
                    chainId: block.chainid,
                    vaultExecutionManager: address(this),
                    fundVault: address(FUND_VAULT),
                    decoder: call_.decoder,
                    decoderCodeHash: call_.decoder.codehash,
                    target: call_.target,
                    targetCodeHash: call_.target.codehash,
                    selector: selector,
                    maxNativeValue: call_.value,
                    sanitizedArguments: sanitizedArguments
                })
            );
            if (!AlphaEngineManageLeafHashLib.verifyProofCalldata(proofs[i], policyRoot, leaf)) {
                revert InvalidManageProof(i, leaf, policyRoot);
            }

            if (selector == IERC20.approve.selector) {
                (address spender, uint256 amount) =
                    abi.decode(call_.targetData[4:], (address, uint256));
                uint256 riskIndex = _riskLimitIndex(call_.target, limits, i);
                uint256 maximum = limits[riskIndex].maxSpend;
                if (amount > maximum) {
                    revert ApprovalAmountExceedsRiskLimit(i, call_.target, amount, maximum);
                }
                if (amount != 0) {
                    uint256 cumulativeAmount = approvedAmountsByLimit[riskIndex] + amount;
                    if (cumulativeAmount > maximum) {
                        revert CumulativeApprovalAmountExceedsRiskLimit(
                            i, call_.target, cumulativeAmount, maximum
                        );
                    }
                    approvedAmountsByLimit[riskIndex] = cumulativeAmount;
                }
                approvalCount =
                    _recordApproval(approvals, approvalCount, call_.target, spender, amount);
            }
        }

        for (uint256 i; i < approvalCount; ++i) {
            if (approvals[i].finalAmount != 0) {
                revert ApprovalNotReset(
                    approvals[i].asset, approvals[i].spender, approvals[i].finalAmount
                );
            }
        }
    }

    function _validateRiskLimits(
        address trader,
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] calldata limits
    ) private view {
        uint256 limitCount = limits.length;
        if (limitCount == 0) revert EmptyAssetLimits();
        for (uint256 i; i < limitCount; ++i) {
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1 calldata limit = limits[i];
            if (limit.asset.code.length == 0) revert InvalidRiskAsset(i, limit.asset);
            if (limit.maxSpend == 0 && limit.minReceive == 0) {
                revert EmptyAssetLimit(i, limit.asset);
            }
            if (limit.maxSpend != 0) {
                TraderAssetRiskLimit storage risk = traderAssetRiskLimits[trader][limit.asset];
                if (risk.maxSpendPerExecution == 0 || risk.maxSpendPer24Hours == 0) {
                    revert MissingTraderRiskLimit(trader, limit.asset);
                }
                if (limit.maxSpend > risk.maxSpendPerExecution) {
                    revert PerExecutionRiskLimitExceeded(
                        trader, limit.asset, limit.maxSpend, risk.maxSpendPerExecution
                    );
                }
            }
        }
    }

    function _snapshotBalances(AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] calldata limits)
        private
        view
        returns (uint256[] memory balances)
    {
        balances = new uint256[](limits.length);
        for (uint256 i; i < limits.length; ++i) {
            balances[i] = _assetBalance(limits[i].asset);
        }
    }

    function _enforceAssetDeltas(
        bytes32 intentId,
        address trader,
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] calldata limits,
        uint256[] memory balancesBefore
    ) private {
        for (uint256 i; i < limits.length; ++i) {
            AlphaEngineExecutionHashLib.AssetDeltaLimitV1 calldata limit = limits[i];
            TraderAssetRiskLimit storage risk = traderAssetRiskLimits[trader][limit.asset];
            if (limit.maxSpend != 0) {
                if (risk.maxSpendPerExecution == 0 || risk.maxSpendPer24Hours == 0) {
                    revert MissingTraderRiskLimit(trader, limit.asset);
                }
                if (limit.maxSpend > risk.maxSpendPerExecution) {
                    revert PerExecutionRiskLimitExceeded(
                        trader, limit.asset, limit.maxSpend, risk.maxSpendPerExecution
                    );
                }
            }

            uint256 balanceAfter = _assetBalance(limit.asset);
            uint256 balanceBefore = balancesBefore[i];
            uint256 spent = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
            uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
            if (spent > limit.maxSpend) {
                revert AssetSpendExceeded(limit.asset, spent, limit.maxSpend);
            }
            if (received < limit.minReceive) {
                revert MinimumAssetReceiptNotMet(limit.asset, received, limit.minReceive);
            }

            uint256 windowSpend;
            if (spent != 0) windowSpend = _consumeSpendLimit(trader, limit.asset, spent, risk);
            else windowSpend = _currentWindowSpend(trader, limit.asset);
            emit AssetDeltaEnforced(intentId, limit.asset, spent, received, windowSpend);
        }
    }

    function _consumeSpendLimit(
        address trader,
        address asset,
        uint256 spent,
        TraderAssetRiskLimit storage risk
    ) private returns (uint256 newSpend) {
        if (risk.maxSpendPerExecution == 0 || risk.maxSpendPer24Hours == 0) {
            revert MissingTraderRiskLimit(trader, asset);
        }
        if (spent > risk.maxSpendPerExecution) {
            revert PerExecutionRiskLimitExceeded(trader, asset, spent, risk.maxSpendPerExecution);
        }

        AlphaEngineRollingSpendLib.SpendWindow storage window = _spendWindows[trader][asset];
        newSpend = window.current() + spent;
        if (newSpend > risk.maxSpendPer24Hours) {
            revert SpendWindowLimitExceeded(trader, asset, newSpend, risk.maxSpendPer24Hours);
        }
        newSpend = window.consume(spent);
    }

    function _currentWindowSpend(address trader, address asset) private view returns (uint256) {
        return _spendWindows[trader][asset].current();
    }

    function _recordApproval(
        ApprovalPair[] memory approvals,
        uint256 approvalCount,
        address asset,
        address spender,
        uint256 amount
    ) private pure returns (uint256) {
        for (uint256 i; i < approvalCount; ++i) {
            if (approvals[i].asset == asset && approvals[i].spender == spender) {
                approvals[i].finalAmount = amount;
                return approvalCount;
            }
        }
        approvals[approvalCount] =
            ApprovalPair({asset: asset, spender: spender, finalAmount: amount});
        return approvalCount + 1;
    }

    function _riskLimitIndex(
        address asset,
        AlphaEngineExecutionHashLib.AssetDeltaLimitV1[] calldata limits,
        uint256 callIndex
    ) private pure returns (uint256) {
        for (uint256 i; i < limits.length; ++i) {
            if (limits[i].asset == asset) return i;
        }
        revert ApprovalAssetNotRiskBound(callIndex, asset);
    }

    function _enforceZeroAllowances(ApprovalPair[] memory approvals, uint256 approvalCount)
        private
        view
    {
        for (uint256 i; i < approvalCount; ++i) {
            ApprovalPair memory pair = approvals[i];
            uint256 remaining = _allowance(pair.asset, pair.spender);
            if (remaining != 0) revert ResidualAllowance(pair.asset, pair.spender, remaining);
        }
    }

    function _assetBalance(address asset) private view returns (uint256 balance) {
        (bool success, bytes memory result) =
            asset.staticcall(abi.encodeCall(IERC20.balanceOf, (address(FUND_VAULT))));
        if (!success || result.length < 32) revert AssetBalanceCheckFailed(asset);
        balance = abi.decode(result, (uint256));
    }

    function _allowance(address asset, address spender) private view returns (uint256 amount) {
        (bool success, bytes memory result) =
            asset.staticcall(abi.encodeCall(IERC20.allowance, (address(FUND_VAULT), spender)));
        if (!success || result.length < 32) revert AllowanceCheckFailed(asset, spender);
        amount = abi.decode(result, (uint256));
    }

    function _vaultBatch(AlphaEngineExecutionHashLib.CallV1[] calldata calls)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory targetData)
    {
        uint256 count = calls.length;
        targets = new address[](count);
        values = new uint256[](count);
        targetData = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            targets[i] = calls[i].target;
            values[i] = calls[i].value;
            targetData[i] = calls[i].targetData;
        }
    }
}
