// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    UnsignedEncryptedInput,
    FunctionId,
    ITaskManager
} from "@fhenixprotocol/cofhe-contracts/ICofhe.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract MockCoFheTaskManager is ITaskManager {
    error UnsupportedOperation();
    error UnknownCiphertext(uint256 ctHash);
    error SenderMismatch(address expectedSender, address actualSender);
    error InvalidSecurityZone(uint8 expectedSecurityZone, uint8 actualSecurityZone);
    error InvalidUtype(uint8 expectedUtype, uint8 actualUtype);
    error InvalidSignature(bytes32 expectedSignatureHash, bytes32 actualSignatureHash);
    error InvalidDecryptResult(uint256 ctHash, uint256 expectedResult, uint256 actualResult);
    error SenderNotAllowed(uint256 ctHash, address sender);
    error NotShared(uint256 handle, address receiver);
    error UnexpectedSharer(address expected, address actual);
    error InvalidSigner(address actual, address expected);
    address public verifierSigner;
    uint256 public batchVerificationCount;
    uint256 public taskCreationCount;
    uint256 public lastBatchSize;

    function setVerifierSigner(address signer) external {
        verifierSigner = signer;
    }

    struct RegisteredInput {
        bool exists;
        address sender;
        uint8 securityZone;
        uint8 utype;
        uint256 value;
    }

    mapping(uint256 ctHash => RegisteredInput input) private _registeredInputs;
    mapping(uint256 ctHash => mapping(address account => bool isAllowedAccount)) private
        _allowedAccounts;
    mapping(uint256 ctHash => bool isPubliclyAllowedCiphertext) private _publiclyAllowed;
    mapping(uint256 ctHash => uint256 result) private _decryptResults;
    mapping(uint256 ctHash => bool published) private _publishedResults;
    mapping(uint256 ctHash => uint256 count) public publicAllowCount;
    mapping(uint256 ctHash => address requestor) public lastPublicAllower;
    uint256 private _nextGeneratedCiphertext = 1;

    function registerInput(
        uint256 ctHash,
        address sender,
        uint8 securityZone,
        uint8 utype,
        uint256 value
    ) external {
        _registeredInputs[ctHash] = RegisteredInput({
            exists: true, sender: sender, securityZone: securityZone, utype: utype, value: value
        });
    }

    function mockValue(uint256 ctHash) external view returns (uint256) {
        RegisteredInput storage registeredInput = _registeredInputs[ctHash];
        if (!registeredInput.exists) {
            revert UnknownCiphertext(ctHash);
        }

        return registeredInput.value;
    }

    function createTask(
        uint8 returnType,
        FunctionId funcId,
        uint256[] memory encryptedInputs,
        uint256[] memory extraInputs
    ) external returns (uint256) {
        taskCreationCount += 1;
        uint256 value;

        if (funcId == FunctionId.trivialEncrypt) {
            value = extraInputs[0];
        } else if (funcId == FunctionId.add) {
            value = _value(encryptedInputs[0]) + _value(encryptedInputs[1]);
        } else if (funcId == FunctionId.sub) {
            uint256 lhs = _value(encryptedInputs[0]);
            uint256 rhs = _value(encryptedInputs[1]);
            value = lhs >= rhs ? lhs - rhs : 0;
        } else if (funcId == FunctionId.gte) {
            value = _value(encryptedInputs[0]) >= _value(encryptedInputs[1]) ? 1 : 0;
        } else if (funcId == FunctionId.lte) {
            value = _value(encryptedInputs[0]) <= _value(encryptedInputs[1]) ? 1 : 0;
        } else if (funcId == FunctionId.eq) {
            value = _value(encryptedInputs[0]) == _value(encryptedInputs[1]) ? 1 : 0;
        } else if (funcId == FunctionId.select) {
            value = _value(encryptedInputs[0]) != 0
                ? _value(encryptedInputs[1])
                : _value(encryptedInputs[2]);
        } else {
            revert UnsupportedOperation();
        }

        uint256 ctHash = uint256(
            keccak256(
                abi.encode(
                    "alphaengine.mock.cofhe-task",
                    _nextGeneratedCiphertext,
                    returnType,
                    funcId,
                    encryptedInputs,
                    extraInputs,
                    value
                )
            )
        );
        _nextGeneratedCiphertext += 1;

        _registeredInputs[ctHash] = RegisteredInput({
            exists: true, sender: msg.sender, securityZone: 0, utype: returnType, value: value
        });

        _allowTransient(ctHash, msg.sender);
        return ctHash;
    }

    function createRandomTask(uint8, uint256, int32) external pure returns (uint256) {
        revert UnsupportedOperation();
    }

    function batchVerifyInputs(
        UnsignedEncryptedInput[] memory inputs,
        address sender,
        bytes memory signature
    ) external returns (uint256[] memory handles) {
        handles = new uint256[](inputs.length);
        bytes32[] memory hashes = new bytes32[](inputs.length);
        for (uint256 i; i < inputs.length; ++i) {
            UnsignedEncryptedInput memory input = inputs[i];
            RegisteredInput storage registered = _registeredInputs[input.ctHash];
            if (!registered.exists) revert UnknownCiphertext(input.ctHash);
            if (registered.sender != sender) revert SenderMismatch(registered.sender, sender);
            if (registered.securityZone != input.securityZone) {
                revert InvalidSecurityZone(registered.securityZone, input.securityZone);
            }
            if (registered.utype != input.utype) {
                revert InvalidUtype(registered.utype, input.utype);
            }
            hashes[i] = keccak256(
                abi.encodePacked(
                    input.ctHash, input.utype, input.securityZone, sender, block.chainid, msg.sender
                )
            );
            // Test values use their registered handle directly; production appends type metadata.
            handles[i] = input.ctHash;
        }
        address signer = ECDSA.recover(keccak256(abi.encodePacked(hashes)), signature);
        if (signer != verifierSigner) revert InvalidSigner(signer, verifierSigner);
        for (uint256 i; i < handles.length; ++i) {
            _allowTransient(handles[i], msg.sender);
        }
        batchVerificationCount += 1;
        lastBatchSize = inputs.length;
    }

    function allow(uint256 ctHash, address account) external {
        if (!_registeredInputs[ctHash].exists) {
            revert UnknownCiphertext(ctHash);
        }

        _requireAllowed(ctHash, msg.sender);
        _allowedAccounts[ctHash][account] = true;
    }

    function isAllowed(uint256 ctHash, address account) external view returns (bool) {
        return _isAllowed(ctHash, account);
    }

    function isPubliclyAllowed(uint256 ctHash) external view returns (bool) {
        return _publiclyAllowed[ctHash];
    }

    function allowGlobal(uint256 ctHash) external {
        if (!_registeredInputs[ctHash].exists) {
            revert UnknownCiphertext(ctHash);
        }

        _requireAllowed(ctHash, msg.sender);
        _publiclyAllowed[ctHash] = true;
        publicAllowCount[ctHash] += 1;
        lastPublicAllower[ctHash] = msg.sender;
    }

    function allowTransient(uint256 ctHash, address account) external {
        _requireAllowed(ctHash, msg.sender);
        _allowTransient(ctHash, account);
    }

    function shareCtHash(uint256 ctHash, address receiver) external {
        _requireAllowed(ctHash, msg.sender);
        _allowTransient(ctHash, receiver);
        bytes32 slot = keccak256(abi.encode("mock.share", ctHash, receiver));
        address sharer = msg.sender;
        assembly { tstore(slot, sharer) }
    }

    function receiveCtHash(uint256 ctHash, address expectedSharer) external {
        bytes32 slot = keccak256(abi.encode("mock.share", ctHash, msg.sender));
        address sharer;
        assembly {
            sharer := tload(slot)
            tstore(slot, 0)
        }
        if (sharer == address(0)) revert NotShared(ctHash, msg.sender);
        if (sharer != expectedSharer) revert UnexpectedSharer(expectedSharer, sharer);
        _requireAllowed(ctHash, sharer);
    }

    function _allowTransient(uint256 ctHash, address account) private {
        bytes32 slot = keccak256(abi.encode("mock.allow", ctHash, account));
        assembly { tstore(slot, 1) }
    }

    function _isAllowed(uint256 ctHash, address account) private view returns (bool) {
        bytes32 slot = keccak256(abi.encode("mock.allow", ctHash, account));
        bool allowed;
        assembly { allowed := tload(slot) }
        return allowed || _allowedAccounts[ctHash][account] || _publiclyAllowed[ctHash];
    }

    function _requireAllowed(uint256 ctHash, address account) private view {
        if (!_registeredInputs[ctHash].exists) revert UnknownCiphertext(ctHash);
        if (!_isAllowed(ctHash, account)) revert SenderNotAllowed(ctHash, account);
    }

    function getDecryptResultSafe(uint256 ctHash) external view returns (uint256, bool) {
        return (_decryptResults[ctHash], _publishedResults[ctHash]);
    }

    function getDecryptResult(uint256 ctHash) external view returns (uint256) {
        if (!_publishedResults[ctHash]) {
            revert UnknownCiphertext(ctHash);
        }

        return _decryptResults[ctHash];
    }

    function publishDecryptResult(uint256 ctHash, uint256 result, bytes calldata) external {
        if (!_registeredInputs[ctHash].exists) {
            revert UnknownCiphertext(ctHash);
        }

        _decryptResults[ctHash] = result;
        _publishedResults[ctHash] = true;
    }

    function publishDecryptResultBatch(
        uint256[] calldata ctHashes,
        uint256[] calldata results,
        bytes[] calldata
    ) external {
        uint256 length = ctHashes.length;
        for (uint256 index = 0; index < length; ++index) {
            uint256 ctHash = ctHashes[index];
            if (!_registeredInputs[ctHash].exists) {
                revert UnknownCiphertext(ctHash);
            }

            _decryptResults[ctHash] = results[index];
            _publishedResults[ctHash] = true;
        }
    }

    function verifyDecryptResult(uint256 ctHash, uint256 result, bytes calldata)
        external
        view
        returns (bool)
    {
        if (!_publishedResults[ctHash] || _decryptResults[ctHash] != result) {
            revert InvalidDecryptResult(ctHash, _decryptResults[ctHash], result);
        }

        return true;
    }

    function verifyDecryptResultSafe(uint256 ctHash, uint256 result, bytes calldata)
        external
        view
        returns (bool)
    {
        return _publishedResults[ctHash] && _decryptResults[ctHash] == result;
    }

    function verifyDecryptResultBatch(
        uint256[] calldata ctHashes,
        uint256[] calldata results,
        bytes[] calldata
    ) external view returns (bool) {
        uint256 length = ctHashes.length;
        for (uint256 index = 0; index < length; ++index) {
            uint256 ctHash = ctHashes[index];
            if (!_publishedResults[ctHash] || _decryptResults[ctHash] != results[index]) {
                revert InvalidDecryptResult(ctHash, _decryptResults[ctHash], results[index]);
            }
        }

        return true;
    }

    function verifyDecryptResultBatchSafe(
        uint256[] calldata ctHashes,
        uint256[] calldata results,
        bytes[] calldata
    ) external view returns (bool[] memory verificationResults) {
        uint256 length = ctHashes.length;
        verificationResults = new bool[](length);
        for (uint256 index = 0; index < length; ++index) {
            verificationResults[index] = _publishedResults[ctHashes[index]]
                && _decryptResults[ctHashes[index]] == results[index];
        }
    }

    function _value(uint256 ctHash) private view returns (uint256) {
        _requireAllowed(ctHash, msg.sender);
        RegisteredInput storage registeredInput = _registeredInputs[ctHash];
        if (!registeredInput.exists) {
            revert UnknownCiphertext(ctHash);
        }

        return registeredInput.value;
    }
}
