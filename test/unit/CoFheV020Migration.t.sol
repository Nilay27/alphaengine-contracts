// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {
    FHE,
    euint64,
    sharedEuint64,
    externalEuint64
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockCoFheTaskManager} from "test/mocks/MockCoFheTaskManager.sol";
import {MockERC20, MockZeroTransferRevertingERC20} from "test/mocks/MockERC20.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {
    FHERC20InvalidReceiver,
    FHERC20UnauthorizedSpender
} from "fhenix-confidential-contracts/FHERC20/utils/FHERC20Errors.sol";
import {
    FHERC20WrapperClaims
} from "fhenix-confidential-contracts/FHERC20/utils/FHERC20WrapperClaims.sol";

contract CoFheShareReceiver {
    function receiveAmount(sharedEuint64 amount) external returns (euint64) {
        euint64 received = FHE.receiveEuint64Param(amount);
        FHE.allowThis(received);
        return received;
    }
}

contract CoFheV020MigrationTest is MockCoFheTest {
    AlphaEngineFHERC20ERC20Wrapper private wrapper;
    MockERC20 private underlying;

    function setUp() public {
        _installMockTaskManager();
        underlying = new MockERC20("USD Coin", "USDC", 6);
        wrapper = new AlphaEngineFHERC20ERC20Wrapper(underlying, "Encrypted USD Coin", "eUSDC", "");
        underlying.mint(address(this), 100e6);
        underlying.approve(address(wrapper), 100e6);
        FHE.receiveEuint64FromCall(wrapper.shield(address(this), 100e6), address(wrapper));
    }

    function test_aclAllowanceAloneCannotSubstituteForAnUnshieldShare() public {
        euint64 amount = FHE.asEuint64(10e6);
        FHE.allow(amount, address(wrapper));
        vm.expectRevert(
            abi.encodeWithSelector(
                MockCoFheTaskManager.NotShared.selector,
                uint256(FHE.unwrap(amount)),
                address(wrapper)
            )
        );
        wrapper.unshield(address(this), address(this), sharedEuint64.wrap(FHE.unwrap(amount)));
        assertEq(wrapper.latestUnshieldClaimId(address(this)), bytes32(0));
    }

    function test_claimIdAdapterPreservesRecipientAndOperatorValidation() public {
        vm.expectRevert(abi.encodeWithSelector(FHERC20InvalidReceiver.selector, address(0)));
        wrapper.unshield(address(this), address(0), uint64(10e6));

        address stranger = makeAddr("unauthorized-unshield-caller");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(FHERC20UnauthorizedSpender.selector, address(this), stranger)
        );
        wrapper.unshield(address(this), stranger, uint64(10e6));
        assertEq(wrapper.latestUnshieldClaimId(address(this)), bytes32(0));
        assertEq(wrapper.latestUnshieldClaimId(stranger), bytes32(0));
        assertEq(
            mockStorage(uint256(FHE.unwrap(wrapper.confidentialBalanceOf(address(this))))), 100e6
        );
    }

    function test_shareIsDirectedAuthenticatedAndConsumedOnce() public {
        CoFheShareReceiver receiver = new CoFheShareReceiver();
        euint64 amount = FHE.asEuint64(7);
        sharedEuint64 sharedAmount = FHE.shareEuint64(amount, address(receiver));
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockCoFheTaskManager.UnexpectedSharer.selector, stranger, address(this)
            )
        );
        receiver.receiveAmount(sharedAmount);
        euint64 received = receiver.receiveAmount(sharedAmount);
        assertEq(FHE.unwrap(received), FHE.unwrap(amount));
        assertTrue(FHE.isAllowed(received, address(receiver)));
        vm.expectRevert(
            abi.encodeWithSelector(
                MockCoFheTaskManager.NotShared.selector,
                uint256(FHE.unwrap(amount)),
                address(receiver)
            )
        );
        receiver.receiveAmount(sharedAmount);
    }

    function test_claimIdsRemainIndependentAndCiphertextIsNotAClaimId() public {
        euint64 first = FHE.receiveEuint64FromCall(
            wrapper.unshield(address(this), address(this), uint64(10e6)), address(wrapper)
        );
        bytes32 firstId = wrapper.latestUnshieldClaimId(address(this));
        taskManager.publishDecryptResult(uint256(FHE.unwrap(first)), 10e6, "");
        vm.expectRevert(FHERC20WrapperClaims.ClaimNotFound.selector);
        wrapper.claimUnshielded(FHE.unwrap(first), 10e6, "");
        wrapper.claimUnshielded(firstId, 10e6, "");
        euint64 second = FHE.receiveEuint64FromCall(
            wrapper.unshield(address(this), address(this), uint64(10e6)), address(wrapper)
        );
        bytes32 secondId = wrapper.latestUnshieldClaimId(address(this));
        assertNotEq(firstId, secondId);
        assertNotEq(firstId, FHE.unwrap(first));
        assertEq(wrapper.getClaim(firstId).ctHash, FHE.unwrap(first));
        assertEq(wrapper.getClaim(secondId).ctHash, FHE.unwrap(second));
        taskManager.publishDecryptResult(uint256(FHE.unwrap(second)), 10e6, "");
        wrapper.claimUnshielded(secondId, 10e6, "");
        assertTrue(wrapper.getClaim(firstId).claimed);
        assertTrue(wrapper.getClaim(secondId).claimed);
        assertEq(underlying.balanceOf(address(this)), 20e6);
        assertEq(underlying.balanceOf(address(wrapper)), 80e6);
    }

    function test_unshieldMinimumAndPendingGateAlsoCoversEncryptedHandle() public {
        assertEq(wrapper.minimumUnshieldAmount(), 1000);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.UnshieldAmountBelowMinimum.selector, 999, 1000
            )
        );
        wrapper.unshield(address(this), address(this), uint64(999));

        euint64 first = FHE.receiveEuint64FromCall(
            wrapper.unshield(address(this), address(this), uint64(10e6)), address(wrapper)
        );
        bytes32 firstId = wrapper.pendingUnshieldClaimId(address(this));
        euint64 encryptedAmount = FHE.asEuint64(10e6);
        sharedEuint64 blockedShare = FHE.shareEuint64(encryptedAmount, address(wrapper));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.PendingUnshieldClaim.selector, address(this), firstId
            )
        );
        wrapper.unshield(address(this), address(this), blockedShare);
        taskManager.publishDecryptResult(uint256(FHE.unwrap(first)), 10e6, "");
        wrapper.claimUnshielded(firstId, 10e6, "");
        assertEq(wrapper.pendingUnshieldClaimId(address(this)), bytes32(0));

        euint64 second = FHE.receiveEuint64FromCall(
            wrapper.unshield(
                address(this), address(this), FHE.shareEuint64(encryptedAmount, address(wrapper))
            ),
            address(wrapper)
        );
        bytes32 secondId = wrapper.pendingUnshieldClaimId(address(this));
        taskManager.publishDecryptResult(uint256(FHE.unwrap(second)), 10e6, "");
        wrapper.claimUnshielded(secondId, 10e6, "");
        assertEq(wrapper.pendingUnshieldClaimId(address(this)), bytes32(0));
    }

    function test_zeroBurnClaimClearsPendingEvenWhenUnderlyingRejectsZeroTransfer() public {
        MockZeroTransferRevertingERC20 zeroRejecting =
            new MockZeroTransferRevertingERC20("Zero Rejecting", "ZR", 6);
        AlphaEngineFHERC20ERC20Wrapper guarded =
            new AlphaEngineFHERC20ERC20Wrapper(zeroRejecting, "Encrypted ZR", "eZR", "");
        zeroRejecting.mint(address(this), 1e6);
        zeroRejecting.approve(address(guarded), 1e6);
        FHE.receiveEuint64FromCall(guarded.shield(address(this), 1e6), address(guarded));

        euint64 burned = FHE.receiveEuint64FromCall(
            guarded.unshield(address(this), address(this), uint64(2e6)), address(guarded)
        );
        assertEq(mockStorage(uint256(FHE.unwrap(burned))), 0);
        bytes32 claimId = guarded.pendingUnshieldClaimId(address(this));
        taskManager.publishDecryptResult(uint256(FHE.unwrap(burned)), 0, "");
        guarded.claimUnshielded(claimId, 0, "");
        assertEq(guarded.pendingUnshieldClaimId(address(this)), bytes32(0));
        assertTrue(guarded.getClaim(claimId).claimed);
        assertEq(zeroRejecting.balanceOf(address(guarded)), 1e6);
    }

    function test_batchClaimClearsEachSourceAccountPendingGate() public {
        address secondAccount = makeAddr("second-unshield-source");
        underlying.mint(address(this), 10e6);
        underlying.approve(address(wrapper), 10e6);
        FHE.receiveEuint64FromCall(wrapper.shield(secondAccount, 10e6), address(wrapper));

        wrapper.unshield(address(this), address(this), uint64(10e6));
        bytes32 firstId = wrapper.pendingUnshieldClaimId(address(this));
        vm.prank(secondAccount);
        wrapper.unshield(secondAccount, secondAccount, uint64(10e6));
        bytes32 secondId = wrapper.pendingUnshieldClaimId(secondAccount);
        taskManager.publishDecryptResult(uint256(wrapper.getClaim(firstId).ctHash), 10e6, "");
        taskManager.publishDecryptResult(uint256(wrapper.getClaim(secondId).ctHash), 10e6, "");

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = firstId;
        ids[1] = secondId;
        uint64[] memory amounts = new uint64[](2);
        amounts[0] = 10e6;
        amounts[1] = 10e6;
        bytes[] memory proofs = new bytes[](2);
        vm.recordLogs();
        wrapper.claimUnshieldedBatch(ids, amounts, proofs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 claimEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(wrapper)
                    && logs[i].topics[0]
                        == keccak256("ClaimedUnshielded(address,bytes32,bytes32,uint64)")
            ) claimEvents += 1;
        }
        assertEq(claimEvents, 2);
        assertEq(wrapper.pendingUnshieldClaimId(address(this)), bytes32(0));
        assertEq(wrapper.pendingUnshieldClaimId(secondAccount), bytes32(0));
    }

    function test_externalTransferUsesConsumerBoundProofAndReturnsAShare() public {
        externalEuint64 input = createExternalEuint64(9e6, address(this));
        bytes memory wrongProof = _inputProof(address(this), input);
        vm.expectPartialRevert(MockCoFheTaskManager.InvalidSigner.selector);
        wrapper.confidentialTransfer(makeAddr("recipient"), input, wrongProof);
        euint64 actual = FHE.receiveEuint64FromCall(
            wrapper.confidentialTransfer(
                makeAddr("recipient"), input, _inputProof(address(wrapper), input)
            ),
            address(wrapper)
        );
        assertEq(mockStorage(uint256(FHE.unwrap(actual))), 9e6);
        assertEq(taskManager.lastBatchSize(), 1);
    }
}
