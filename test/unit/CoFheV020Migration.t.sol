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
    FHERC20ZeroBalance,
    FHERC20UnauthorizedSpender
} from "fhenix-confidential-contracts/FHERC20/utils/FHERC20Errors.sol";
import {
    FHERC20WrapperClaims
} from "fhenix-confidential-contracts/FHERC20/utils/FHERC20WrapperClaims.sol";

import {
    AlphaEngineConfidentialAssetRegistry
} from "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";

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
    AlphaEngineConfidentialAssetRegistry private registry;

    function setUp() public {
        _installMockTaskManager();
        underlying = new MockERC20("USD Coin", "USDC", 6);
        registry = _deployAssetRegistry(address(this));
        wrapper = AlphaEngineFHERC20ERC20Wrapper(
            registry.createWrapper(address(underlying), "Encrypted USD Coin", "eUSDC", "")
        );
        registry.setWrapperMinimums(address(wrapper), 1e6, 1000);
        underlying.mint(address(this), 100e6);
        underlying.approve(address(wrapper), 100e6);
        FHE.receiveEuint64FromCall(wrapper.shield(address(this), 100e6), address(wrapper));
    }

    function test_uninitializedFullExitRollsBackAdmissionAndCooldown() public {
        address empty = makeAddr("never-shielded");
        uint16 tokens = registry.availableUnshieldTokens();
        vm.prank(empty);
        vm.expectRevert(abi.encodeWithSelector(FHERC20ZeroBalance.selector, empty));
        wrapper.unshieldAll(empty);
        assertEq(registry.availableUnshieldTokens(), tokens);
        assertEq(wrapper.unshieldCooldownUntil(empty), 0);
        assertEq(wrapper.pendingUnshieldClaimId(empty), bytes32(0));
    }

    function test_fullExitOfInitializedZeroCompletesAndRestartsCooldown() public {
        wrapper.unshieldAll(address(this));
        bytes32 first = wrapper.pendingUnshieldClaimId(address(this));
        taskManager.publishDecryptResult(uint256(wrapper.getClaim(first).ctHash), 100e6, "");
        wrapper.claimUnshielded(first, 100e6, "");
        vm.warp(wrapper.unshieldCooldownUntil(address(this)));
        wrapper.unshieldAll(address(this));
        bytes32 second = wrapper.pendingUnshieldClaimId(address(this));
        assertEq(mockStorage(uint256(wrapper.getClaim(second).ctHash)), 0);
        vm.warp(block.timestamp + 30);
        taskManager.publishDecryptResult(uint256(wrapper.getClaim(second).ctHash), 0, "");
        wrapper.claimUnshielded(second, 0, "");
        assertEq(wrapper.pendingUnshieldClaimId(address(this)), bytes32(0));
        assertEq(wrapper.unshieldCooldownUntil(address(this)), block.timestamp + 5 minutes);
        assertEq(underlying.balanceOf(address(this)), 100e6);
    }

    function test_budgetPolicyChangeAccruesOldRateWithoutResettingCredit() public {
        registry.setUnshieldRateLimits(1, 1);
        wrapper.unshield(address(this), address(this), uint64(1000));
        registry.setUnshieldRateLimits(2, 10);
        assertEq(registry.availableUnshieldTokens(), 0);
        vm.warp(block.timestamp + 3);
        registry.setUnshieldRateLimits(3, 10);
        assertEq(registry.availableUnshieldTokens(), 6);
        assertEq(registry.unshieldTokensUpdatedAt(), block.timestamp);
        registry.setUnshieldRateLimits(1, 2);
        assertEq(registry.availableUnshieldTokens(), 2);
    }

    function test_encryptedMinimumAndBalanceBoundariesPreserveFunds() public {
        uint64[6] memory amounts = [uint64(0), 999, 1000, 1e6, 100e6, type(uint64).max];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 beforeBalance =
                mockStorage(uint256(FHE.unwrap(wrapper.confidentialBalanceOf(address(this)))));
            uint64 expected = amounts[i] >= 1000 && amounts[i] <= beforeBalance ? amounts[i] : 0;
            euint64 encrypted = FHE.asEuint64(amounts[i]);
            euint64 actual = FHE.receiveEuint64FromCall(
                wrapper.unshield(
                    address(this), address(this), FHE.shareEuint64(encrypted, address(wrapper))
                ),
                address(wrapper)
            );
            assertEq(mockStorage(uint256(FHE.unwrap(actual))), expected);
            assertEq(
                mockStorage(uint256(FHE.unwrap(wrapper.confidentialBalanceOf(address(this))))),
                beforeBalance - expected
            );
            bytes32 id = wrapper.pendingUnshieldClaimId(address(this));
            taskManager.publishDecryptResult(uint256(FHE.unwrap(actual)), expected, "");
            wrapper.claimUnshielded(id, expected, "");
            if (expected == 0) vm.warp(wrapper.unshieldCooldownUntil(address(this)));
        }
    }

    function testFuzz_encryptedMinimumUsesActualBalance(uint64 amount) public {
        euint64 encrypted = FHE.asEuint64(amount);
        euint64 actual = FHE.receiveEuint64FromCall(
            wrapper.unshield(
                address(this), address(this), FHE.shareEuint64(encrypted, address(wrapper))
            ),
            address(wrapper)
        );
        uint64 expected = amount >= 1000 && amount <= 100e6 ? amount : 0;
        assertEq(mockStorage(uint256(FHE.unwrap(actual))), expected);
        assertEq(
            mockStorage(uint256(FHE.unwrap(wrapper.confidentialBalanceOf(address(this))))),
            100e6 - expected
        );
    }

    function test_zeroClaimCooldownUsesSourceAndCannotBeForged() public {
        address recipient = makeAddr("zero-recipient");
        wrapper.unshield(address(this), recipient, uint64(101e6));
        bytes32 id = wrapper.pendingUnshieldClaimId(address(this));
        taskManager.publishDecryptResult(uint256(wrapper.getClaim(id).ctHash), 0, "");
        vm.expectRevert(
            abi.encodeWithSelector(
                MockCoFheTaskManager.InvalidDecryptResult.selector,
                uint256(wrapper.getClaim(id).ctHash),
                0,
                1
            )
        );
        wrapper.claimUnshielded(id, 1, "");
        assertEq(wrapper.unshieldCooldownUntil(address(this)), 0);
        assertEq(wrapper.pendingUnshieldClaimId(address(this)), id);
        vm.expectEmit(true, false, false, true, address(wrapper));
        emit AlphaEngineFHERC20ERC20Wrapper.UnshieldCooldownStarted(
            address(this), uint40(block.timestamp + 5 minutes)
        );
        vm.prank(recipient);
        wrapper.claimUnshielded(id, 0, "");
        uint40 until = wrapper.unshieldCooldownUntil(address(this));
        assertEq(until, block.timestamp + 5 minutes);
        assertEq(wrapper.unshieldCooldownUntil(recipient), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.UnshieldCooldownActive.selector, address(this), until
            )
        );
        wrapper.unshield(address(this), address(this), uint64(1000));
        euint64 amount = FHE.asEuint64(1000);
        sharedEuint64 shared = FHE.shareEuint64(amount, address(wrapper));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.UnshieldCooldownActive.selector, address(this), until
            )
        );
        wrapper.unshield(address(this), address(this), shared);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.UnshieldCooldownActive.selector, address(this), until
            )
        );
        wrapper.unshieldAll(address(this));
        vm.warp(until - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.UnshieldCooldownActive.selector, address(this), until
            )
        );
        wrapper.unshield(address(this), address(this), uint64(1000));
        vm.warp(until);
        wrapper.unshield(address(this), address(this), uint64(1000));
    }

    function test_fullBalanceExitPaysDustAndLeavesLaterDepositsUntouched() public {
        address account = makeAddr("dust-owner");
        underlying.mint(address(this), 999 + 1e6);
        underlying.approve(address(wrapper), 999 + 1e6);
        wrapper.shield(account, 999);
        vm.prank(account);
        vm.recordLogs();
        wrapper.unshieldAll(account);
        bytes32 id = wrapper.pendingUnshieldClaimId(account);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawFullExit;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(wrapper)
                    && logs[i].topics[0]
                        == keccak256("FullBalanceUnshieldRequested(address,address,bytes32)")
            ) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(account))));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(account))));
                assertEq(abi.decode(logs[i].data, (bytes32)), id);
                sawFullExit = true;
            }
        }
        assertTrue(sawFullExit);
        assertEq(mockStorage(uint256(FHE.unwrap(wrapper.confidentialBalanceOf(account)))), 0);
        wrapper.shield(account, 1e6);
        taskManager.publishDecryptResult(uint256(wrapper.getClaim(id).ctHash), 999, "");
        registry.setWrapperMinimums(address(wrapper), 2e6, 2e6);
        wrapper.claimUnshielded(id, 999, "");
        assertEq(underlying.balanceOf(account), 999);
        assertEq(mockStorage(uint256(FHE.unwrap(wrapper.confidentialBalanceOf(account)))), 1e6);
        uint40 until = wrapper.unshieldCooldownUntil(account);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.UnshieldCooldownActive.selector, account, until
            )
        );
        wrapper.unshieldAll(account);
        vm.warp(until);
        vm.prank(account);
        wrapper.unshieldAll(account);
    }

    function test_batchZeroClaimAppliesCooldownOnlyToZeroSource() public {
        address other = makeAddr("batch-success");
        underlying.mint(address(this), 1e6);
        underlying.approve(address(wrapper), 1e6);
        wrapper.shield(other, 1e6);
        wrapper.unshield(address(this), other, uint64(101e6));
        bytes32 first = wrapper.pendingUnshieldClaimId(address(this));
        vm.prank(other);
        wrapper.unshield(other, address(this), uint64(1e6));
        bytes32 second = wrapper.pendingUnshieldClaimId(other);
        taskManager.publishDecryptResult(uint256(wrapper.getClaim(first).ctHash), 0, "");
        taskManager.publishDecryptResult(uint256(wrapper.getClaim(second).ctHash), 1e6, "");
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = first;
        ids[1] = second;
        uint64[] memory amounts = new uint64[](2);
        amounts[1] = 1e6;
        wrapper.claimUnshieldedBatch(ids, amounts, new bytes[](2));
        assertEq(wrapper.unshieldCooldownUntil(address(this)), block.timestamp + 5 minutes);
        assertEq(wrapper.unshieldCooldownUntil(other), 0);
        assertEq(wrapper.pendingUnshieldClaimId(address(this)), bytes32(0));
        assertEq(wrapper.pendingUnshieldClaimId(other), bytes32(0));
    }

    function test_unshieldBudgetIsSharedAcrossAssetsAndDoesNotBlockExistingClaims() public {
        MockERC20 secondToken = new MockERC20("Wrapped Ether", "WETH", 18);
        AlphaEngineFHERC20ERC20Wrapper second = AlphaEngineFHERC20ERC20Wrapper(
            registry.createWrapper(address(secondToken), "Encrypted Ether", "eWETH", "")
        );
        registry.setWrapperMinimums(address(second), 100, 10);
        assertEq(wrapper.minimumUnshieldAmount(), 1000);
        assertEq(second.minimumUnshieldAmount(), 10);
        secondToken.mint(address(this), 1e18);
        secondToken.approve(address(second), 1e18);
        second.shield(address(this), 1e18);
        vm.expectEmit(false, false, false, true, address(registry));
        emit AlphaEngineConfidentialAssetRegistry.UnshieldRateLimitsUpdated(1, 1);
        registry.setUnshieldRateLimits(1, 1);
        vm.expectEmit(true, false, false, true, address(registry));
        emit AlphaEngineConfidentialAssetRegistry.UnshieldAdmissionConsumed(address(wrapper), 0);
        wrapper.unshield(address(this), address(this), uint64(1000));
        bytes32 id = wrapper.pendingUnshieldClaimId(address(this));
        uint256 tasks = taskManager.taskCreationCount();
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.UnshieldRateLimitExceeded.selector,
                block.timestamp + 1
            )
        );
        second.unshield(address(this), address(this), uint64(10));
        assertEq(taskManager.taskCreationCount(), tasks);
        assertEq(second.pendingUnshieldClaimId(address(this)), bytes32(0));
        taskManager.publishDecryptResult(uint256(wrapper.getClaim(id).ctHash), 1000, "");
        wrapper.claimUnshielded(id, 1000, "");
        vm.warp(block.timestamp + 1);
        second.unshield(address(this), address(this), uint64(10));
        assertEq(registry.availableUnshieldTokens(), 0);
    }

    function test_partialUnshieldRequiresPolicyButFullExitRemainsAvailable() public {
        MockERC20 token = new MockERC20("Unconfigured", "UNC", 6);
        AlphaEngineFHERC20ERC20Wrapper unconfigured = AlphaEngineFHERC20ERC20Wrapper(
            registry.createWrapper(address(token), "Encrypted", "eUNC", "")
        );
        token.mint(address(this), 7);
        token.approve(address(unconfigured), 7);
        unconfigured.shield(address(this), 7);
        vm.expectRevert(AlphaEngineFHERC20ERC20Wrapper.UnshieldMinimumNotConfigured.selector);
        unconfigured.unshield(address(this), address(this), uint64(7));
        euint64 amount = FHE.asEuint64(7);
        sharedEuint64 shared = FHE.shareEuint64(amount, address(unconfigured));
        uint16 budget = registry.availableUnshieldTokens();
        vm.expectRevert(AlphaEngineFHERC20ERC20Wrapper.UnshieldMinimumNotConfigured.selector);
        unconfigured.unshield(address(this), address(this), shared);
        assertEq(registry.availableUnshieldTokens(), budget);
        unconfigured.unshieldAll(address(this));
        bytes32 id = unconfigured.pendingUnshieldClaimId(address(this));
        taskManager.publishDecryptResult(uint256(unconfigured.getClaim(id).ctHash), 7, "");
        unconfigured.claimUnshielded(id, 7, "");
        assertEq(token.balanceOf(address(this)), 7);
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
        AlphaEngineFHERC20ERC20Wrapper guarded = AlphaEngineFHERC20ERC20Wrapper(
            registry.createWrapper(address(zeroRejecting), "Encrypted ZR", "eZR", "")
        );
        registry.setWrapperMinimums(address(guarded), 1e6, 1000);
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
