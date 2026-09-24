// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    FHE,
    euint64,
    sharedEuint64,
    externalEuint64
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockCoFheTaskManager} from "test/mocks/MockCoFheTaskManager.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
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
        euint64 second = FHE.receiveEuint64FromCall(
            wrapper.unshield(address(this), address(this), uint64(10e6)), address(wrapper)
        );
        bytes32 secondId = wrapper.latestUnshieldClaimId(address(this));
        assertNotEq(firstId, secondId);
        assertNotEq(firstId, FHE.unwrap(first));
        assertEq(wrapper.getClaim(firstId).ctHash, FHE.unwrap(first));
        assertEq(wrapper.getClaim(secondId).ctHash, FHE.unwrap(second));
        taskManager.publishDecryptResult(uint256(FHE.unwrap(first)), 10e6, "");
        taskManager.publishDecryptResult(uint256(FHE.unwrap(second)), 10e6, "");
        vm.expectRevert(FHERC20WrapperClaims.ClaimNotFound.selector);
        wrapper.claimUnshielded(FHE.unwrap(first), 10e6, "");
        wrapper.claimUnshielded(secondId, 10e6, "");
        assertFalse(wrapper.getClaim(firstId).claimed);
        wrapper.claimUnshielded(firstId, 10e6, "");
        assertTrue(wrapper.getClaim(firstId).claimed);
        assertTrue(wrapper.getClaim(secondId).claimed);
        assertEq(underlying.balanceOf(address(this)), 20e6);
        assertEq(underlying.balanceOf(address(wrapper)), 80e6);
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
