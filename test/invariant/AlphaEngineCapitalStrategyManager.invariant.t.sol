// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IAlphaEngineCapitalStrategyManager} from
    "src/interfaces/IAlphaEngineCapitalStrategyManager.sol";
import {IAlphaEngineTraderQualificationRegistry} from
    "src/interfaces/IAlphaEngineTraderQualificationRegistry.sol";
import {AlphaEngineExecutionHashLib} from "src/libraries/AlphaEngineExecutionHashLib.sol";
import {AlphaEngineCapitalStrategyManager} from "src/strategy/AlphaEngineCapitalStrategyManager.sol";
import {AlphaEngineTraderQualificationRegistry} from
    "src/strategy/AlphaEngineTraderQualificationRegistry.sol";
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
        handler = new CapitalManagerInvariantHandler(manager, registry, executionManager, fundVault);

        vm.startPrank(admin);
        registry.grantRole(registry.QUALIFICATION_ISSUER_ROLE(), address(handler));
        registry.grantRole(registry.QUALIFICATION_REVOKER_ROLE(), address(handler));
        manager.grantRole(manager.EVALUATOR_ROLE(), address(handler));
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

        bytes4[] memory selectors = new bytes4[](10);
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
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
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
