// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {
    IAlphaEngineTraderQualificationRegistry
} from "src/interfaces/IAlphaEngineTraderQualificationRegistry.sol";
import {
    AlphaEngineTraderQualificationRegistry
} from "src/strategy/AlphaEngineTraderQualificationRegistry.sol";
import {
    QualificationRegistryInvariantHandler
} from "test/handlers/QualificationRegistryInvariantHandler.sol";

contract AlphaEngineTraderQualificationRegistryInvariantTest is StdInvariant, Test {
    AlphaEngineTraderQualificationRegistry private registry;
    QualificationRegistryInvariantHandler private handler;

    address private admin = makeAddr("admin");
    address private pauser = makeAddr("pauser");
    address private revoker = makeAddr("revoker");

    function setUp() public {
        AlphaEngineTraderQualificationRegistry implementation =
            new AlphaEngineTraderQualificationRegistry();
        bytes memory initData = abi.encodeCall(
            AlphaEngineTraderQualificationRegistry.initialize, (admin, pauser, revoker)
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), admin, initData);
        registry = AlphaEngineTraderQualificationRegistry(address(proxy));
        handler = new QualificationRegistryInvariantHandler(registry, admin, pauser);

        vm.startPrank(admin);
        registry.grantRole(registry.QUALIFICATION_ISSUER_ROLE(), address(handler));
        registry.grantRole(registry.QUALIFICATION_REVOKER_ROLE(), address(handler));
        registry.unpause();
        vm.stopPrank();

        handler.qualifyOrExtend(0, 1 days);
        handler.qualifyOrExtend(0, 1 days);
        handler.revoke(0);
        handler.qualifyOrExtend(0, 1 days);
        handler.advanceTime(1);
        handler.attemptShorterExtension(0, true);
        handler.expiryCycle(0);
        handler.governanceCycle(0);
        handler.upgradeCycle();

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.qualifyOrExtend.selector;
        selectors[1] = handler.revoke.selector;
        selectors[2] = handler.advanceTime.selector;
        selectors[3] = handler.attemptShorterExtension.selector;
        selectors[4] = handler.expiryCycle.selector;
        selectors[5] = handler.governanceCycle.selector;
        selectors[6] = handler.upgradeCycle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev QC-01/QC-03/QC-11/QC-14: independently predicted evidence, versions and expiry.
    function invariant_exactQualificationLedgerAndBoundaryWitnesses() public view {
        handler.property_exactQualificationLedger();
        assertGt(handler.rejectedExtensions(), 0);
        assertGt(handler.exactExpiryCycles(), 0);
        assertGt(handler.governanceCycles(), 0);
        assertGt(handler.upgradeCycles(), 0);
    }

    function invariant_versionsNeverDecrease() public view {
        assertGt(handler.qualifications(), 0);
        assertGt(handler.extensions(), 0);
        assertGt(handler.revocations(), 0);
        assertGt(handler.timeAdvances(), 0);
        assertFalse(handler.versionDecreased());
    }

    function invariant_supersededVersionsNeverReactivate() public view {
        for (uint256 index = 0; index < handler.TRADER_COUNT(); ++index) {
            address trader = handler.traderAt(index);
            uint64 supersededVersion = handler.supersededVersion(trader);
            if (supersededVersion != 0) {
                assertFalse(registry.isQualifiedAtVersion(trader, supersededVersion));
            }
        }
    }

    function invariant_registryStateMatchesObservedVersion() public view {
        for (uint256 index = 0; index < handler.TRADER_COUNT(); ++index) {
            address trader = handler.traderAt(index);
            uint64 observedVersion = handler.observedVersion(trader);
            assertEq(registry.existsQualification(trader), observedVersion != 0);
            if (observedVersion == 0) {
                assertFalse(registry.isQualified(trader));
                continue;
            }

            IAlphaEngineTraderQualificationRegistry.Qualification memory qualification =
                registry.getQualification(trader);
            assertEq(qualification.version, observedVersion);
            assertEq(
                registry.isQualified(trader), registry.isQualifiedAtVersion(trader, observedVersion)
            );
            if (registry.isQualified(trader)) {
                assertGt(qualification.validUntil, block.timestamp);
            }
        }
    }
}
