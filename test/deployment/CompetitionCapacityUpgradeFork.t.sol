// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {externalEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeCompetitionCapacity} from "script/UpgradeCompetitionCapacity.s.sol";
import {
    AlphaEngineCompetitionStrategyManager as CompetitionManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";

contract CompetitionCapacityUpgradeForkTest is MockCoFheTest {
    bytes32 private constant IMPLEMENTATION_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 private constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 private constant TIMEFRAME = keccak256("1h");

    function test_scriptRejectsWrongChain() public {
        vm.chainId(42_161);
        UpgradeCompetitionCapacity script = new UpgradeCompetitionCapacity();
        vm.expectRevert(
            abi.encodeWithSelector(UpgradeCompetitionCapacity.WrongChain.selector, 42_161, 421_614)
        );
        script.run(421_614);
    }

    function test_scriptRejectsUnsupportedChainAndWrongSigner() public {
        UpgradeCompetitionCapacity script = new UpgradeCompetitionCapacity();
        vm.chainId(1);
        vm.expectRevert(
            abi.encodeWithSelector(UpgradeCompetitionCapacity.UnsupportedChain.selector, 1)
        );
        script.run(1);
        vm.chainId(421_614);
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeCompetitionCapacity.WrongSender.selector,
                address(this),
                0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d
            )
        );
        script.run(421_614);
    }

    function test_sepoliaCapacityUpgradePreservesStateAndAdmits257thWallet() public {
        vm.skip(!vm.envOr("RUN_COMPETITION_CAPACITY_FORKS", false));
        vm.createSelectFork("arbitrum_sepolia", 328_186_235);
        _rehearse(
            CompetitionManager(0x9CBF3917Ff31E41393e5D992b3bdbf1fC9C80744),
            0x5e361d7809649fb68530babe18e33537abf553d09b986b38889f606cea1cb317,
            0x7fd99c6d9518b697a201dedd3955603b72449ad3e867628cc8187f978bd9813d,
            0xf8457c1e797a47b1c5416bdeb133d0aba030329852abbb29a667c46944adafb5,
            421_614,
            256
        );
    }

    function test_mainnetCapacityUpgradePreservesStateAndAdmitsNewWallet() public {
        vm.skip(!vm.envOr("RUN_COMPETITION_CAPACITY_FORKS", false));
        vm.createSelectFork("arbitrum", 523_276_406);
        _rehearse(
            CompetitionManager(0x7fFcDa0A08401AcF1d114C83B32cE439C48c3681),
            0xda6ffb7ec090a3eb2c19f17f18e3c22e96b19b23f7043f5e56ac04f2e9aea708,
            0xfdb35917be05418b47908b8f046d23815fb50c02375323c39d9cf94b9bb46618,
            0x5aac22ced359b9c807ae54863b18a5ba9d16f67084af8a2c01b94292881d84d6,
            42_161,
            95
        );
    }

    function _rehearse(
        CompetitionManager manager,
        bytes32 round,
        bytes32 earlierRound,
        bytes32 historicalSubmission,
        uint256 chainId,
        uint16 activeCount
    ) private {
        assertEq(block.chainid, chainId);
        assertEq(manager.getCompetition(round).activeSubmissionCount, activeCount);
        assertEq(manager.MAX_ACTIVE_SUBMISSIONS(), 256);
        assertEq(manager.submissionLimit(), 3);
        assertEq(manager.submissionWindowSeconds(), 300);
        address wallet = manager.getSubmissionIdentity(historicalSubmission).trader;
        assertEq(manager.activeSubmissionByTrader(round, wallet), historicalSubmission);

        address newcomer = makeAddr("capacity-new-wallet");
        if (activeCount == 256) {
            externalEuint128[] memory components = new externalEuint128[](1);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CompetitionManager.MaximumActiveSubmissionsReached.selector, round
                )
            );
            vm.prank(newcomer);
            manager.submitCompetitionStrategy(
                round, TIMEFRAME, externalEuint128.wrap(bytes32(0)), components, ""
            );
        }

        // Preserve the real proxy and existing records. Mock only CoFHE to create
        // fresh encrypted inputs and fill the wallet's rolling allowance on the fork.
        _installMockTaskManager();
        _submit(manager, round, wallet, 1);
        _submit(manager, round, wallet, 2);
        bytes32 latest = _submit(manager, round, wallet, 3);
        (bool allowed, uint256 nextAllowedAt) = manager.getSubmissionAllowance(wallet);
        assertFalse(allowed);
        assertEq(nextAllowedAt, block.timestamp + 300);
        bytes32 stateBefore =
            _stateHash(manager, round, earlierRound, wallet, latest, historicalSubmission);

        address owner = manager.defaultAdmin();
        address implementation = address(new CompetitionManager());
        ProxyAdmin proxyAdmin =
            ProxyAdmin(address(uint160(uint256(vm.load(address(manager), ADMIN_SLOT)))));
        assertEq(proxyAdmin.owner(), owner);
        vm.startPrank(owner);
        manager.pause();
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(manager)), implementation, ""
        );
        assertEq(manager.getCompetitionCapacity(round), 256);
        manager.setCompetitionCapacity(round, 512);
        manager.unpause();
        vm.stopPrank();
        assertEq(
            vm.load(address(manager), IMPLEMENTATION_SLOT),
            bytes32(uint256(uint160(implementation)))
        );
        assertFalse(manager.paused());
        assertEq(manager.getCompetitionCapacity(round), 512);
        assertEq(manager.getCompetitionCapacity(earlierRound), 256);
        assertEq(
            _stateHash(manager, round, earlierRound, wallet, latest, historicalSubmission),
            stateBefore
        );
        (bool allowedAfter, uint256 nextAllowedAtAfter) = manager.getSubmissionAllowance(wallet);
        assertFalse(allowedAfter);
        assertEq(nextAllowedAtAfter, nextAllowedAt);

        _submit(manager, round, newcomer, 4);
        assertEq(manager.getCompetition(round).activeSubmissionCount, activeCount + 1);
        vm.warp(nextAllowedAt);
        bytes32 replacement = _submit(manager, round, wallet, 5);
        assertEq(manager.activeSubmissionByTrader(round, wallet), replacement);
        assertEq(
            uint8(manager.getSubmissionState(latest).status),
            uint8(CompetitionManager.SubmissionStatus.Superseded)
        );
        assertEq(manager.getCompetition(round).activeSubmissionCount, activeCount + 1);
    }

    function _stateHash(
        CompetitionManager manager,
        bytes32 round,
        bytes32 earlierRound,
        address wallet,
        bytes32 latest,
        bytes32 historical
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                manager.getCompetition(round),
                manager.getCompetition(earlierRound),
                manager.activeSubmissionByTrader(round, wallet),
                manager.traderNonces(wallet),
                _submissionHash(manager, latest),
                _submissionHash(manager, historical),
                _settingsHash(manager)
            )
        );
    }

    function _submissionHash(CompetitionManager manager, bytes32 submission)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                manager.getSubmissionIdentity(submission),
                manager.getSubmissionState(submission),
                manager.getSubmissionComponents(submission)
            )
        );
    }

    function _settingsHash(CompetitionManager manager) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                manager.defaultAdmin(),
                manager.fheOperator(),
                manager.qualificationRegistry(),
                manager.submissionLimit(),
                manager.submissionWindowSeconds(),
                manager.competitionNonce()
            )
        );
    }

    function _submit(CompetitionManager manager, bytes32 round, address wallet, uint128 marketId)
        private
        returns (bytes32)
    {
        externalEuint128 market = createExternalEuint128(marketId, wallet);
        externalEuint128[] memory components = new externalEuint128[](1);
        components[0] = createExternalEuint128(101, wallet);
        bytes memory proof = _strategyProof(address(manager), market, components);
        vm.prank(wallet);
        return manager.submitCompetitionStrategy(round, TIMEFRAME, market, components, proof);
    }
}
