// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";
import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {MockFundVaultCallTarget} from "test/mocks/MockFundVaultExecution.sol";

contract FundVaultExecutionInvariantHandler {
    IAlphaEngineFundVault public immutable VAULT;
    MockFundVaultCallTarget public immutable TARGET;
    address public immutable ACCOUNTING_MANAGER;

    uint256 public ghostSuccessfulTotal;
    uint256 public successfulBatches;
    uint256 public failedBatches;
    uint256 public protectedCalls;
    bool public rollbackViolation;
    bool public protectedTargetViolation;
    uint256 public maximumBatches;
    uint256 public preflightFailures;
    uint256 public callbackProbes;
    bool public boundaryViolation;

    constructor(
        IAlphaEngineFundVault vault,
        MockFundVaultCallTarget target,
        address accountingManager
    ) {
        VAULT = vault;
        TARGET = target;
        ACCOUNTING_MANAGER = accountingManager;
    }

    function executeSuccessful(uint96 first, uint96 second) external {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory targetData = new bytes[](2);
        targets[0] = address(TARGET);
        targets[1] = address(TARGET);
        targetData[0] = abi.encodeCall(MockFundVaultCallTarget.add, (first));
        targetData[1] = abi.encodeCall(MockFundVaultCallTarget.add, (second));

        VAULT.executeBatch(targets, values, targetData);
        ghostSuccessfulTotal += uint256(first) + uint256(second);
        successfulBatches += 1;
    }

    function executeFailing(uint96 first, uint96 failureValue) external {
        uint256 totalBefore = TARGET.total();
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory targetData = new bytes[](2);
        targets[0] = address(TARGET);
        targets[1] = address(TARGET);
        targetData[0] = abi.encodeCall(MockFundVaultCallTarget.add, (first));
        targetData[1] = abi.encodeCall(MockFundVaultCallTarget.fail, (failureValue));

        (bool success, bytes memory revertData) = address(VAULT)
            .call(abi.encodeCall(IAlphaEngineFundVault.executeBatch, (targets, values, targetData)));
        if (
            success || _selector(revertData) != AlphaEngineFundVault.BatchCallFailed.selector
                || TARGET.total() != totalBefore
        ) {
            rollbackViolation = true;
        }
        failedBatches += 1;
    }

    function attemptProtectedAccountingCall(bytes32 seed) external {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory targetData = new bytes[](1);
        targets[0] = ACCOUNTING_MANAGER;
        targetData[0] = abi.encode(seed);

        (bool success, bytes memory revertData) = address(VAULT)
            .call(abi.encodeCall(IAlphaEngineFundVault.executeBatch, (targets, values, targetData)));
        if (success || _selector(revertData) != AlphaEngineFundVault.ProtectedBatchTarget.selector)
        {
            protectedTargetViolation = true;
        }
        protectedCalls += 1;
    }

    /// @notice EX-18: exact maximum is usable; forbidden later calls are preflighted atomically.
    function exerciseBatchBoundaries(uint96 rawValue, uint8 rawFailure) external {
        uint256 count = AlphaEngineFundVault(address(VAULT)).MAX_BATCH_CALLS();
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory data = new bytes[](count);
        uint256 value = uint256(rawValue) % 1e18;
        for (uint256 i; i < count; ++i) {
            targets[i] = address(TARGET);
            data[i] = abi.encodeCall(MockFundVaultCallTarget.add, (value));
        }
        VAULT.executeBatch(targets, values, data);
        ghostSuccessfulTotal += count * value;
        ++successfulBatches;
        ++maximumBatches;

        uint256 totalBefore = TARGET.total();
        bool protected = rawFailure % 2 == 0;
        targets[count - 1] = protected ? ACCOUNTING_MANAGER : address(0xBAD);
        (bool success, bytes memory reason) = address(VAULT)
            .call(abi.encodeCall(IAlphaEngineFundVault.executeBatch, (targets, values, data)));
        bytes4 expected = protected
            ? AlphaEngineFundVault.ProtectedBatchTarget.selector
            : AlphaEngineFundVault.InvalidBatchTarget.selector;
        if (success || _selector(reason) != expected || TARGET.total() != totalBefore) {
            boundaryViolation = true;
        }
        ++preflightFailures;

        targets[count - 1] = address(TARGET);
        VAULT.executeBatch(targets, values, data);
        ghostSuccessfulTotal += count * value;
        ++successfulBatches;
    }

    /// @notice EX-12/EX-13: an allowed indirect caller gets no accounting/recovery/batch authority.
    function exerciseIndirectAuthority(uint96 rawValue) external {
        FundExecutionCallbackProbe probe = new FundExecutionCallbackProbe(VAULT);
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](2);
        targets[0] = address(TARGET);
        targets[1] = address(probe);
        data[0] = abi.encodeCall(MockFundVaultCallTarget.add, (rawValue));
        data[1] = abi.encodeCall(FundExecutionCallbackProbe.probe, ());
        VAULT.executeBatch(targets, values, data);
        ghostSuccessfulTotal += rawValue;
        ++successfulBatches;
        if (probe.checkedSelectors() != 12) boundaryViolation = true;
        ++callbackProbes;
    }

    function _selector(bytes memory revertData) private pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(revertData, 0x20))
        }
    }
}

/// @dev Test-only adversarial target; every nested call must fail with its authority error.
contract FundExecutionCallbackProbe {
    IAlphaEngineFundVault private immutable VAULT;
    uint256 public checkedSelectors;

    constructor(IAlphaEngineFundVault vault) {
        VAULT = vault;
    }

    function probe() external {
        _denied(
            abi.encodeCall(
                IAlphaEngineFundVault.settleDeposit, (address(this), address(this), 1, 1)
            ),
            AlphaEngineFundVault.UnauthorizedUSDCManager.selector
        );
        _denied(
            abi.encodeCall(IAlphaEngineFundVault.lockRedemptionShares, (address(this), 1)),
            AlphaEngineFundVault.UnauthorizedUSDCManager.selector
        );
        _denied(
            abi.encodeCall(IAlphaEngineFundVault.releaseRedemptionShares, (address(this), 1)),
            AlphaEngineFundVault.UnauthorizedUSDCManager.selector
        );
        _denied(
            abi.encodeCall(IAlphaEngineFundVault.settleRedemption, (address(this), 1, 1)),
            AlphaEngineFundVault.UnauthorizedUSDCManager.selector
        );
        _denied(
            abi.encodeCall(IAlphaEngineFundVault.mintFeeShares, (address(this), 1)),
            AlphaEngineFundVault.UnauthorizedUSDCManager.selector
        );
        _denied(
            abi.encodeCall(IAlphaEngineFundVault.recoverAsset, (IERC20(VAULT.usdc()))),
            AlphaEngineFundVault.UnauthorizedEmergencyAuthority.selector
        );
        _denied(
            abi.encodeCall(
                IAlphaEngineFundVault.executeBatch,
                (new address[](0), new uint256[](0), new bytes[](0))
            ),
            AlphaEngineFundVault.UnauthorizedExecutionManager.selector
        );
        _denied(
            abi.encodeCall(AlphaEngineFundVault.setUsdcManager, (address(this))),
            Ownable.OwnableUnauthorizedAccount.selector
        );
        _denied(
            abi.encodeCall(IAlphaEngineFundVault.setExecutionManager, (address(this))),
            Ownable.OwnableUnauthorizedAccount.selector
        );
        _denied(
            abi.encodeCall(
                IAlphaEngineFundVault.setEmergencyConfiguration, (address(this), address(this))
            ),
            Ownable.OwnableUnauthorizedAccount.selector
        );
        _denied(
            abi.encodeCall(AlphaEngineFundVault.pause, ()),
            AlphaEngineFundVault.UnauthorizedPauser.selector
        );
        _denied(
            abi.encodeCall(AlphaEngineFundVault.unpause, ()),
            Ownable.OwnableUnauthorizedAccount.selector
        );
    }

    function _denied(bytes memory data, bytes4 expected) private {
        (bool success, bytes memory reason) = address(VAULT).call(data);
        assert(!success && reason.length >= 4 && bytes4(reason) == expected);
        ++checkedSelectors;
    }
}
