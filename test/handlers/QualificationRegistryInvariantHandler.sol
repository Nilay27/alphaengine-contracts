// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAlphaEngineTraderQualificationRegistry} from
    "src/interfaces/IAlphaEngineTraderQualificationRegistry.sol";
import {AlphaEngineTraderQualificationRegistry} from
    "src/strategy/AlphaEngineTraderQualificationRegistry.sol";

contract QualificationRegistryInvariantHandler is Test {
    uint256 public constant TRADER_COUNT = 4;

    AlphaEngineTraderQualificationRegistry public immutable REGISTRY;

    mapping(address trader => uint64 version) public observedVersion;
    mapping(address trader => uint64 version) public supersededVersion;
    bool public versionDecreased;

    constructor(AlphaEngineTraderQualificationRegistry registry) {
        REGISTRY = registry;
    }

    function qualifyOrExtend(uint256 traderSeed, uint40 extensionDelta) external {
        address trader = traderAt(traderSeed);
        extensionDelta = uint40(bound(extensionDelta, 1, 30 days));
        if (block.timestamp > type(uint40).max - 30 days) {
            return;
        }

        uint64 previousVersion = observedVersion[trader];
        uint40 validUntil = uint40(block.timestamp) + extensionDelta;
        if (REGISTRY.isQualified(trader)) {
            IAlphaEngineTraderQualificationRegistry.Qualification memory qualification =
                REGISTRY.getQualification(trader);
            uint256 extendedExpiry = uint256(qualification.validUntil) + extensionDelta;
            if (extendedExpiry > type(uint40).max) {
                return;
            }
            validUntil = uint40(extendedExpiry);
        }

        uint64 newVersion = REGISTRY.qualifyTrader(
            trader,
            validUntil,
            keccak256(abi.encode("competition", trader, previousVersion, validUntil)),
            keccak256(abi.encode("evidence", trader, previousVersion, validUntil))
        );
        _recordVersion(trader, previousVersion, newVersion);
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
        _recordVersion(trader, previousVersion, newVersion);
    }

    function advanceTime(uint40 delta) external {
        delta = uint40(bound(delta, 1, 30 days));
        if (block.timestamp > type(uint40).max - delta) {
            return;
        }
        vm.warp(block.timestamp + delta);
    }

    function traderAt(uint256 seed) public pure returns (address) {
        return address(uint160(0x1000 + (seed % TRADER_COUNT)));
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
