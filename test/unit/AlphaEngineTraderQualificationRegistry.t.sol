// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Test} from "forge-std/Test.sol";
import {
    IAlphaEngineTraderQualificationRegistry
} from "src/interfaces/IAlphaEngineTraderQualificationRegistry.sol";
import {
    AlphaEngineTraderQualificationRegistry
} from "src/strategy/AlphaEngineTraderQualificationRegistry.sol";

contract AlphaEngineTraderQualificationRegistryUnitTest is Test {
    AlphaEngineTraderQualificationRegistry private implementation;
    AlphaEngineTraderQualificationRegistry private registry;
    TransparentUpgradeableProxy private proxy;

    address private admin = makeAddr("admin");
    address private pauser = makeAddr("pauser");
    address private revoker = makeAddr("revoker");
    address private issuer = makeAddr("issuer");
    address private trader = makeAddr("trader");
    address private stranger = makeAddr("stranger");

    bytes32 private constant COMPETITION_ID = keccak256("competition");
    bytes32 private constant EVIDENCE_HASH = keccak256("evidence");
    bytes32 private constant REASON_HASH = keccak256("reason");
    bytes32 private constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 private constant ISSUER_ROLE = keccak256("QUALIFICATION_ISSUER_ROLE");
    bytes32 private constant REVOKER_ROLE = keccak256("QUALIFICATION_REVOKER_ROLE");
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    event TraderQualified(
        address indexed trader,
        uint64 indexed version,
        uint40 validUntil,
        bytes32 indexed sourceCompetitionId,
        bytes32 evidenceHash
    );
    event TraderQualificationExtended(
        address indexed trader,
        uint64 indexed version,
        uint40 previousValidUntil,
        uint40 newValidUntil,
        bytes32 indexed sourceCompetitionId,
        bytes32 evidenceHash
    );
    event TraderQualificationRevoked(
        address indexed trader,
        uint64 indexed revokedVersion,
        uint64 indexed newVersion,
        bytes32 reasonHash
    );

    function setUp() public {
        implementation = new AlphaEngineTraderQualificationRegistry();
        bytes memory initData = abi.encodeCall(
            AlphaEngineTraderQualificationRegistry.initialize, (admin, pauser, revoker)
        );
        proxy = new TransparentUpgradeableProxy(address(implementation), admin, initData);
        registry = AlphaEngineTraderQualificationRegistry(address(proxy));

        vm.prank(admin);
        registry.grantRole(ISSUER_ROLE, issuer);
    }

    function test_constructorDisablesImplementationInitializer() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(admin, pauser, revoker);
    }

    function test_initializeSetsRolesDelayPauseAndProxyAdmin() public view {
        assertEq(registry.defaultAdmin(), admin);
        assertEq(registry.defaultAdminDelay(), 48 hours);
        assertTrue(registry.hasRole(PAUSER_ROLE, pauser));
        assertTrue(registry.hasRole(REVOKER_ROLE, revoker));
        assertTrue(registry.hasRole(ISSUER_ROLE, issuer));
        assertTrue(registry.paused());

        address proxyAdmin = _proxyAdmin();
        assertNotEq(proxyAdmin, address(0));
        assertEq(ProxyAdmin(proxyAdmin).owner(), admin);
    }

    function test_initializeRejectsZeroAddresses() public {
        _expectInitializationRevert(
            address(0),
            pauser,
            revoker,
            AlphaEngineTraderQualificationRegistry.ZeroInitialDefaultAdmin.selector
        );
        _expectInitializationRevert(
            admin,
            address(0),
            revoker,
            AlphaEngineTraderQualificationRegistry.ZeroInitialPauser.selector
        );
        _expectInitializationRevert(
            admin,
            pauser,
            address(0),
            AlphaEngineTraderQualificationRegistry.ZeroInitialRevoker.selector
        );
    }

    function test_reinitializeReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(admin, pauser, revoker);
    }

    function test_onlyAdminCanUnpauseAndPauserCannotUnpause() public {
        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, DEFAULT_ADMIN_ROLE
            )
        );
        registry.unpause();

        vm.prank(admin);
        registry.unpause();
        assertFalse(registry.paused());
    }

    function test_onlyPauserCanPause() public {
        _unpause();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, PAUSER_ROLE
            )
        );
        registry.pause();

        vm.prank(pauser);
        registry.pause();
        assertTrue(registry.paused());
    }

    function test_firstQualificationStoresVersionAndEmits() public {
        _unpause();
        uint40 validUntil = _validUntil(7 days);

        vm.expectEmit(true, true, true, true);
        emit TraderQualified(trader, 1, validUntil, COMPETITION_ID, EVIDENCE_HASH);
        vm.prank(issuer);
        uint64 version = registry.qualifyTrader(trader, validUntil, COMPETITION_ID, EVIDENCE_HASH);

        assertEq(version, 1);
        assertTrue(registry.existsQualification(trader));
        assertTrue(registry.isQualified(trader));
        assertTrue(registry.isQualifiedAtVersion(trader, 1));
        assertFalse(registry.isQualifiedAtVersion(trader, 2));

        IAlphaEngineTraderQualificationRegistry.Qualification memory qualification =
            registry.getQualification(trader);
        assertEq(qualification.version, 1);
        assertEq(qualification.validUntil, validUntil);
        assertEq(qualification.sourceCompetitionId, COMPETITION_ID);
        assertEq(qualification.evidenceHash, EVIDENCE_HASH);
    }

    function test_activeExtensionPreservesVersionAndUpdatesEvidence() public {
        _unpause();
        uint40 firstExpiry = _validUntil(7 days);
        uint40 secondExpiry = _validUntil(14 days);
        bytes32 secondCompetitionId = keccak256("second competition");
        bytes32 secondEvidenceHash = keccak256("second evidence");
        _qualify(trader, firstExpiry);

        vm.expectEmit(true, true, true, true);
        emit TraderQualificationExtended(
            trader, 1, firstExpiry, secondExpiry, secondCompetitionId, secondEvidenceHash
        );
        vm.prank(issuer);
        uint64 version =
            registry.qualifyTrader(trader, secondExpiry, secondCompetitionId, secondEvidenceHash);

        assertEq(version, 1);
        IAlphaEngineTraderQualificationRegistry.Qualification memory qualification =
            registry.getQualification(trader);
        assertEq(qualification.version, 1);
        assertEq(qualification.validUntil, secondExpiry);
        assertEq(qualification.sourceCompetitionId, secondCompetitionId);
        assertEq(qualification.evidenceHash, secondEvidenceHash);
    }

    function test_activeQualificationCannotBeShortenedOrRepeated() public {
        _unpause();
        uint40 validUntil = _validUntil(7 days);
        _qualify(trader, validUntil);

        vm.startPrank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineTraderQualificationRegistry.QualificationExtensionNotLater.selector,
                validUntil,
                validUntil
            )
        );
        registry.qualifyTrader(trader, validUntil, COMPETITION_ID, EVIDENCE_HASH);

        uint40 earlierExpiry = validUntil - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineTraderQualificationRegistry.QualificationExtensionNotLater.selector,
                validUntil,
                earlierExpiry
            )
        );
        registry.qualifyTrader(trader, earlierExpiry, COMPETITION_ID, EVIDENCE_HASH);
        vm.stopPrank();
    }

    function test_expiryInvalidatesAndRequalificationIncrementsVersion() public {
        _unpause();
        uint40 firstExpiry = _validUntil(7 days);
        _qualify(trader, firstExpiry);

        vm.warp(firstExpiry);
        assertFalse(registry.isQualified(trader));
        assertFalse(registry.isQualifiedAtVersion(trader, 1));

        uint40 secondExpiry = firstExpiry + 7 days;
        vm.prank(issuer);
        uint64 newVersion =
            registry.qualifyTrader(trader, secondExpiry, COMPETITION_ID, EVIDENCE_HASH);

        assertEq(newVersion, 2);
        assertTrue(registry.isQualifiedAtVersion(trader, 2));
        assertFalse(registry.isQualifiedAtVersion(trader, 1));
    }

    function test_revocationInvalidatesVersionAndRequalificationCannotReviveIt() public {
        _unpause();
        _qualify(trader, _validUntil(7 days));

        vm.expectEmit(true, true, true, true);
        emit TraderQualificationRevoked(trader, 1, 2, REASON_HASH);
        vm.prank(revoker);
        uint64 revokedStateVersion = registry.revokeTrader(trader, REASON_HASH);

        assertEq(revokedStateVersion, 2);
        assertFalse(registry.isQualified(trader));
        assertFalse(registry.isQualifiedAtVersion(trader, 1));
        assertFalse(registry.isQualifiedAtVersion(trader, 2));

        vm.prank(issuer);
        uint64 requalifiedVersion =
            registry.qualifyTrader(trader, _validUntil(14 days), COMPETITION_ID, EVIDENCE_HASH);
        assertEq(requalifiedVersion, 3);
        assertFalse(registry.isQualifiedAtVersion(trader, 1));
        assertTrue(registry.isQualifiedAtVersion(trader, 3));
    }

    function test_revocationRemainsAvailableWhilePaused() public {
        _unpause();
        _qualify(trader, _validUntil(7 days));

        vm.prank(pauser);
        registry.pause();

        vm.prank(revoker);
        registry.revokeTrader(trader, REASON_HASH);
        assertFalse(registry.isQualified(trader));
    }

    function test_qualificationIsBlockedWhilePaused() public {
        vm.prank(issuer);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        registry.qualifyTrader(trader, _validUntil(7 days), COMPETITION_ID, EVIDENCE_HASH);
    }

    function test_onlyIssuerCanQualify() public {
        _unpause();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ISSUER_ROLE
            )
        );
        registry.qualifyTrader(trader, _validUntil(7 days), COMPETITION_ID, EVIDENCE_HASH);
    }

    function test_onlyRevokerCanRevoke() public {
        _unpause();
        _qualify(trader, _validUntil(7 days));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, REVOKER_ROLE
            )
        );
        registry.revokeTrader(trader, REASON_HASH);
    }

    function test_unknownQualificationHasExistsHelperAndTypedGetterFailure() public {
        assertFalse(registry.existsQualification(trader));
        assertFalse(registry.isQualified(trader));
        assertFalse(registry.isQualifiedAtVersion(trader, 1));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineTraderQualificationRegistry.QualificationNotFound.selector, trader
            )
        );
        registry.getQualification(trader);
    }

    function test_revokeRejectsUnknownExpiredAndRepeatedRevocation() public {
        vm.prank(revoker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineTraderQualificationRegistry.QualificationNotActive.selector, trader, 0, 0
            )
        );
        registry.revokeTrader(trader, REASON_HASH);

        _unpause();
        uint40 validUntil = _validUntil(1 days);
        _qualify(trader, validUntil);
        vm.warp(validUntil);

        vm.prank(revoker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineTraderQualificationRegistry.QualificationNotActive.selector,
                trader,
                1,
                validUntil
            )
        );
        registry.revokeTrader(trader, REASON_HASH);

        vm.prank(issuer);
        registry.qualifyTrader(trader, validUntil + 1 days, COMPETITION_ID, EVIDENCE_HASH);
        vm.prank(revoker);
        registry.revokeTrader(trader, REASON_HASH);

        vm.prank(revoker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineTraderQualificationRegistry.QualificationNotActive.selector, trader, 3, 0
            )
        );
        registry.revokeTrader(trader, REASON_HASH);
    }

    function test_inputValidation() public {
        _unpause();
        uint40 validUntil = _validUntil(1 days);

        vm.startPrank(issuer);
        vm.expectRevert(AlphaEngineTraderQualificationRegistry.ZeroTrader.selector);
        registry.qualifyTrader(address(0), validUntil, COMPETITION_ID, EVIDENCE_HASH);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineTraderQualificationRegistry.QualificationExpiryNotInFuture.selector,
                uint40(block.timestamp),
                block.timestamp
            )
        );
        registry.qualifyTrader(trader, uint40(block.timestamp), COMPETITION_ID, EVIDENCE_HASH);

        vm.expectRevert(AlphaEngineTraderQualificationRegistry.ZeroSourceCompetitionId.selector);
        registry.qualifyTrader(trader, validUntil, bytes32(0), EVIDENCE_HASH);

        vm.expectRevert(AlphaEngineTraderQualificationRegistry.ZeroEvidenceHash.selector);
        registry.qualifyTrader(trader, validUntil, COMPETITION_ID, bytes32(0));
        vm.stopPrank();

        vm.prank(revoker);
        vm.expectRevert(AlphaEngineTraderQualificationRegistry.ZeroTrader.selector);
        registry.revokeTrader(address(0), REASON_HASH);

        vm.prank(revoker);
        vm.expectRevert(AlphaEngineTraderQualificationRegistry.ZeroReasonHash.selector);
        registry.revokeTrader(trader, bytes32(0));
    }

    function test_versionExhaustionFailsLoudly() public {
        _unpause();
        bytes32 mappingSlot = keccak256(abi.encode(trader, uint256(0)));
        vm.store(address(registry), mappingSlot, bytes32(uint256(type(uint64).max)));

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineTraderQualificationRegistry.QualificationVersionExhausted.selector,
                trader
            )
        );
        registry.qualifyTrader(trader, _validUntil(1 days), COMPETITION_ID, EVIDENCE_HASH);
    }

    function testFuzz_extensionPreservesVersionAndNeverShortens(
        uint40 firstDelta,
        uint40 extraDelta
    ) public {
        firstDelta = uint40(bound(firstDelta, 1, 365 days));
        extraDelta = uint40(bound(extraDelta, 1, 365 days));
        _unpause();
        uint40 firstExpiry = uint40(block.timestamp) + firstDelta;
        uint40 secondExpiry = firstExpiry + extraDelta;
        _qualify(trader, firstExpiry);

        vm.prank(issuer);
        uint64 version = registry.qualifyTrader(trader, secondExpiry, COMPETITION_ID, EVIDENCE_HASH);

        assertEq(version, 1);
        assertTrue(registry.isQualifiedAtVersion(trader, 1));
        assertEq(registry.getQualification(trader).validUntil, secondExpiry);
    }

    function testFuzz_expiredVersionNeverRevives(uint40 firstDelta, uint40 secondDelta) public {
        firstDelta = uint40(bound(firstDelta, 1, 365 days));
        secondDelta = uint40(bound(secondDelta, 1, 365 days));
        _unpause();
        uint40 firstExpiry = uint40(block.timestamp) + firstDelta;
        _qualify(trader, firstExpiry);

        vm.warp(firstExpiry);
        vm.prank(issuer);
        uint64 version = registry.qualifyTrader(
            trader, firstExpiry + secondDelta, COMPETITION_ID, EVIDENCE_HASH
        );

        assertEq(version, 2);
        assertFalse(registry.isQualifiedAtVersion(trader, 1));
        assertTrue(registry.isQualifiedAtVersion(trader, 2));
    }

    function _unpause() private {
        vm.prank(admin);
        registry.unpause();
    }

    function _qualify(address account, uint40 validUntil) private returns (uint64 version) {
        vm.prank(issuer);
        return registry.qualifyTrader(account, validUntil, COMPETITION_ID, EVIDENCE_HASH);
    }

    function _validUntil(uint40 delta) private view returns (uint40) {
        return uint40(block.timestamp) + delta;
    }

    function _expectInitializationRevert(
        address initialAdmin,
        address initialPauser,
        address initialRevoker,
        bytes4 selector
    ) private {
        AlphaEngineTraderQualificationRegistry freshImplementation =
            new AlphaEngineTraderQualificationRegistry();
        bytes memory initData = abi.encodeCall(
            AlphaEngineTraderQualificationRegistry.initialize,
            (initialAdmin, initialPauser, initialRevoker)
        );
        vm.expectRevert(selector);
        new TransparentUpgradeableProxy(address(freshImplementation), admin, initData);
    }

    function _proxyAdmin() private view returns (address) {
        return address(
            uint160(
                uint256(
                    vm.load(
                        address(proxy),
                        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
                    )
                )
            )
        );
    }
}
