// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    IAlphaEngineTraderQualificationRegistry
} from "src/interfaces/IAlphaEngineTraderQualificationRegistry.sol";
import {
    AlphaEngineTraderQualificationRegistry
} from "src/strategy/AlphaEngineTraderQualificationRegistry.sol";

contract QualificationRegistryInvariantHandler is Test {
    uint256 public constant TRADER_COUNT = 4;

    AlphaEngineTraderQualificationRegistry public immutable REGISTRY;
    address private immutable ADMIN;
    address private immutable PAUSER;

    mapping(address trader => uint64 version) public observedVersion;
    mapping(address trader => uint64 version) public supersededVersion;
    bool public versionDecreased;
    uint256 public qualifications;
    uint256 public extensions;
    uint256 public revocations;
    uint256 public timeAdvances;
    uint256 public rejectedExtensions;
    uint256 public exactExpiryCycles;
    uint256 public governanceCycles;
    uint256 public upgradeCycles;
    mapping(address => IAlphaEngineTraderQualificationRegistry.Qualification) private _model;

    constructor(AlphaEngineTraderQualificationRegistry registry, address admin, address pauser) {
        REGISTRY = registry;
        ADMIN = admin;
        PAUSER = pauser;
    }

    function qualifyOrExtend(uint256 traderSeed, uint40 extensionDelta) external {
        address trader = traderAt(traderSeed);
        extensionDelta = uint40(bound(extensionDelta, 1, 30 days));
        if (block.timestamp > type(uint40).max - 30 days) {
            return;
        }

        uint64 previousVersion = observedVersion[trader];
        bool wasActive = REGISTRY.isQualified(trader);
        uint40 validUntil = uint40(block.timestamp) + extensionDelta;
        if (REGISTRY.isQualified(trader)) {
            IAlphaEngineTraderQualificationRegistry.Qualification memory qualification =
                REGISTRY.getQualification(trader);
            uint256 extendedExpiry = uint256(qualification.validUntil) + extensionDelta;
            if (extendedExpiry > type(uint40).max) {
                return;
            }
            validUntil = uint40(extendedExpiry);
            extensions += 1;
        }

        uint64 newVersion = REGISTRY.qualifyTrader(
            trader,
            validUntil,
            keccak256(abi.encode("competition", trader, previousVersion, validUntil)),
            keccak256(abi.encode("evidence", trader, previousVersion, validUntil))
        );
        // QC-01/QC-03: the oracle predicts the version before observing the result.
        assertEq(newVersion, wasActive ? previousVersion : previousVersion + 1);
        _model[trader] = IAlphaEngineTraderQualificationRegistry.Qualification({
            version: newVersion,
            validUntil: validUntil,
            sourceCompetitionId: keccak256(
                abi.encode("competition", trader, previousVersion, validUntil)
            ),
            evidenceHash: keccak256(abi.encode("evidence", trader, previousVersion, validUntil))
        });
        _recordVersion(trader, previousVersion, newVersion);
        qualifications += 1;
    }

    function revoke(uint256 traderSeed) external {
        address trader = traderAt(traderSeed);
        if (!REGISTRY.isQualified(trader)) {
            return;
        }

        uint64 previousVersion = observedVersion[trader];
        uint64 newVersion = REGISTRY.revokeTrader(
            trader, keccak256(abi.encode("revocation", trader, previousVersion))
        );
        assertEq(newVersion, previousVersion + 1);
        _model[trader].version = newVersion;
        _model[trader].validUntil = 0;
        _recordVersion(trader, previousVersion, newVersion);
        revocations += 1;
    }

    function advanceTime(uint40 delta) external {
        delta = uint40(bound(delta, 1, 30 days));
        if (block.timestamp > type(uint40).max - delta) {
            return;
        }
        vm.warp(block.timestamp + delta);
        timeAdvances += 1;
    }

    function traderAt(uint256 seed) public pure returns (address) {
        return address(uint160(0x1000 + (seed % TRADER_COUNT)));
    }

    /// @dev QC-01: failed equal/shorter extensions retain all evidence, not just the version.
    function attemptShorterExtension(uint256 seed, bool equalExpiry) external {
        address trader = traderAt(seed);
        if (!REGISTRY.isQualified(trader)) return;
        IAlphaEngineTraderQualificationRegistry.Qualification memory beforeState =
            REGISTRY.getQualification(trader);
        uint40 proposed = equalExpiry || beforeState.validUntil == block.timestamp + 1
            ? beforeState.validUntil
            : beforeState.validUntil - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineTraderQualificationRegistry.QualificationExtensionNotLater.selector,
                beforeState.validUntil,
                proposed
            )
        );
        REGISTRY.qualifyTrader(
            trader, proposed, keccak256("changed source"), keccak256("changed evidence")
        );
        assertEq(
            keccak256(abi.encode(REGISTRY.getQualification(trader))),
            keccak256(abi.encode(beforeState))
        );
        ++rejectedExtensions;
    }

    /// @dev QC-03/QC-14: exact expiry cannot revive an old version after repeated cycles.
    function expiryCycle(uint256 seed) external {
        address trader = traderAt(seed);
        if (!REGISTRY.isQualified(trader)) this.qualifyOrExtend(seed, 1 days);
        uint40 expiry = REGISTRY.getQualification(trader).validUntil;
        uint64 oldVersion = REGISTRY.getQualification(trader).version;
        vm.warp(expiry - 1);
        assertTrue(REGISTRY.isQualifiedAtVersion(trader, oldVersion));
        vm.warp(expiry);
        assertFalse(REGISTRY.isQualified(trader));
        this.qualifyOrExtend(seed, 1 days);
        assertEq(REGISTRY.getQualification(trader).version, oldVersion + 1);
        assertFalse(REGISTRY.isQualifiedAtVersion(trader, oldVersion));
        ++exactExpiryCycles;
    }

    /// @dev QC-11: pause blocks issuance but cannot block authorized emergency revocation.
    function governanceCycle(uint256 seed) external {
        address trader = traderAt(seed);
        if (!REGISTRY.isQualified(trader)) this.qualifyOrExtend(seed, 1 days);
        bytes32 beforeHash = keccak256(abi.encode(REGISTRY.getQualification(trader)));
        vm.prank(PAUSER);
        REGISTRY.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        REGISTRY.qualifyTrader(
            trader, uint40(block.timestamp + 90 days), keccak256("source"), keccak256("evidence")
        );
        assertEq(keccak256(abi.encode(REGISTRY.getQualification(trader))), beforeHash);
        this.revoke(seed);
        assertFalse(REGISTRY.isQualified(trader));
        vm.startPrank(ADMIN);
        REGISTRY.unpause();
        REGISTRY.revokeRole(REGISTRY.QUALIFICATION_ISSUER_ROLE(), address(this));
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                REGISTRY.QUALIFICATION_ISSUER_ROLE()
            )
        );
        REGISTRY.qualifyTrader(
            trader, uint40(block.timestamp + 1 days), keccak256("source"), keccak256("evidence")
        );
        bytes32 issuerRole = REGISTRY.QUALIFICATION_ISSUER_ROLE();
        vm.prank(ADMIN);
        REGISTRY.grantRole(issuerRole, address(this));
        this.qualifyOrExtend(seed, 1 days);
        ++governanceCycles;
    }

    function property_exactQualificationLedger() external view {
        for (uint256 i; i < TRADER_COUNT; ++i) {
            address trader = traderAt(i);
            IAlphaEngineTraderQualificationRegistry.Qualification memory expected = _model[trader];
            if (expected.version == 0) continue;
            assertEq(
                keccak256(abi.encode(REGISTRY.getQualification(trader))),
                keccak256(abi.encode(expected))
            );
            assertEq(REGISTRY.isQualified(trader), block.timestamp < expected.validUntil);
        }
    }

    /// @dev QC-15: expired/revoked records and business roles survive a real ProxyAdmin handover.
    function upgradeCycle() external {
        bytes32 beforeHash = _registrySnapshot();
        ProxyAdmin proxyAdmin = ProxyAdmin(
            address(
                uint160(
                    uint256(
                        vm.load(
                            address(REGISTRY),
                            bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
                        )
                    )
                )
            )
        );
        address nextAdmin = address(0xA11CE15);
        address implementation = address(new AlphaEngineTraderQualificationRegistry());
        vm.prank(ADMIN);
        proxyAdmin.transferOwnership(nextAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ADMIN));
        vm.prank(ADMIN);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(REGISTRY)), implementation, ""
        );
        vm.prank(nextAdmin);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(REGISTRY)), implementation, ""
        );
        assertEq(_registrySnapshot(), beforeHash);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        REGISTRY.initialize(ADMIN, PAUSER, address(this));
        vm.prank(nextAdmin);
        proxyAdmin.transferOwnership(ADMIN);
        ++upgradeCycles;
    }

    function _registrySnapshot() private view returns (bytes32 snapshot) {
        snapshot = keccak256(
            abi.encode(
                REGISTRY.defaultAdmin(),
                REGISTRY.paused(),
                REGISTRY.hasRole(REGISTRY.QUALIFICATION_ISSUER_ROLE(), address(this)),
                REGISTRY.hasRole(REGISTRY.QUALIFICATION_REVOKER_ROLE(), address(this))
            )
        );
        for (uint256 i; i < TRADER_COUNT; ++i) {
            address trader = traderAt(i);
            if (REGISTRY.existsQualification(trader)) {
                snapshot =
                    keccak256(abi.encode(snapshot, trader, REGISTRY.getQualification(trader)));
            }
        }
    }

    function _recordVersion(address trader, uint64 previousVersion, uint64 newVersion) private {
        if (newVersion < previousVersion) {
            versionDecreased = true;
        }
        if (newVersion > previousVersion && previousVersion != 0) {
            supersededVersion[trader] = previousVersion;
        }
        observedVersion[trader] = newVersion;
    }
}
