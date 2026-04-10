// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {InEuint64, InEuint128, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {AlphaEngineIntentController} from "src/AlphaEngineIntentController.sol";
import {AlphaEngineConfidentialVault} from "src/vault/AlphaEngineConfidentialVault.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";

contract IntentControllerInvariantHandler is MockCoFheTest {
    struct StrategySnapshot {
        address submitter;
        bytes32 marketIdHandle;
        bytes32 timeframeKey;
        uint40 deadline;
        uint40 createdAt;
        uint64 submitterNonce;
        uint8 componentCount;
        bytes32 payloadHash;
        address listenerOperatorAtSubmit;
        AlphaEngineIntentController.IntentStatus expectedStatus;
    }

    struct SwapSnapshot {
        address submitter;
        address confidentialVault;
        address inputWrapper;
        bytes32 routeKey;
        bytes32 requestedInputHandle;
        bytes32 lockedAmountHandle;
        uint40 deadline;
        uint40 createdAt;
        uint64 submitterNonce;
        bytes32 payloadHash;
        AlphaEngineIntentController.IntentStatus expectedStatus;
    }

    struct LockSnapshot {
        address account;
        address wrapper;
        bytes32 lockedAmountHandle;
        AlphaEngineConfidentialVault.SwapIntentLockStatus expectedStatus;
    }

    AlphaEngineIntentController public immutable CONTROLLER;
    AlphaEngineConfidentialVault public immutable VAULT_A;
    AlphaEngineConfidentialVault public immutable VAULT_B;
    address public immutable WRAPPER_A;
    address public immutable WRAPPER_B;
    uint128 public immutable MARKET_ID;
    bytes32 public immutable TIMEFRAME_KEY;
    bytes32 public immutable ROUTE_KEY;
    address public immutable OWNER;
    address public immutable SUBMITTER_A;
    address public immutable SUBMITTER_B;
    address public immutable LISTENER_A;
    address public immutable LISTENER_B;

    mapping(address submitter => uint64 submissions) public strategySubmissionsBySubmitter;
    mapping(address submitter => uint64 submissions) public swapSubmissionsBySubmitter;
    mapping(address submitter => uint64 submissions) public totalSubmissionsBySubmitter;
    mapping(bytes32 intentId => bool) public knownIntent;
    mapping(bytes32 intentId => bool) public knownStrategyIntent;
    mapping(bytes32 intentId => bool) public knownSwapIntent;
    mapping(bytes32 handle => bool) public knownStrategyHandle;
    mapping(bytes32 handle => bool) public knownSwapLockedHandle;

    mapping(bytes32 intentId => StrategySnapshot snapshot) private _strategySnapshots;
    mapping(bytes32 intentId => SwapSnapshot snapshot) private _swapSnapshots;
    mapping(bytes32 intentId => LockSnapshot snapshot) private _lockSnapshots;
    mapping(bytes32 intentId => bytes32[] componentHandles) private _strategyComponentHandles;

    bytes32[] private _allIntentIds;
    bytes32[] private _strategyIntentIds;
    bytes32[] private _swapIntentIds;

    constructor(
        AlphaEngineIntentController controller_,
        AlphaEngineConfidentialVault vaultA_,
        address wrapperA_,
        AlphaEngineConfidentialVault vaultB_,
        address wrapperB_,
        uint128 marketId_,
        bytes32 timeframeKey_,
        bytes32 routeKey_,
        address owner_,
        address submitterA_,
        address submitterB_,
        address listenerA_,
        address listenerB_
    ) {
        _bindMockTaskManager();
        CONTROLLER = controller_;
        VAULT_A = vaultA_;
        WRAPPER_A = wrapperA_;
        VAULT_B = vaultB_;
        WRAPPER_B = wrapperB_;
        MARKET_ID = marketId_;
        TIMEFRAME_KEY = timeframeKey_;
        ROUTE_KEY = routeKey_;
        OWNER = owner_;
        SUBMITTER_A = submitterA_;
        SUBMITTER_B = submitterB_;
        LISTENER_A = listenerA_;
        LISTENER_B = listenerB_;
    }

    function submitStrategyAsA(uint128 value, uint8 rawCount) external {
        _submitStrategy(SUBMITTER_A, value, rawCount);
    }

    function submitStrategyAsB(uint128 value, uint8 rawCount) external {
        _submitStrategy(SUBMITTER_B, value, rawCount);
    }

    function submitSwapAsA(uint64 rawAmount) external {
        _submitSwap(SUBMITTER_A, rawAmount);
    }

    function submitSwapAsB(uint64 rawAmount) external {
        _submitSwap(SUBMITTER_B, rawAmount);
    }

    function cancelStrategyAsOwner(uint8 rawIndex) external {
        _cancelStrategy(OWNER, rawIndex);
    }

    function cancelStrategyAsSubmitterA(uint8 rawIndex) external {
        _cancelStrategy(SUBMITTER_A, rawIndex);
    }

    function cancelStrategyAsSubmitterB(uint8 rawIndex) external {
        _cancelStrategy(SUBMITTER_B, rawIndex);
    }

    function cancelSwapAsOwner(uint8 rawIndex) external {
        _cancelSwap(OWNER, rawIndex);
    }

    function cancelSwapAsSubmitterA(uint8 rawIndex) external {
        _cancelSwap(SUBMITTER_A, rawIndex);
    }

    function cancelSwapAsSubmitterB(uint8 rawIndex) external {
        _cancelSwap(SUBMITTER_B, rawIndex);
    }

    function rotateListenerToA() external {
        _setListenerOperator(LISTENER_A);
    }

    function rotateListenerToB() external {
        _setListenerOperator(LISTENER_B);
    }

    function rotateVaultToA() external {
        _setVault(address(VAULT_A));
    }

    function rotateVaultToB() external {
        _setVault(address(VAULT_B));
    }

    function allIntentIdsLength() external view returns (uint256) {
        return _allIntentIds.length;
    }

    function allIntentIdAt(uint256 index) external view returns (bytes32) {
        return _allIntentIds[index];
    }

    function strategyIntentIdsLength() external view returns (uint256) {
        return _strategyIntentIds.length;
    }

    function strategyIntentIdAt(uint256 index) external view returns (bytes32) {
        return _strategyIntentIds[index];
    }

    function swapIntentIdsLength() external view returns (uint256) {
        return _swapIntentIds.length;
    }

    function swapIntentIdAt(uint256 index) external view returns (bytes32) {
        return _swapIntentIds[index];
    }

    function strategySnapshot(bytes32 intentId) external view returns (StrategySnapshot memory) {
        return _strategySnapshots[intentId];
    }

    function strategyComponentHandleAt(bytes32 intentId, uint256 index)
        external
        view
        returns (bytes32)
    {
        return _strategyComponentHandles[intentId][index];
    }

    function swapSnapshot(bytes32 intentId) external view returns (SwapSnapshot memory) {
        return _swapSnapshots[intentId];
    }

    function lockSnapshot(bytes32 intentId) external view returns (LockSnapshot memory) {
        return _lockSnapshots[intentId];
    }

    function _submitStrategy(address sender, uint128 value, uint8 rawCount) private {
        uint256 count = bound(uint256(rawCount), 1, CONTROLLER.MAX_COMPONENT_COUNT());
        InEuint128 memory input = createInEuint128(value, sender);
        InEuint128[] memory inputs = new InEuint128[](count);
        for (uint256 index = 0; index < count; ++index) {
            inputs[index] = input;
        }
        InEuint128 memory marketIdInput = createInEuint128(MARKET_ID, sender);

        vm.prank(sender);
        try CONTROLLER.submitStrategyIntent(
            marketIdInput, TIMEFRAME_KEY, inputs, uint40(block.timestamp) + 1 hours
        ) returns (bytes32 intentId) {
            _recordStrategyIntent(intentId);
            strategySubmissionsBySubmitter[sender] += 1;
            totalSubmissionsBySubmitter[sender] += 1;
        } catch {}
    }

    function _submitSwap(address sender, uint64 rawAmount) private {
        (AlphaEngineConfidentialVault activeVault, address activeWrapper) = _activeVaultAndWrapper();
        uint64 amount = uint64(bound(uint256(rawAmount), 1, 1000));
        InEuint64 memory input = createInEuint64(amount, sender);

        vm.prank(sender);
        try CONTROLLER.submitSwapIntent(
            activeWrapper, ROUTE_KEY, input, uint40(block.timestamp) + 1 hours
        ) returns (bytes32 intentId) {
            _recordSwapIntent(intentId, input.ctHash, activeVault);
            swapSubmissionsBySubmitter[sender] += 1;
            totalSubmissionsBySubmitter[sender] += 1;
        } catch {}
    }

    function _cancelStrategy(address actor, uint8 rawIndex) private {
        if (_strategyIntentIds.length == 0) {
            return;
        }

        bytes32 intentId =
            _strategyIntentIds[bound(uint256(rawIndex), 0, _strategyIntentIds.length - 1)];
        vm.prank(actor);
        try CONTROLLER.cancelStrategyIntent(intentId) {
            _strategySnapshots[intentId].expectedStatus =
                AlphaEngineIntentController.IntentStatus.Cancelled;
        } catch {}
    }

    function _cancelSwap(address actor, uint8 rawIndex) private {
        if (_swapIntentIds.length == 0) {
            return;
        }

        bytes32 intentId = _swapIntentIds[bound(uint256(rawIndex), 0, _swapIntentIds.length - 1)];
        vm.prank(actor);
        try CONTROLLER.cancelSwapIntent(intentId) {
            _swapSnapshots[intentId].expectedStatus =
                AlphaEngineIntentController.IntentStatus.Cancelled;
            _lockSnapshots[intentId].expectedStatus =
                AlphaEngineConfidentialVault.SwapIntentLockStatus.Unlocked;
        } catch {}
    }

    function _setListenerOperator(address listenerOperator) private {
        vm.prank(OWNER);
        try CONTROLLER.setListenerOperator(listenerOperator) {} catch {}
    }

    function _setVault(address vault) private {
        vm.prank(OWNER);
        try CONTROLLER.setConfidentialVault(vault) {} catch {}
    }

    function _recordStrategyIntent(bytes32 intentId) private {
        assertFalse(knownIntent[intentId], "duplicate intent id");
        knownIntent[intentId] = true;
        knownStrategyIntent[intentId] = true;
        _allIntentIds.push(intentId);
        _strategyIntentIds.push(intentId);

        AlphaEngineIntentController.IntentRecord memory intentRecord =
            CONTROLLER.getIntent(intentId);
        bytes32[] memory componentHandles = CONTROLLER.getIntentComponentHandles(intentId);

        for (uint256 index = 0; index < componentHandles.length; ++index) {
            assertFalse(
                knownSwapLockedHandle[componentHandles[index]],
                "strategy handle reused as swap lock handle"
            );
            knownStrategyHandle[componentHandles[index]] = true;
            _strategyComponentHandles[intentId].push(componentHandles[index]);
        }

        _strategySnapshots[intentId] = StrategySnapshot({
            submitter: intentRecord.submitter,
            marketIdHandle: intentRecord.marketIdHandle,
            timeframeKey: intentRecord.timeframeKey,
            deadline: intentRecord.deadline,
            createdAt: intentRecord.createdAt,
            submitterNonce: intentRecord.submitterNonce,
            componentCount: intentRecord.componentCount,
            payloadHash: intentRecord.payloadHash,
            listenerOperatorAtSubmit: CONTROLLER.listenerOperator(),
            expectedStatus: AlphaEngineIntentController.IntentStatus.Active
        });
    }

    function _recordSwapIntent(
        bytes32 intentId,
        uint256 requestedInputHandle,
        AlphaEngineConfidentialVault activeVault
    ) private {
        assertFalse(knownIntent[intentId], "duplicate intent id");
        knownIntent[intentId] = true;
        knownSwapIntent[intentId] = true;
        _allIntentIds.push(intentId);
        _swapIntentIds.push(intentId);

        AlphaEngineIntentController.SwapIntentRecord memory swapRecord =
            CONTROLLER.getSwapIntent(intentId);
        AlphaEngineConfidentialVault.SwapIntentLock memory intentLock =
            activeVault.getSwapIntentLock(intentId);
        bytes32 lockedAmountHandle = euint64.unwrap(intentLock.lockedAmount);

        assertFalse(
            knownStrategyHandle[lockedAmountHandle], "swap lock handle reused as strategy handle"
        );
        knownSwapLockedHandle[lockedAmountHandle] = true;

        _swapSnapshots[intentId] = SwapSnapshot({
            submitter: swapRecord.submitter,
            confidentialVault: swapRecord.confidentialVault,
            inputWrapper: swapRecord.inputWrapper,
            routeKey: swapRecord.routeKey,
            requestedInputHandle: bytes32(requestedInputHandle),
            lockedAmountHandle: swapRecord.lockedAmountHandle,
            deadline: swapRecord.deadline,
            createdAt: swapRecord.createdAt,
            submitterNonce: swapRecord.submitterNonce,
            payloadHash: swapRecord.payloadHash,
            expectedStatus: AlphaEngineIntentController.IntentStatus.Active
        });
        _lockSnapshots[intentId] = LockSnapshot({
            account: intentLock.account,
            wrapper: intentLock.wrapper,
            lockedAmountHandle: lockedAmountHandle,
            expectedStatus: AlphaEngineConfidentialVault.SwapIntentLockStatus.Locked
        });
    }

    function _activeVaultAndWrapper()
        private
        view
        returns (AlphaEngineConfidentialVault activeVault, address activeWrapper)
    {
        address configuredVault = CONTROLLER.confidentialVault();
        if (configuredVault == address(VAULT_B)) {
            return (VAULT_B, WRAPPER_B);
        }

        return (VAULT_A, WRAPPER_A);
    }
}
