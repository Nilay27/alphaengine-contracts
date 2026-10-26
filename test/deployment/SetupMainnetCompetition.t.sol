// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SetupMainnetCompetition} from "script/SetupMainnetCompetition.s.sol";
import {
    AlphaEngineCompetitionStrategyManager as CompetitionManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
import {
    AlphaEngineTraderQualificationRegistry as QualificationRegistry
} from "src/strategy/AlphaEngineTraderQualificationRegistry.sol";

/// @dev Real call from the pinned admin avoids combining a prank with startBroadcast.
contract MainnetCompetitionAdminCaller {
    function run(SetupMainnetCompetition target) external returns (bytes32) {
        return target.run();
    }
}

/// @dev Uses pinned-address local fixtures; run with FOUNDRY_PROFILE=create2 for exact runtime hashes.
contract SetupMainnetCompetitionTest is Test {
    SetupMainnetCompetition private setupScript;
    CompetitionManager private manager;
    QualificationRegistry private registry;
    address private admin;
    address private bootstrap;
    bytes32 private constant IMPLEMENTATION_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 private constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    function setUp() public {
        vm.skip(
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default")))) != keccak256("create2")
        );
        vm.chainId(42_161);
        vm.warp(1_792_665_000);
        setupScript = new SetupMainnetCompetition();
        admin = setupScript.ADMIN();
        bootstrap = setupScript.PREVIOUS_BOOTSTRAP();
        vm.etch(admin, type(MainnetCompetitionAdminCaller).runtimeCode);
        CompetitionManager managerImpl = new CompetitionManager();
        QualificationRegistry registryImpl = new QualificationRegistry();
        // This also proves the script's deployed-code pins match this source build.
        assertEq(address(managerImpl).codehash, setupScript.MANAGER_CODE_HASH());
        assertEq(address(registryImpl).codehash, setupScript.REGISTRY_CODE_HASH());
        vm.etch(setupScript.MANAGER_IMPLEMENTATION(), address(managerImpl).code);
        vm.etch(setupScript.REGISTRY_IMPLEMENTATION(), address(registryImpl).code);
        _installProxy(setupScript.MANAGER(), setupScript.MANAGER_IMPLEMENTATION());
        _installProxy(setupScript.REGISTRY(), setupScript.REGISTRY_IMPLEMENTATION());
        manager = CompetitionManager(setupScript.MANAGER());
        registry = QualificationRegistry(setupScript.REGISTRY());
        registry.initialize(admin, bootstrap, bootstrap);
        manager.initialize(
            CompetitionManager.InitializationParams({
                initialDefaultAdmin: admin,
                initialPauser: bootstrap,
                initialFheOperator: bootstrap,
                qualificationRegistry: address(registry)
            })
        );
        vm.etch(setupScript.TASK_MANAGER(), hex"00");
        _mockAdmission(true);
    }

    function test_runGrantsRevokesUnpausesBothAndCreatesActiveCompetition() public {
        vm.recordLogs();
        bytes32 id = _run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 granted;
        uint256 revoked;
        uint256 unpaused;
        uint256 created;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("RoleGranted(bytes32,address,address)")) granted++;
            if (logs[i].topics[0] == keccak256("RoleRevoked(bytes32,address,address)")) revoked++;
            if (logs[i].topics[0] == keccak256("Unpaused(address)")) {
                unpaused++;
                assertTrue(
                    logs[i].emitter == address(manager) || logs[i].emitter == address(registry)
                );
            }
            assertNotEq(logs[i].topics[0], keccak256("Paused(address)"));
            if (
                logs[i].topics[0]
                    == keccak256(
                        "CompetitionCreated(bytes32,uint64,bytes32,uint40,uint40,uint40,uint16)"
                    )
            ) {
                created++;
                assertEq(logs[i].topics[1], id);
            }
        }
        assertEq(granted, 10);
        assertEq(revoked, 3);
        assertEq(unpaused, 2);
        assertEq(created, 1);
        assertTrue(manager.existsCompetition(id));
        assertFalse(manager.paused());
        assertFalse(registry.paused());
        assertEq(manager.competitionNonce(), 1);
        assertEq(manager.fheOperator(), admin);
        assertFalse(manager.hasRole(manager.PAUSER_ROLE(), bootstrap));
        assertFalse(registry.hasRole(registry.PAUSER_ROLE(), bootstrap));
        assertFalse(registry.hasRole(registry.QUALIFICATION_REVOKER_ROLE(), bootstrap));
        assertTrue(registry.hasRole(registry.QUALIFICATION_ISSUER_ROLE(), address(manager)));
        assertFalse(registry.hasRole(registry.QUALIFICATION_ISSUER_ROLE(), admin));
        assertEq(manager.submissionLimit(), 3);
        assertEq(manager.submissionWindowSeconds(), 300);
    }

    function test_repeatRunDoesNotEmitTransactionsOrDuplicateCompetition() public {
        bytes32 id = _run();
        vm.recordLogs();
        assertEq(_run(), id);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(manager.competitionNonce(), 1);
        assertFalse(manager.paused());
    }

    function test_partialPermissionSetupIsSkippedAndCompleted() public {
        bytes32 creatorRole = manager.COMPETITION_CREATOR_ROLE();
        vm.prank(admin);
        manager.grantRole(creatorRole, admin);
        vm.prank(admin);
        manager.updateFheOperator(admin);
        _run();
        assertTrue(manager.hasRole(manager.EVALUATOR_ROLE(), admin));
        assertFalse(manager.paused());
        assertEq(manager.competitionNonce(), 1);
    }

    function test_alreadyUnpausedWithCorrectOperatorDoesNotPauseAgain() public {
        vm.startPrank(admin);
        manager.updateFheOperator(admin);
        manager.unpause();
        vm.stopPrank();
        _run();
        assertFalse(manager.paused());
        assertEq(manager.competitionNonce(), 1);
    }

    function test_wrongChainFailsBeforePermissionsChange() public {
        vm.chainId(421_614);
        vm.expectRevert(
            abi.encodeWithSelector(SetupMainnetCompetition.WrongChain.selector, 421_614)
        );
        _run();
    }

    function test_wrongSenderFails() public {
        vm.expectRevert(
            abi.encodeWithSelector(SetupMainnetCompetition.WrongSender.selector, address(this))
        );
        setupScript.run();
    }

    function test_changedImplementationFails() public {
        vm.store(address(manager), IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(0xbad)))));
        vm.expectRevert(
            abi.encodeWithSelector(
                SetupMainnetCompetition.UnexpectedImplementation.selector, address(manager)
            )
        );
        _run();
    }

    function test_pendingAdminTransferFails() public {
        vm.prank(admin);
        manager.beginDefaultAdminTransfer(address(0x1234));
        vm.expectRevert(
            abi.encodeWithSelector(
                SetupMainnetCompetition.PendingAdminTransfer.selector, address(manager)
            )
        );
        _run();
    }

    function test_registryAlreadyUnpausedIsAccepted() public {
        vm.prank(admin);
        registry.unpause();
        bytes32 id = _run();
        assertTrue(manager.existsCompetition(id));
        assertFalse(registry.paused());
    }

    function test_unpausedManagerWithOldOperatorFails() public {
        vm.prank(admin);
        manager.unpause();
        vm.expectRevert(SetupMainnetCompetition.OperatorRotationRequiresPausedManager.selector);
        _run();
    }

    function test_missingCofheAdmissionFails() public {
        _mockAdmission(false);
        vm.expectRevert(SetupMainnetCompetition.CofheAdmissionUnavailable.selector);
        _run();
    }

    function test_changedSubmissionLimitsFailsWithoutGrants() public {
        vm.prank(admin);
        manager.updateSubmissionLimits(2, 300);
        vm.expectRevert(SetupMainnetCompetition.UnexpectedSubmissionLimits.selector);
        _run();
        assertFalse(manager.hasRole(manager.COMPETITION_CREATOR_ROLE(), admin));
    }

    function test_differentCompetitionNonceFailsBeforeSetup() public {
        CompetitionManager.CompetitionConfig memory config = CompetitionManager.CompetitionConfig({
            rulesHash: keccak256("existing competition"),
            submissionDeadline: uint40(block.timestamp + 14 days),
            evaluationDeadline: uint40(block.timestamp + 15 days),
            qualificationValidUntil: uint40(block.timestamp + 30 days),
            qualificationSlots: 1
        });
        vm.startPrank(admin);
        manager.grantRole(manager.COMPETITION_CREATOR_ROLE(), admin);
        manager.unpause();
        manager.createCompetition(config);
        vm.stopPrank();
        vm.prank(bootstrap);
        manager.pause();
        vm.expectRevert(
            abi.encodeWithSelector(
                SetupMainnetCompetition.UnexpectedCompetitionNonce.selector, uint64(1)
            )
        );
        _run();
        assertEq(manager.competitionNonce(), 1);
    }

    function test_changedDefaultAdminFailsBeforeSetup() public {
        vm.prank(admin);
        registry.beginDefaultAdminTransfer(address(0x1234));
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(address(0x1234));
        registry.acceptDefaultAdminTransfer();
        vm.expectRevert(
            abi.encodeWithSelector(
                SetupMainnetCompetition.UnexpectedAdmin.selector, address(registry), address(0x1234)
            )
        );
        _run();
    }

    function test_invalidScheduleFailsBeforePermissionsChange() public {
        CompetitionManager.CompetitionConfig memory config = _config();
        config.submissionDeadline = uint40(block.timestamp);
        vm.expectRevert(SetupMainnetCompetition.InvalidSchedule.selector);
        vm.prank(admin);
        setupScript.prepare(config, 0);
        assertFalse(manager.hasRole(manager.COMPETITION_CREATOR_ROLE(), admin));
    }

    function test_matchingIdWithChangedScheduleFails() public {
        CompetitionManager.CompetitionConfig memory config = _config();
        config.submissionDeadline--;
        vm.startPrank(admin);
        manager.grantRole(manager.COMPETITION_CREATOR_ROLE(), admin);
        manager.unpause();
        bytes32 id = manager.createCompetition(config);
        vm.stopPrank();
        vm.prank(bootstrap);
        manager.pause();
        vm.expectRevert(
            abi.encodeWithSelector(SetupMainnetCompetition.CompetitionMismatch.selector, id)
        );
        _run();
    }

    function _config() private view returns (CompetitionManager.CompetitionConfig memory config) {
        string memory json = vm.readFile(setupScript.CONFIG_PATH());
        config.rulesHash = vm.parseJsonBytes32(json, ".rulesHash");
        config.submissionDeadline = uint40(vm.parseJsonUint(json, ".submissionDeadline"));
        config.evaluationDeadline = uint40(vm.parseJsonUint(json, ".evaluationDeadline"));
        config.qualificationValidUntil = uint40(vm.parseJsonUint(json, ".qualificationValidUntil"));
        config.qualificationSlots = uint16(vm.parseJsonUint(json, ".qualificationSlots"));
    }

    function _run() private returns (bytes32) {
        return MainnetCompetitionAdminCaller(admin).run(setupScript);
    }

    function _installProxy(address target, address implementation) private {
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(implementation, admin, "");
        vm.etch(target, address(proxy).code);
        vm.store(target, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));
        vm.store(target, ADMIN_SLOT, vm.load(address(proxy), ADMIN_SLOT));
    }

    function _mockAdmission(bool allowed) private {
        address taskManager = setupScript.TASK_MANAGER();
        vm.mockCall(taskManager, abi.encodeWithSignature("isEnabled()"), abi.encode(true));
        vm.mockCall(taskManager, abi.encodeWithSignature("accessListEnabled()"), abi.encode(true));
        vm.mockCall(
            taskManager,
            abi.encodeWithSignature("accessList(address)", address(manager)),
            abi.encode(allowed)
        );
    }
}
