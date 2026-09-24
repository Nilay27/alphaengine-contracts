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
        handler = new QualificationRegistryInvariantHandler(registry);

        vm.startPrank(admin);
        registry.grantRole(registry.QUALIFICATION_ISSUER_ROLE(), address(handler));
        registry.grantRole(registry.QUALIFICATION_REVOKER_ROLE(), address(handler));
        registry.unpause();
        vm.stopPrank();

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.qualifyOrExtend.selector;
        selectors[1] = handler.revoke.selector;
        selectors[2] = handler.advanceTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_versionsNeverDecrease() public view {
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
