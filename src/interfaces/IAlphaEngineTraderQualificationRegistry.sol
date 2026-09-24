// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IAlphaEngineTraderQualificationRegistry {
    struct Qualification {
        uint64 version;
        uint40 validUntil;
        bytes32 sourceCompetitionId;
        bytes32 evidenceHash;
    }

    function qualifyTrader(
        address trader,
        uint40 validUntil,
        bytes32 sourceCompetitionId,
        bytes32 evidenceHash
    ) external returns (uint64 version);

    function revokeTrader(address trader, bytes32 reasonHash) external returns (uint64 newVersion);

    function existsQualification(address trader) external view returns (bool);

    function getQualification(address trader)
        external
        view
        returns (Qualification memory qualification);

    function isQualified(address trader) external view returns (bool);

    function isQualifiedAtVersion(address trader, uint64 version) external view returns (bool);
}
