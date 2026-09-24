// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    IAlphaEngineTraderQualificationRegistry
} from "../interfaces/IAlphaEngineTraderQualificationRegistry.sol";

/// @title AlphaEngineTraderQualificationRegistry
/// @notice Stores versioned, expiring trader qualifications issued by competition managers.
/// @dev Qualification applies to a trader, never to a submitted strategy. Capital intents bind
///      to the exact active version so revocation or expiry cannot be bypassed by requalification.
contract AlphaEngineTraderQualificationRegistry is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    PausableUpgradeable,
    IAlphaEngineTraderQualificationRegistry
{
    uint48 public constant DEFAULT_ADMIN_DELAY = 48 hours;

    bytes32 public constant QUALIFICATION_ISSUER_ROLE = keccak256("QUALIFICATION_ISSUER_ROLE");
    bytes32 public constant QUALIFICATION_REVOKER_ROLE = keccak256("QUALIFICATION_REVOKER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    error ZeroInitialDefaultAdmin();
    error ZeroInitialPauser();
    error ZeroInitialRevoker();
    error ZeroTrader();
    error ZeroSourceCompetitionId();
    error ZeroEvidenceHash();
    error ZeroReasonHash();
    error QualificationNotFound(address trader);
    error QualificationNotActive(address trader, uint64 version, uint40 validUntil);
    error QualificationExpiryNotInFuture(uint40 validUntil, uint256 currentTimestamp);
    error QualificationExtensionNotLater(uint40 currentValidUntil, uint40 proposedValidUntil);
    error QualificationVersionExhausted(address trader);

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

    mapping(address trader => Qualification qualification) private _qualifications;

    /// @dev One mapping slot plus this gap reserves 50 repository-owned storage slots.
    uint256[49] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialDefaultAdmin, address initialPauser, address initialRevoker)
        external
        initializer
    {
        if (initialDefaultAdmin == address(0)) {
            revert ZeroInitialDefaultAdmin();
        }
        if (initialPauser == address(0)) {
            revert ZeroInitialPauser();
        }
        if (initialRevoker == address(0)) {
            revert ZeroInitialRevoker();
        }

        __AccessControlDefaultAdminRules_init(DEFAULT_ADMIN_DELAY, initialDefaultAdmin);
        __Pausable_init();

        _grantRole(PAUSER_ROLE, initialPauser);
        _grantRole(QUALIFICATION_REVOKER_ROLE, initialRevoker);
        _pause();
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpausing is intentionally restricted to delayed governance, not the pauser.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function qualifyTrader(
        address trader,
        uint40 validUntil,
        bytes32 sourceCompetitionId,
        bytes32 evidenceHash
    ) external whenNotPaused onlyRole(QUALIFICATION_ISSUER_ROLE) returns (uint64 version) {
        _validateQualificationInput(trader, validUntil, sourceCompetitionId, evidenceHash);

        Qualification storage qualification = _qualifications[trader];
        bool currentlyQualified = _isActive(qualification);

        if (currentlyQualified) {
            if (validUntil <= qualification.validUntil) {
                revert QualificationExtensionNotLater(qualification.validUntil, validUntil);
            }

            uint40 previousValidUntil = qualification.validUntil;
            qualification.validUntil = validUntil;
            qualification.sourceCompetitionId = sourceCompetitionId;
            qualification.evidenceHash = evidenceHash;
            version = qualification.version;

            emit TraderQualificationExtended(
                trader, version, previousValidUntil, validUntil, sourceCompetitionId, evidenceHash
            );
            return version;
        }

        version = _nextVersion(trader, qualification.version);
        qualification.version = version;
        qualification.validUntil = validUntil;
        qualification.sourceCompetitionId = sourceCompetitionId;
        qualification.evidenceHash = evidenceHash;

        emit TraderQualified(trader, version, validUntil, sourceCompetitionId, evidenceHash);
    }

    /// @notice Revocation remains callable while paused for emergency invalidation.
    function revokeTrader(address trader, bytes32 reasonHash)
        external
        onlyRole(QUALIFICATION_REVOKER_ROLE)
        returns (uint64 newVersion)
    {
        if (trader == address(0)) {
            revert ZeroTrader();
        }
        if (reasonHash == bytes32(0)) {
            revert ZeroReasonHash();
        }

        Qualification storage qualification = _qualifications[trader];
        if (!_isActive(qualification)) {
            revert QualificationNotActive(trader, qualification.version, qualification.validUntil);
        }

        uint64 revokedVersion = qualification.version;
        newVersion = _nextVersion(trader, revokedVersion);
        qualification.version = newVersion;
        qualification.validUntil = 0;

        emit TraderQualificationRevoked(trader, revokedVersion, newVersion, reasonHash);
    }

    function existsQualification(address trader) external view returns (bool) {
        return _qualifications[trader].version != 0;
    }

    function getQualification(address trader)
        external
        view
        returns (Qualification memory qualification)
    {
        qualification = _qualifications[trader];
        if (qualification.version == 0) {
            revert QualificationNotFound(trader);
        }
    }

    function isQualified(address trader) external view returns (bool) {
        return _isActive(_qualifications[trader]);
    }

    function isQualifiedAtVersion(address trader, uint64 version) external view returns (bool) {
        Qualification storage qualification = _qualifications[trader];
        return qualification.version == version && _isActive(qualification);
    }

    function _validateQualificationInput(
        address trader,
        uint40 validUntil,
        bytes32 sourceCompetitionId,
        bytes32 evidenceHash
    ) private view {
        if (trader == address(0)) {
            revert ZeroTrader();
        }
        if (validUntil <= block.timestamp) {
            revert QualificationExpiryNotInFuture(validUntil, block.timestamp);
        }
        if (sourceCompetitionId == bytes32(0)) {
            revert ZeroSourceCompetitionId();
        }
        if (evidenceHash == bytes32(0)) {
            revert ZeroEvidenceHash();
        }
    }

    function _nextVersion(address trader, uint64 currentVersion)
        private
        pure
        returns (uint64 nextVersion)
    {
        if (currentVersion == type(uint64).max) {
            revert QualificationVersionExhausted(trader);
        }
        return currentVersion + 1;
    }

    function _isActive(Qualification storage qualification) private view returns (bool) {
        return qualification.version != 0 && block.timestamp < qualification.validUntil;
    }
}
