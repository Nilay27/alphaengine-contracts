// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {FHE, InEuint128, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

contract AlphaEngineIntentController is Initializable, OwnableUpgradeable, PausableUpgradeable {
    uint256 public constant MAX_COMPONENT_COUNT = 16;

    enum IntentStatus {
        Unset,
        Active,
        Cancelled
    }

    struct IntentRecord {
        address submitter;
        address market;
        bytes32 timeframeKey;
        uint40 deadline;
        uint40 createdAt;
        uint64 submitterNonce;
        uint8 componentCount;
        IntentStatus status;
        bytes32 payloadHash;
    }

    error ZeroOwner();
    error ZeroListenerOperator();
    error ZeroMarket();
    error ZeroTimeframeKey();
    error DeadlineNotInFuture(uint40 deadline, uint40 currentTimestamp);
    error InvalidComponentCount(uint256 componentCount);
    error IntentNotFound(bytes32 intentId);
    error IntentAlreadyCancelled(bytes32 intentId);
    error UnauthorizedCancel(address actor, bytes32 intentId);

    event StrategyIntentSubmitted(
        bytes32 indexed intentId,
        address indexed submitter,
        address indexed market,
        bytes32 timeframeKey,
        bytes32[] componentHandles,
        uint40 deadline,
        bytes32 payloadHash,
        uint64 submitterNonce
    );
    event StrategyIntentCancelled(bytes32 indexed intentId, address indexed actor);
    event ListenerOperatorUpdated(address indexed previousOperator, address indexed newOperator);

    address public listenerOperator;
    mapping(bytes32 intentId => IntentRecord intentRecord) private _intentRecords;
    mapping(bytes32 intentId => bytes32[] componentHandles) private _intentComponentHandles;
    mapping(address submitter => uint64 nonce) public submitterNonces;

    uint256[46] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address listenerOperator_) external initializer {
        if (owner_ == address(0)) {
            revert ZeroOwner();
        }
        if (listenerOperator_ == address(0)) {
            revert ZeroListenerOperator();
        }

        __Ownable_init(owner_);
        __Pausable_init();

        listenerOperator = listenerOperator_;
    }

    function submitStrategyIntent(
        address market,
        bytes32 timeframeKey,
        InEuint128[] calldata encryptedComponents,
        uint40 deadline
    ) external whenNotPaused returns (bytes32 intentId) {
        if (market == address(0)) {
            revert ZeroMarket();
        }
        if (timeframeKey == bytes32(0)) {
            revert ZeroTimeframeKey();
        }
        if (deadline <= block.timestamp) {
            revert DeadlineNotInFuture(deadline, uint40(block.timestamp));
        }

        uint256 componentCount = encryptedComponents.length;
        if (componentCount == 0 || componentCount > MAX_COMPONENT_COUNT) {
            revert InvalidComponentCount(componentCount);
        }

        uint64 submitterNonce = submitterNonces[msg.sender];
        intentId = keccak256(abi.encode(address(this), block.chainid, msg.sender, submitterNonce));

        bytes32[] memory componentHandles = new bytes32[](componentCount);
        bytes32[] storage storedHandles = _intentComponentHandles[intentId];

        for (uint256 index = 0; index < componentCount; ++index) {
            euint128 internalizedComponent = FHE.asEuint128(encryptedComponents[index]);
            FHE.allowThis(internalizedComponent);
            FHE.allow(internalizedComponent, listenerOperator);

            bytes32 componentHandle = FHE.unwrap(internalizedComponent);
            componentHandles[index] = componentHandle;
            storedHandles.push(componentHandle);
        }

        bytes32 payloadHash = keccak256(abi.encode(market, timeframeKey, deadline, componentHandles));

        _intentRecords[intentId] = IntentRecord({
            submitter: msg.sender,
            market: market,
            timeframeKey: timeframeKey,
            deadline: deadline,
            createdAt: uint40(block.timestamp),
            submitterNonce: submitterNonce,
            // forge-lint: disable-next-line(unsafe-typecast)
            componentCount: uint8(componentCount),
            status: IntentStatus.Active,
            payloadHash: payloadHash
        });

        submitterNonces[msg.sender] = submitterNonce + 1;

        emit StrategyIntentSubmitted(
            intentId,
            msg.sender,
            market,
            timeframeKey,
            componentHandles,
            deadline,
            payloadHash,
            submitterNonce
        );
    }

    function cancelStrategyIntent(bytes32 intentId) external {
        IntentRecord storage intentRecord = _intentRecords[intentId];

        if (intentRecord.status == IntentStatus.Unset) {
            revert IntentNotFound(intentId);
        }
        if (intentRecord.status == IntentStatus.Cancelled) {
            revert IntentAlreadyCancelled(intentId);
        }
        if (msg.sender != intentRecord.submitter && msg.sender != owner()) {
            revert UnauthorizedCancel(msg.sender, intentId);
        }

        intentRecord.status = IntentStatus.Cancelled;
        emit StrategyIntentCancelled(intentId, msg.sender);
    }

    function setListenerOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) {
            revert ZeroListenerOperator();
        }

        address previousOperator = listenerOperator;
        listenerOperator = newOperator;

        emit ListenerOperatorUpdated(previousOperator, newOperator);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getIntent(bytes32 intentId) external view returns (IntentRecord memory) {
        return _intentRecords[intentId];
    }

    function getIntentComponentHandles(bytes32 intentId) external view returns (bytes32[] memory) {
        return _intentComponentHandles[intentId];
    }
}
