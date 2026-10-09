// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AlphaEngineCompetitionStrategyManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";

/// @notice Opt-in upgrade rehearsal against the recorded, populated Arbitrum Sepolia proxy.
/// @dev RUN_COMPETITION_UPGRADE_FORK=true uses the configured arbitrum_sepolia RPC; no broadcast.
contract CompetitionManagerUpgradeForkTest is Test {
    uint256 private constant FORK_BLOCK = 317_476_663;
    address private constant PROXY = 0x9CBF3917Ff31E41393e5D992b3bdbf1fC9C80744;
    address private constant ADMIN = 0x4e3841A9e383850bD238377f3471205Ba21ded8c;
    address private constant OLD_IMPLEMENTATION = 0x6b695e6bae7c39B70b31136844Ca674abe446842;
    address private constant GOVERNANCE = 0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d;
    bytes32 private constant OLD_CODE_HASH =
        0x2392689e40138eb11868ebe360aacd7a672d8bc7b022ace71682751ae823c1a3;
    bytes32 private constant COMPETITION =
        0xb6affee44171d2bb27bf22f6472331b9acaa3dcb7f689bd3de6e69601ff89252;
    bytes32 private constant SUBMISSION =
        0xfbbeeb4e2cd92c8e8faec040ead24a797298ce2c97e58d2ebfe9a54b94912b69;
    bytes32 private constant IMPLEMENTATION_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 private constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    event Upgraded(address indexed implementation);
    event SubmissionLimitsUpdated(uint16 limit, uint32 windowSeconds);

    function test_recordedProxyUpgradePreservesStateAndConfiguresNewAllowance() public {
        vm.skip(!vm.envOr("RUN_COMPETITION_UPGRADE_FORK", false));
        vm.createSelectFork("arbitrum_sepolia", FORK_BLOCK);
        assertEq(block.chainid, 421_614);
        assertEq(address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT)))), OLD_IMPLEMENTATION);
        assertEq(address(uint160(uint256(vm.load(PROXY, ADMIN_SLOT)))), ADMIN);
        assertEq(OLD_IMPLEMENTATION.codehash, OLD_CODE_HASH);
        assertEq(ProxyAdmin(ADMIN).owner(), GOVERNANCE);
        assertEq(ProxyAdmin(ADMIN).UPGRADE_INTERFACE_VERSION(), "5.0.0");

        AlphaEngineCompetitionStrategyManager manager = AlphaEngineCompetitionStrategyManager(PROXY);
        assertEq(manager.defaultAdmin(), GOVERNANCE);
        assertTrue(manager.hasRole(manager.PAUSER_ROLE(), GOVERNANCE));
        assertTrue(manager.existsSubmission(SUBMISSION));
        address trader = manager.getSubmissionIdentity(SUBMISSION).trader;
        assertEq(manager.activeSubmissionByTrader(COMPETITION, trader), SUBMISSION);
        assertGt(manager.traderNonces(trader), 0);
        bytes32 stateBefore = _stateHash(manager, trader);
        bytes32 proxyCodeBefore = PROXY.codehash;
        uint256 balanceBefore = PROXY.balance;

        if (!manager.paused()) {
            vm.prank(GOVERNANCE);
            manager.pause();
        }
        uint256 pausedAt = vm.getBlockTimestamp();
        bytes32[11] memory slotsBefore;
        for (uint256 i; i < 11; ++i) {
            slotsBefore[i] = vm.load(PROXY, bytes32(i));
        }

        AlphaEngineCompetitionStrategyManager implementation =
            new AlphaEngineCompetitionStrategyManager();
        address stranger = makeAddr("unauthorized-upgrader");
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vm.prank(stranger);
        ProxyAdmin(ADMIN)
            .upgradeAndCall(ITransparentUpgradeableProxy(PROXY), address(implementation), "");
        assertEq(address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT)))), OLD_IMPLEMENTATION);

        vm.expectEmit(true, false, false, true, PROXY);
        emit Upgraded(address(implementation));
        vm.prank(GOVERNANCE);
        ProxyAdmin(ADMIN)
            .upgradeAndCall(ITransparentUpgradeableProxy(PROXY), address(implementation), "");

        assertEq(
            address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT)))), address(implementation)
        );
        assertEq(address(uint160(uint256(vm.load(PROXY, ADMIN_SLOT)))), ADMIN);
        assertEq(ProxyAdmin(ADMIN).owner(), GOVERNANCE);
        assertEq(PROXY.codehash, proxyCodeBefore);
        assertEq(PROXY.balance, balanceBefore);
        assertEq(_stateHash(manager, trader), stateBefore);
        for (uint256 i; i < 11; ++i) {
            assertEq(vm.load(PROXY, bytes32(i)), slotsBefore[i]);
        }
        assertTrue(manager.paused());
        // An upgrade does not rerun initialize or install fresh-proxy defaults.
        assertEq(manager.submissionLimit(), 0);
        assertEq(manager.submissionWindowSeconds(), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineCompetitionStrategyManager.InvalidSubmissionLimits.selector,
                uint16(0),
                uint32(0)
            )
        );
        manager.getSubmissionAllowance(trader);
        AlphaEngineCompetitionStrategyManager.InitializationParams memory params =
            AlphaEngineCompetitionStrategyManager.InitializationParams({
                initialDefaultAdmin: GOVERNANCE,
                initialPauser: GOVERNANCE,
                initialFheOperator: manager.fheOperator(),
                qualificationRegistry: address(manager.qualificationRegistry())
            });
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        manager.initialize(params);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(params);

        vm.expectEmit(false, false, false, true, PROXY);
        emit SubmissionLimitsUpdated(3, 300);
        vm.prank(GOVERNANCE);
        manager.updateSubmissionLimits(3, 300);
        assertEq(manager.submissionLimit(), 3);
        assertEq(manager.submissionWindowSeconds(), 300);
        // Old admissions have no new timestamp history; wait one full window after pausing.
        vm.warp(pausedAt + 300);
        vm.prank(GOVERNANCE);
        manager.unpause();
        assertFalse(manager.paused());
        (bool allowed, uint256 nextAllowedAt) = manager.getSubmissionAllowance(trader);
        assertTrue(allowed);
        assertEq(nextAllowedAt, 0);
        assertEq(_stateHash(manager, trader), stateBefore);
    }

    function _stateHash(AlphaEngineCompetitionStrategyManager manager, address trader)
        private
        view
        returns (bytes32)
    {
        bytes32[8] memory roles = [
            manager.DEFAULT_ADMIN_ROLE(),
            manager.PAUSER_ROLE(),
            manager.COMPETITION_CREATOR_ROLE(),
            manager.COMPETITION_CANCELLER_ROLE(),
            manager.EVALUATOR_ROLE(),
            manager.FINALIZER_ROLE(),
            manager.QUALIFIER_ROLE(),
            manager.SCORE_REVEALER_ROLE()
        ];
        bool[8] memory granted;
        for (uint256 i; i < roles.length; ++i) {
            granted[i] = manager.hasRole(roles[i], GOVERNANCE);
        }
        return keccak256(
            abi.encode(
                manager.getCompetition(COMPETITION),
                manager.getSubmissionIdentity(SUBMISSION),
                manager.getSubmissionState(SUBMISSION),
                manager.getSubmissionComponents(SUBMISSION),
                manager.activeSubmissionByTrader(COMPETITION, trader),
                manager.traderNonces(trader),
                manager.competitionNonce(),
                manager.defaultAdmin(),
                manager.defaultAdminDelay(),
                manager.fheOperator(),
                address(manager.qualificationRegistry()),
                granted
            )
        );
    }
}
