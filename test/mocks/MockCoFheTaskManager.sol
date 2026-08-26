// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    EncryptedInput, FunctionId, ITaskManager
} from "@fhenixprotocol/cofhe-contracts/ICofhe.sol";

contract MockCoFheTaskManager is ITaskManager {
    error UnsupportedOperation();
    error UnknownCiphertext(uint256 ctHash);
    error SenderMismatch(address expectedSender, address actualSender);
    error InvalidSecurityZone(uint8 expectedSecurityZone, uint8 actualSecurityZone);
    error InvalidUtype(uint8 expectedUtype, uint8 actualUtype);
    error InvalidSignature(bytes32 expectedSignatureHash, bytes32 actualSignatureHash);
    error InvalidDecryptResult(uint256 ctHash, uint256 expectedResult, uint256 actualResult);
    error DecryptRequesterNotAllowed(uint256 ctHash, address requester);

    struct RegisteredInput {
        bool exists;
        address sender;
        uint8 securityZone;
        uint8 utype;
        uint256 value;
        bytes32 signatureHash;
    }

    mapping(uint256 ctHash => RegisteredInput input) private _registeredInputs;
    mapping(uint256 ctHash => mapping(address account => bool isAllowedAccount)) private
        _allowedAccounts;
    mapping(uint256 ctHash => bool isPubliclyAllowedCiphertext) private _publiclyAllowed;
    mapping(uint256 ctHash => uint256 result) private _decryptResults;
    mapping(uint256 ctHash => bool published) private _publishedResults;
    mapping(uint256 ctHash => uint256 count) public decryptRequestCount;
    mapping(uint256 ctHash => address requestor) public lastDecryptRequestor;
    uint256 private _nextGeneratedCiphertext = 1;

    function registerInput(
        uint256 ctHash,
        address sender,
        uint8 securityZone,
        uint8 utype,
        uint256 value,
        bytes calldata signature
    ) external {
        _registeredInputs[ctHash] = RegisteredInput({
            exists: true,
            sender: sender,
            securityZone: securityZone,
            utype: utype,
            value: value,
            signatureHash: keccak256(signature)
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
            exists: true,
            sender: msg.sender,
            securityZone: 0,
            utype: returnType,
            value: value,
            signatureHash: bytes32(0)
        });

        return ctHash;
    }

    function createRandomTask(uint8, uint256, int32) external pure returns (uint256) {
        revert UnsupportedOperation();
    }

    function createDecryptTask(uint256 ctHash, address requestor) external {
        if (!_registeredInputs[ctHash].exists) {
            revert UnknownCiphertext(ctHash);
        }
        if (!_allowedAccounts[ctHash][msg.sender] && !_publiclyAllowed[ctHash]) {
            revert DecryptRequesterNotAllowed(ctHash, msg.sender);
        }

        decryptRequestCount[ctHash] += 1;
        lastDecryptRequestor[ctHash] = requestor;
    }

    function verifyInput(EncryptedInput memory input, address sender)
        external
        view
        returns (uint256)
    {
        RegisteredInput storage registeredInput = _registeredInputs[input.ctHash];
        if (!registeredInput.exists) {
            revert UnknownCiphertext(input.ctHash);
        }
        if (registeredInput.sender != sender) {
            revert SenderMismatch(registeredInput.sender, sender);
        }
        if (registeredInput.securityZone != input.securityZone) {
            revert InvalidSecurityZone(registeredInput.securityZone, input.securityZone);
        }
        if (registeredInput.utype != input.utype) {
            revert InvalidUtype(registeredInput.utype, input.utype);
        }

        bytes32 actualSignatureHash = keccak256(input.signature);
        if (registeredInput.signatureHash != actualSignatureHash) {
            revert InvalidSignature(registeredInput.signatureHash, actualSignatureHash);
        }

        return input.ctHash;
    }

    function allow(uint256 ctHash, address account) external {
        if (!_registeredInputs[ctHash].exists) {
            revert UnknownCiphertext(ctHash);
        }

        _allowedAccounts[ctHash][account] = true;
    }

    function isAllowed(uint256 ctHash, address account) external view returns (bool) {
        return _allowedAccounts[ctHash][account] || _publiclyAllowed[ctHash];
    }

    function isPubliclyAllowed(uint256 ctHash) external view returns (bool) {
        return _publiclyAllowed[ctHash];
    }

    function allowGlobal(uint256 ctHash) external {
        if (!_registeredInputs[ctHash].exists) {
            revert UnknownCiphertext(ctHash);
        }

        _publiclyAllowed[ctHash] = true;
    }

    function allowTransient(uint256 ctHash, address account) external {
        if (!_registeredInputs[ctHash].exists) {
            revert UnknownCiphertext(ctHash);
        }

        _allowedAccounts[ctHash][account] = true;
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
        RegisteredInput storage registeredInput = _registeredInputs[ctHash];
        if (!registeredInput.exists) {
            revert UnknownCiphertext(ctHash);
        }

        return registeredInput.value;
    }
}
