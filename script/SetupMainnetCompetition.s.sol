// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    AlphaEngineCompetitionStrategyManager as CompetitionManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
import {
    AlphaEngineTraderQualificationRegistry as QualificationRegistry
} from "src/strategy/AlphaEngineTraderQualificationRegistry.sol";

import {AlphaEngineStrategyHashLib} from "src/libraries/AlphaEngineStrategyHashLib.sol";

/// @dev Admission getters are absent from the pinned ICofhe.sol ITaskManager interface.
interface IMainnetCompetitionTaskManager {
    function isEnabled() external view returns (bool);
    function accessListEnabled() external view returns (bool);
    function accessList(address caller) external view returns (bool);
}

/// @notice User-run permission setup and competition creation; leaves both contracts unpaused.
/// @dev A Foundry script only: no helper contract or implementation is deployed on-chain.
contract SetupMainnetCompetition is Script {
    using SafeCast for uint256;

    string public constant CONFIG_PATH =
        "deployments/v2/arbitrum-mainnet-first-competition-2026-10-22.json";
    address public constant ADMIN = 0xAcc08cBbeD784Ba9b5B07ADb5F0E299Cb0fD3d95;
    address public constant PREVIOUS_BOOTSTRAP = 0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d;
    address public constant MANAGER = 0x7fFcDa0A08401AcF1d114C83B32cE439C48c3681;
    address public constant REGISTRY = 0xF7017f2e11E22094ef5E3952eA86768eD302C98D;
    address public constant MANAGER_IMPLEMENTATION = 0xA0e845476674Ad39319761f55dEbfba30CFcE1E0;
    address public constant REGISTRY_IMPLEMENTATION = 0x6DeBF287f1E9B64918078fCcbC36b659D8ea68eD;
    address public constant TASK_MANAGER = 0x52E7a0cAF234b266bCFAa6aA933a412FDe58432A;
    bytes32 public constant MANAGER_CODE_HASH =
        0x9f78e935c2bc6ad09cb062bba9dcb76861f56de3aeffb91dce9de87bcc58eb8a;
    bytes32 public constant REGISTRY_CODE_HASH =
        0xee4d39a243d479ac29667e0e02d5857879b0fba893468f361a5d2c4a0a23e407;
    bytes32 private constant IMPLEMENTATION_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    error WrongChain(uint256 actual);
    error WrongSender(address actual);
    error UnexpectedImplementation(address proxy);
    error UnexpectedAdmin(address target, address actual);
    error PendingAdminTransfer(address target);
    error RegistryMustBeUnpaused();
    error InvalidCompetitionParameters();
    error InvalidSchedule();
    error CompetitionMismatch(bytes32 competitionId);
    error OperatorRotationRequiresPausedManager();
    error ManagerMustBeUnpaused();
    error UnexpectedCompetitionNonce(uint64 actual);
    error CofheAdmissionUnavailable();
    error UnexpectedRoleAdmin(address target, bytes32 role);
    error PermissionCheckFailed(address target, bytes32 role, address holder);
    error OperatorCheckFailed();
    error UnexpectedSubmissionLimits();
    error UnknownRoleLabel(bytes32 role);

    function run() external returns (bytes32 competitionId) {
        string memory json = vm.readFile(CONFIG_PATH);
        if (
            vm.parseJsonUint(json, ".chainId") != 42_161
                || vm.parseJsonAddress(json, ".competitionManager") != MANAGER
        ) {
            revert InvalidCompetitionParameters();
        }
        CompetitionManager.CompetitionConfig memory config = CompetitionManager.CompetitionConfig({
            rulesHash: vm.parseJsonBytes32(json, ".rulesHash"),
            submissionDeadline: vm.parseJsonUint(json, ".submissionDeadline").toUint40(),
            evaluationDeadline: vm.parseJsonUint(json, ".evaluationDeadline").toUint40(),
            qualificationValidUntil: vm.parseJsonUint(json, ".qualificationValidUntil").toUint40(),
            qualificationSlots: vm.parseJsonUint(json, ".qualificationSlots").toUint16()
        });
        return prepare(config, vm.parseJsonUint(json, ".expectedCompetitionNonce").toUint64());
    }

    function prepare(CompetitionManager.CompetitionConfig memory config, uint64 expectedNonce)
        public
        returns (bytes32 competitionId)
    {
        if (block.chainid != 42_161) revert WrongChain(block.chainid);
        if (msg.sender != ADMIN) revert WrongSender(msg.sender);
        _checkImplementation(MANAGER, MANAGER_IMPLEMENTATION, MANAGER_CODE_HASH);
        _checkImplementation(REGISTRY, REGISTRY_IMPLEMENTATION, REGISTRY_CODE_HASH);

        CompetitionManager manager = CompetitionManager(MANAGER);
        QualificationRegistry registry = QualificationRegistry(REGISTRY);
        _checkAdmins(manager, registry);
        if (address(manager.qualificationRegistry()) != REGISTRY) {
            revert UnexpectedImplementation(REGISTRY);
        }
        _checkAdmission();
        if (manager.submissionLimit() != 3 || manager.submissionWindowSeconds() != 300) {
            revert UnexpectedSubmissionLimits();
        }
        if (!manager.paused() && manager.fheOperator() != ADMIN) {
            revert OperatorRotationRequiresPausedManager();
        }
        if (
            config.rulesHash == bytes32(0) || config.qualificationSlots == 0
                || config.qualificationSlots > manager.MAX_ACTIVE_SUBMISSIONS()
        ) {
            revert InvalidCompetitionParameters();
        }
        if (
            config.submissionDeadline <= block.timestamp
                || config.submissionDeadline >= config.evaluationDeadline
                || config.evaluationDeadline >= config.qualificationValidUntil
        ) revert InvalidSchedule();

        competitionId = AlphaEngineStrategyHashLib.hashCompetitionId(
            block.chainid, MANAGER, expectedNonce, config.rulesHash
        );
        bool alreadyCreated = manager.existsCompetition(competitionId);
        uint64 nonce = manager.competitionNonce();
        if (alreadyCreated) {
            if (uint256(nonce) != uint256(expectedNonce) + 1) {
                revert UnexpectedCompetitionNonce(nonce);
            }
            _checkCompetition(manager, competitionId, config, expectedNonce);
        } else if (nonce != expectedNonce) {
            revert UnexpectedCompetitionNonce(nonce);
        }

        console2.log(
            "SIMULATION PLAN: live state requires broadcast receipts and a fresh RPC check."
        );
        console2.log("Mode: permissions, unpause both contracts, create and start competition.");
        console2.log("Chain", block.chainid);
        console2.log("Signer / FHE operator", ADMIN);
        console2.log("Competition ID");
        console2.logBytes32(competitionId);
        console2.log("Configuration hash (compare between dry run and broadcast)");
        console2.logBytes32(
            keccak256(
                abi.encode(
                    "ALPHAENGINE_MAINNET_COMPETITION_START_V1",
                    block.chainid,
                    MANAGER,
                    REGISTRY,
                    ADMIN,
                    PREVIOUS_BOOTSTRAP,
                    expectedNonce,
                    config
                )
            )
        );
        console2.log("Submission deadline (UTC epoch)", config.submissionDeadline);
        console2.log("Evaluation deadline (UTC epoch)", config.evaluationDeadline);
        console2.log("Qualification expiry (UTC epoch)", config.qualificationValidUntil);
        console2.log("Qualification slots", config.qualificationSlots);
        console2.log("Competition already exists", alreadyCreated);

        vm.startBroadcast(ADMIN);
        uint256 calls;
        bytes32[7] memory roles = _managerRoles(manager);
        for (uint256 i; i < roles.length; ++i) {
            calls += _grant(manager, roles[i], ADMIN);
        }
        calls += _grant(registry, registry.QUALIFICATION_REVOKER_ROLE(), ADMIN);
        calls += _grant(registry, registry.PAUSER_ROLE(), ADMIN);
        calls += _grant(registry, registry.QUALIFICATION_ISSUER_ROLE(), MANAGER);
        if (manager.fheOperator() != ADMIN) {
            manager.updateFheOperator(ADMIN);
            calls++;
        }
        _checkPermissions(manager, registry);
        calls += _revoke(manager, manager.PAUSER_ROLE(), PREVIOUS_BOOTSTRAP);
        calls += _revoke(registry, registry.QUALIFICATION_REVOKER_ROLE(), PREVIOUS_BOOTSTRAP);
        calls += _revoke(registry, registry.PAUSER_ROLE(), PREVIOUS_BOOTSTRAP);
        // Complete operational setup before enabling either contract.
        if (registry.paused()) {
            registry.unpause();
            calls++;
        }
        if (manager.paused()) {
            manager.unpause();
            calls++;
        }
        if (!alreadyCreated) {
            bytes32 created = manager.createCompetition(config);
            if (created != competitionId) revert CompetitionMismatch(created);
            calls++;
        }
        vm.stopBroadcast();

        _checkPermissions(manager, registry);
        _requireRole(manager, manager.PAUSER_ROLE(), PREVIOUS_BOOTSTRAP, false);
        _requireRole(registry, registry.PAUSER_ROLE(), PREVIOUS_BOOTSTRAP, false);
        _requireRole(registry, registry.QUALIFICATION_REVOKER_ROLE(), PREVIOUS_BOOTSTRAP, false);
        _checkCompetition(manager, competitionId, config, expectedNonce);
        if (manager.paused()) revert ManagerMustBeUnpaused();
        if (registry.paused()) revert RegistryMustBeUnpaused();
        console2.log("Prepared transactions", calls);
        console2.log("FINAL SIMULATED CHECKS: all required roles present; old roles removed.");
        console2.log("Competition exists", manager.existsCompetition(competitionId));
        console2.log("Competition active", true);
        console2.log("Competition nonce after", manager.competitionNonce());
        console2.log("Competition manager paused", manager.paused());
        console2.log("Qualification registry paused", registry.paused());
        console2.log("Submission limit", manager.submissionLimit());
        console2.log("Submission window seconds", manager.submissionWindowSeconds());
        console2.log(
            "No protocol funding, token approval, implementation upgrade or pause transaction."
        );
    }

    function _checkImplementation(address proxy, address implementation, bytes32 codeHash)
        private
        view
    {
        if (
            proxy.code.length == 0 || implementation.codehash != codeHash
                || address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))) != implementation
        ) {
            revert UnexpectedImplementation(proxy);
        }
    }

    function _checkAdmins(CompetitionManager manager, QualificationRegistry registry) private view {
        if (manager.defaultAdmin() != ADMIN) {
            revert UnexpectedAdmin(MANAGER, manager.defaultAdmin());
        }
        if (registry.defaultAdmin() != ADMIN) {
            revert UnexpectedAdmin(REGISTRY, registry.defaultAdmin());
        }
        (address successor, uint48 schedule) = manager.pendingDefaultAdmin();
        if (successor != address(0) || schedule != 0) revert PendingAdminTransfer(MANAGER);
        (successor, schedule) = registry.pendingDefaultAdmin();
        if (successor != address(0) || schedule != 0) revert PendingAdminTransfer(REGISTRY);
    }

    function _checkAdmission() private view {
        IMainnetCompetitionTaskManager taskManager = IMainnetCompetitionTaskManager(TASK_MANAGER);
        if (
            !taskManager.isEnabled()
                || (taskManager.accessListEnabled() && !taskManager.accessList(MANAGER))
        ) {
            revert CofheAdmissionUnavailable();
        }
    }

    function _managerRoles(CompetitionManager manager) private view returns (bytes32[7] memory) {
        return [
            manager.COMPETITION_CREATOR_ROLE(),
            manager.COMPETITION_CANCELLER_ROLE(),
            manager.EVALUATOR_ROLE(),
            manager.FINALIZER_ROLE(),
            manager.QUALIFIER_ROLE(),
            manager.SCORE_REVEALER_ROLE(),
            manager.PAUSER_ROLE()
        ];
    }

    function _grant(IAccessControl target, bytes32 role, address recipient)
        private
        returns (uint256)
    {
        if (target.getRoleAdmin(role) != bytes32(0)) {
            revert UnexpectedRoleAdmin(address(target), role);
        }
        if (target.hasRole(role, recipient)) return 0;
        target.grantRole(role, recipient);
        console2.log("Granted on", address(target));
        console2.log("Role", _roleName(role));
        console2.log("Role hash");
        console2.logBytes32(role);
        console2.log("Recipient", recipient);
        return 1;
    }

    function _revoke(IAccessControl target, bytes32 role, address recipient)
        private
        returns (uint256)
    {
        if (!target.hasRole(role, recipient)) return 0;
        target.revokeRole(role, recipient);
        console2.log("Revoked on", address(target));
        console2.log("Role", _roleName(role));
        console2.log("Previous holder", recipient);
        return 1;
    }

    function _roleName(bytes32 role) private pure returns (string memory) {
        string[9] memory names = [
            "COMPETITION_CREATOR_ROLE",
            "COMPETITION_CANCELLER_ROLE",
            "EVALUATOR_ROLE",
            "FINALIZER_ROLE",
            "QUALIFIER_ROLE",
            "SCORE_REVEALER_ROLE",
            "PAUSER_ROLE",
            "QUALIFICATION_REVOKER_ROLE",
            "QUALIFICATION_ISSUER_ROLE"
        ];
        for (uint256 i; i < names.length; ++i) {
            if (keccak256(bytes(names[i])) == role) return names[i];
        }
        revert UnknownRoleLabel(role);
    }

    function _requireRole(IAccessControl target, bytes32 role, address holder, bool expected)
        private
        view
    {
        if (target.hasRole(role, holder) != expected) {
            revert PermissionCheckFailed(address(target), role, holder);
        }
    }

    function _checkPermissions(CompetitionManager manager, QualificationRegistry registry)
        private
        view
    {
        bytes32[7] memory roles = _managerRoles(manager);
        for (uint256 i; i < roles.length; ++i) {
            _requireRole(manager, roles[i], ADMIN, true);
        }
        _requireRole(registry, registry.QUALIFICATION_REVOKER_ROLE(), ADMIN, true);
        _requireRole(registry, registry.PAUSER_ROLE(), ADMIN, true);
        _requireRole(registry, registry.QUALIFICATION_ISSUER_ROLE(), MANAGER, true);
        if (manager.fheOperator() != ADMIN) revert OperatorCheckFailed();
    }

    function _checkCompetition(
        CompetitionManager manager,
        bytes32 id,
        CompetitionManager.CompetitionConfig memory config,
        uint64 expectedNonce
    ) private view {
        CompetitionManager.CompetitionRecord memory record = manager.getCompetition(id);
        if (
            record.rulesHash != config.rulesHash
                || record.submissionDeadline != config.submissionDeadline
                || record.evaluationDeadline != config.evaluationDeadline
                || record.qualificationValidUntil != config.qualificationValidUntil
                || record.qualificationSlots != config.qualificationSlots
                || record.competitionNonce != expectedNonce
                || record.status != CompetitionManager.CompetitionStatus.Active
        ) revert CompetitionMismatch(id);
    }
}
