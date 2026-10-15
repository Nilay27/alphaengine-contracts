// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {
    IAlphaEngineCapitalStrategyManager
} from "src/interfaces/IAlphaEngineCapitalStrategyManager.sol";
import {
    IAlphaEngineTraderQualificationRegistry
} from "src/interfaces/IAlphaEngineTraderQualificationRegistry.sol";
import {AlphaEngineExecutionHashLib} from "src/libraries/AlphaEngineExecutionHashLib.sol";
import {
    AlphaEngineCapitalStrategyManager
} from "src/strategy/AlphaEngineCapitalStrategyManager.sol";
import {
    AlphaEngineTraderQualificationRegistry
} from "src/strategy/AlphaEngineTraderQualificationRegistry.sol";
import {CapitalManagerInvariantHandler} from "test/handlers/CapitalManagerInvariantHandler.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockFundVault, MockVaultExecutionManager} from "test/mocks/MockVaultExecutionManager.sol";

contract AlphaEngineCapitalStrategyManagerInvariantTest is StdInvariant, MockCoFheTest {
    AlphaEngineTraderQualificationRegistry private registry;
    AlphaEngineCapitalStrategyManager private manager;
    MockVaultExecutionManager private executionManager;
    MockFundVault private fundVault;
    CapitalManagerInvariantHandler private handler;

    address private admin = makeAddr("admin");
    address private pauser = makeAddr("pauser");
    address private revoker = makeAddr("revoker");
    address private operator = makeAddr("operator");

    function setUp() public {
        _installMockTaskManager();
        registry = _deployRegistry();
        manager = _deployManager();
        executionManager =
            new MockVaultExecutionManager(IAlphaEngineCapitalStrategyManager(address(manager)));
        fundVault = new MockFundVault();
        handler = new CapitalManagerInvariantHandler(
            manager, registry, executionManager, fundVault, admin, pauser
        );

        vm.startPrank(admin);
        registry.grantRole(registry.QUALIFICATION_ISSUER_ROLE(), address(handler));
        registry.grantRole(registry.QUALIFICATION_REVOKER_ROLE(), address(handler));
        manager.grantRole(manager.EVALUATOR_ROLE(), address(handler));
        manager.grantRole(manager.REVOCER_ROLE(), address(handler));
        manager.setExecutionManagerAuthorization(address(executionManager), true);
        registry.unpause();
        manager.unpause();
        vm.stopPrank();

        for (uint256 index = 0; index < handler.TRADER_COUNT(); ++index) {
            address trader = handler.traderAt(index);
            vm.prank(address(handler));
            registry.qualifyTrader(
                trader,
                uint40(block.timestamp) + 30 days,
                keccak256(abi.encode("competition", trader)),
                keccak256(abi.encode("qualification", trader))
            );
        }

        // Every campaign exercises rollback, consumption and both qualification gates.
        handler.submit(0, 1, 1);
        handler.approve(0, 1);
        handler.attemptFailingConsume(0);
        handler.consume(0);
        handler.submit(1, 2, 2);
        handler.approve(1, 2);
        handler.revokeQualification(1);
        handler.attemptInvalidQualificationProgress(1, 2);
        handler.submit(2, 3, 3);
        handler.revokeQualification(2);
        handler.attemptInvalidQualificationProgress(2, 3);
        handler.requalify(1, 30 days);
        handler.requalify(2, 30 days);
        // QC-04/05/07/08/09/10/11/13/15: seed genuine critical prestates, then randomize the same actions.
        handler.attemptTerminalProgress(0);
        handler.submit(3, 4, 4);
        handler.approveFuture(3, 4, 100);
        handler.consumeAtBoundary(3, 0);
        handler.consumeAtBoundary(3, 1);
        handler.submit(0, 5, 5);
        handler.approve(4, 5);
        for (uint8 field; field < 19; ++field) {
            handler.attemptMutatedConsume(4, field);
        }
        handler.governanceCycle(4, 2);
        handler.consume(4);
        handler.submit(0, 6, 6);
        handler.approve(5, 6);
        handler.governanceCycle(5, 1);
        handler.submit(1, 7, 7);
        handler.governanceCycle(6, 0);
        handler.submit(3, 8, 8);
        handler.approveFuture(7, 8, 1);
        handler.consumeAtBoundary(7, 3);
        handler.expire(7);
        handler.submit(0, 9, 9);
        handler.upgradeCycle();
        handler.registryGovernanceCycle(8);

        bytes4[] memory selectors = new bytes4[](20);
        selectors[0] = handler.submit.selector;
        selectors[1] = handler.cancel.selector;
        selectors[2] = handler.reject.selector;
        selectors[3] = handler.approve.selector;
        selectors[4] = handler.consume.selector;
        selectors[5] = handler.attemptFailingConsume.selector;
        selectors[6] = handler.expire.selector;
        selectors[7] = handler.revokeQualification.selector;
        selectors[8] = handler.requalify.selector;
        selectors[9] = handler.attemptInvalidQualificationProgress.selector;
        selectors[10] = handler.attemptTerminalProgress.selector;
        selectors[11] = handler.approveFuture.selector;
        selectors[12] = handler.consumeAtBoundary.selector;
        selectors[13] = handler.attemptMutatedConsume.selector;
        selectors[14] = handler.governanceCycle.selector;
        selectors[15] = handler.upgradeCycle.selector;
        selectors[16] = handler.advanceTime.selector;
        selectors[17] = handler.registryGovernanceCycle.selector;
        selectors[18] = handler.expireWhilePaused.selector;
        selectors[19] = handler.qualificationExpiryCycle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_adversarialLifecycleWitnessesAndRecordedPermissions() public view {
        assertGt(handler.terminalRejections(), 0);
        assertGt(handler.mutatedAuthorizationRejections(), 0);
        assertGt(handler.timeBoundaryChecks(), 0);
        assertGt(handler.governanceChecks(), 0);
        assertGt(handler.upgradeChecks(), 0);
        for (uint256 i; i < handler.intentCount(); ++i) {
            bytes32 id = handler.intentAt(i);
            AlphaEngineCapitalStrategyManager.CapitalIntentIdentity memory identity =
                manager.getCapitalIntentIdentity(id);
            assertTrue(
                taskManager.isAllowed(
                    uint256(identity.marketIdHandle), identity.operatorAtSubmission
                )
            );
            assertTrue(taskManager.isAllowed(uint256(identity.marketIdHandle), address(manager)));
            bytes32[] memory components = manager.getCapitalIntentComponents(id);
            for (uint256 j; j < components.length; ++j) {
                assertTrue(
                    taskManager.isAllowed(uint256(components[j]), identity.operatorAtSubmission)
                );
                assertTrue(taskManager.isAllowed(uint256(components[j]), address(manager)));
            }
        }
    }

    function invariant_nonceEqualsSuccessfulCapitalSubmissions() public view {
        for (uint256 index = 0; index < handler.TRADER_COUNT(); ++index) {
            address trader = handler.traderAt(index);
            assertEq(manager.traderNonces(trader), handler.successfulSubmissions(trader));
        }
    }

    function invariant_intentPayloadAndComponentStateRemainConsistent() public view {
        uint256 length = handler.intentCount();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.intentAt(index);
            AlphaEngineCapitalStrategyManager.CapitalIntentIdentity memory identity =
                manager.getCapitalIntentIdentity(intentId);
            AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
                manager.getCapitalIntentState(intentId);
            assertTrue(manager.existsCapitalIntent(intentId));
            assertNotEq(identity.trader, address(0));
            assertNotEq(identity.operatorAtSubmission, address(0));
            assertNotEq(identity.payloadHash, bytes32(0));
            assertEq(manager.getCapitalIntentComponents(intentId).length, state.componentCount);
            assertEq(state.qualificationVersion, handler.submittedQualificationVersion(intentId));
        }
    }

    function invariant_terminalCapitalStatesNeverChange() public view {
        assertFalse(handler.terminalStateChanged());
    }

    function invariant_approvalsAreImmutableAndAuthorizationNoncesAreUnique() public view {
        assertFalse(handler.duplicateAuthorizationNonce());
        assertEq(manager.nextAuthorizationNonce(), handler.successfulApprovals());

        uint256 length = handler.intentCount();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.intentAt(index);
            bytes32 commitment = handler.observedCommitment(intentId);
            if (commitment == bytes32(0)) continue;

            AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
                manager.getCapitalIntentState(intentId);
            AlphaEngineExecutionHashLib.ExecutionCommitmentV1 memory authorization =
                handler.authorizationFor(intentId);
            assertEq(manager.getApprovedExecutionCommitment(intentId), commitment);
            assertEq(AlphaEngineExecutionHashLib.hashExecutionCommitment(authorization), commitment);
            assertEq(manager.intentByAuthorizationNonce(state.authorizationNonce), intentId);
            assertEq(handler.observedIntentByAuthorizationNonce(state.authorizationNonce), intentId);
            assertEq(state.authorizationNonce, authorization.authorizationNonce);
            assertEq(state.authorizationDeadline, authorization.deadline);
            assertLe(authorization.deadline, state.deadline);
            assertLe(
                authorization.deadline - authorization.validAfter,
                manager.MAX_AUTHORIZATION_WINDOW()
            );
        }
    }

    function invariant_consumptionAndReplayStateStayInParity() public view {
        assertFalse(handler.downstreamRollbackViolation());
        assertGt(handler.verifiedRollbacks(), 0);
        assertGt(handler.successfulConsumptions(), 0);
        uint256 length = handler.intentCount();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.intentAt(index);
            bytes32 commitment = handler.observedCommitment(intentId);
            if (commitment == bytes32(0)) continue;
            AlphaEngineCapitalStrategyManager.CapitalIntentState memory state =
                manager.getCapitalIntentState(intentId);
            bool consumed =
                state.status == AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Consumed;
            assertEq(manager.isExecutionConsumed(commitment), consumed);
            assertEq(manager.consumedAuthorizationNonces(state.authorizationNonce), consumed);
        }
    }

    function invariant_supersededQualificationNeverAuthorizesOldIntent() public view {
        assertFalse(handler.invalidQualificationProgressed());
        assertGt(handler.rejectedQualificationApprovals(), 0);
        assertGt(handler.rejectedQualificationConsumptions(), 0);
        uint256 length = handler.intentCount();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.intentAt(index);
            AlphaEngineCapitalStrategyManager.CapitalIntentIdentity memory identity =
                manager.getCapitalIntentIdentity(intentId);
            uint64 submittedVersion = handler.submittedQualificationVersion(intentId);
            IAlphaEngineTraderQualificationRegistry.Qualification memory currentQualification =
                registry.getQualification(identity.trader);
            if (currentQualification.version != submittedVersion) {
                assertFalse(registry.isQualifiedAtVersion(identity.trader, submittedVersion));
            }
        }
    }

    function invariant_managerHasNoNativeCustody() public view {
        assertEq(address(manager).balance, 0);
    }

    /// @dev QC-04/QC-05/QC-06: approvals remain independently consumable in a different order, with rollback and replay attempts.
    function testFuzz_QC_multipleIntentsOutOfOrderConsumptionAndRetry(
        uint128 market,
        uint128 component
    ) public {
        uint256 first = handler.intentCount();
        handler.submit(0, market, component);
        handler.submit(0, market, component);
        assertEq(handler.intentCount(), first + 2);
        handler.approve(first, uint32(component));
        handler.approve(first + 1, uint32(market));
        handler.attemptFailingConsume(first);
        handler.consume(first + 1);
        handler.attemptTerminalProgress(first + 1);
        handler.consume(first);
        handler.attemptTerminalProgress(first);
        _assertAllProperties();
    }

    /// @dev QC-07/QC-08: validAfter is inclusive; deadline is exclusive; rejected expiry cannot consume state.
    function testFuzz_QC_futureStartDeadlineAndPausedExpiry(uint16 delay, bool beforeDeadline)
        public
    {
        uint256 first = handler.intentCount();
        handler.submit(3, 1, 1);
        handler.approveFuture(first, 1, delay);
        uint256 checksBefore = handler.timeBoundaryChecks();
        handler.consumeAtBoundary(first, 0);
        handler.consumeAtBoundary(first, beforeDeadline ? 2 : 1);
        assertEq(handler.timeBoundaryChecks(), checksBefore + 2);
        assertEq(
            uint8(manager.getCapitalIntentState(handler.intentAt(first)).status),
            uint8(AlphaEngineCapitalStrategyManager.CapitalIntentStatus.Consumed)
        );
        uint256 second = handler.intentCount();
        handler.submit(3, 2, 2);
        handler.approveFuture(second, 2, delay);
        handler.consumeAtBoundary(second, 3);
        handler.expireWhilePaused(second);
        _assertAllProperties();
    }

    /// @dev QC-09/QC-10/QC-11: recorded input access survives operator/role/manager rotation; new inputs use new authority.
    function testFuzz_QC_operatorAndManagerRotationWithOldAndFreshRecords(
        uint128 market,
        uint128 component
    ) public {
        uint256 first = handler.intentCount();
        handler.submit(0, market, component);
        bytes32 firstId = handler.intentAt(first);
        address oldOperator = manager.getCapitalIntentIdentity(firstId).operatorAtSubmission;
        handler.governanceCycle(first, 2);
        handler.submit(0, market, component);
        assertEq(manager.getCapitalIntentIdentity(firstId).operatorAtSubmission, oldOperator);
        assertNotEq(
            manager.getCapitalIntentIdentity(handler.intentAt(first + 1)).operatorAtSubmission,
            oldOperator
        );
        handler.approve(first, 1);
        handler.approve(first + 1, 2);
        handler.governanceCycle(first, 2);
        handler.consume(first + 1);
        handler.registryGovernanceCycle(first);
        handler.attemptInvalidQualificationProgress(first, 1);
        handler.upgradeCycle();
        _assertAllProperties();
    }

    function testFuzz_QC_exactQualificationExpiryCannotReviveOldApproval(uint16 delta) public {
        handler.qualificationExpiryCycle(0, delta);
        handler.qualificationExpiryCycle(0, delta);
        _assertAllProperties();
    }

    function _assertAllProperties() private view {
        invariant_nonceEqualsSuccessfulCapitalSubmissions();
        invariant_intentPayloadAndComponentStateRemainConsistent();
        invariant_terminalCapitalStatesNeverChange();
        invariant_approvalsAreImmutableAndAuthorizationNoncesAreUnique();
        invariant_consumptionAndReplayStateStayInParity();
        invariant_supersededQualificationNeverAuthorizesOldIntent();
        invariant_adversarialLifecycleWitnessesAndRecordedPermissions();
    }

    function _deployRegistry() private returns (AlphaEngineTraderQualificationRegistry deployed) {
        AlphaEngineTraderQualificationRegistry implementation =
            new AlphaEngineTraderQualificationRegistry();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin,
            abi.encodeCall(
                AlphaEngineTraderQualificationRegistry.initialize, (admin, pauser, revoker)
            )
        );
        return AlphaEngineTraderQualificationRegistry(address(proxy));
    }

    function _deployManager() private returns (AlphaEngineCapitalStrategyManager deployed) {
        AlphaEngineCapitalStrategyManager implementation = new AlphaEngineCapitalStrategyManager();
        AlphaEngineCapitalStrategyManager.InitializationParams memory params =
            AlphaEngineCapitalStrategyManager.InitializationParams({
                initialDefaultAdmin: admin,
                initialPauser: pauser,
                initialFheOperator: operator,
                qualificationRegistry: address(registry)
            });
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin,
            abi.encodeCall(AlphaEngineCapitalStrategyManager.initialize, (params))
        );
        return AlphaEngineCapitalStrategyManager(address(proxy));
    }
}
