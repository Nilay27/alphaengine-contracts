// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
    AlphaEngineCompetitionStrategyManager as CompetitionManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";

/// @notice Upgrade the recorded Arena proxy and set its current round's capacity to 512.
contract UpgradeCompetitionCapacity is Script {
    bytes32 private constant IMPLEMENTATION_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 private constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    uint16 private constant CAPACITY = 512;

    struct Target {
        address proxy;
        address proxyAdmin;
        address owner;
        address oldImplementation;
        bytes32 oldCodeHash;
        bytes32 competitionId;
    }

    error WrongChain(uint256 actual, uint256 expected);
    error UnsupportedChain(uint256 chainId);
    error WrongSender(address actual, address expected);
    error UnexpectedProxyAdmin(address actual);
    error UnexpectedImplementation(address actual);
    error UnexpectedAuthority(address owner);
    error ManagerAlreadyPaused();
    error RoundNotOpen(bytes32 competitionId);
    error UnexpectedCapacity(bytes32 competitionId, uint16 actual);

    function run(uint256 expectedChainId) external returns (address implementation) {
        if (block.chainid != expectedChainId) revert WrongChain(block.chainid, expectedChainId);
        Target memory target = _target(expectedChainId);
        if (msg.sender != target.owner) revert WrongSender(msg.sender, target.owner);
        CompetitionManager manager = CompetitionManager(target.proxy);
        ProxyAdmin proxyAdmin = ProxyAdmin(target.proxyAdmin);
        address actualAdmin = _slotAddress(target.proxy, ADMIN_SLOT);
        if (actualAdmin != target.proxyAdmin) revert UnexpectedProxyAdmin(actualAdmin);
        address oldImplementation = _slotAddress(target.proxy, IMPLEMENTATION_SLOT);
        if (
            oldImplementation != target.oldImplementation
                || oldImplementation.codehash != target.oldCodeHash
        ) revert UnexpectedImplementation(oldImplementation);
        if (
            proxyAdmin.owner() != target.owner || manager.defaultAdmin() != target.owner
                || !manager.hasRole(manager.PAUSER_ROLE(), target.owner)
        ) revert UnexpectedAuthority(target.owner);
        if (manager.paused()) revert ManagerAlreadyPaused();
        CompetitionManager.CompetitionRecord memory competition =
            manager.getCompetition(target.competitionId);
        if (
            competition.status != CompetitionManager.CompetitionStatus.Active
                || block.timestamp >= competition.submissionDeadline
        ) revert RoundNotOpen(target.competitionId);

        console2.log("Chain", expectedChainId);
        console2.log("Competition proxy", target.proxy);
        console2.log("Round");
        console2.logBytes32(target.competitionId);
        console2.log("Active submissions", competition.activeSubmissionCount);
        console2.log("New capacity", CAPACITY);

        vm.startBroadcast(target.owner);
        implementation = address(new CompetitionManager());
        manager.pause();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(target.proxy), implementation, "");
        manager.setCompetitionCapacity(target.competitionId, CAPACITY);
        manager.unpause();
        vm.stopBroadcast();

        uint16 capacity = manager.getCompetitionCapacity(target.competitionId);
        if (capacity != CAPACITY) revert UnexpectedCapacity(target.competitionId, capacity);
        console2.log("Implementation", implementation);
        console2.log("Implementation runtime hash");
        console2.logBytes32(implementation.codehash);
    }

    function _slotAddress(address proxy, bytes32 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, slot))));
    }

    function _target(uint256 chainId) private pure returns (Target memory) {
        if (chainId == 421_614) {
            return Target({
                proxy: 0x9CBF3917Ff31E41393e5D992b3bdbf1fC9C80744,
                proxyAdmin: 0x4e3841A9e383850bD238377f3471205Ba21ded8c,
                owner: 0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d,
                oldImplementation: 0xfc81Bf4d378dC526894Bc7A132064f204d922361,
                oldCodeHash: 0x0a1fdbbe9c2384dd34b0ea647fb160d9b09f4b4aa9b63f77beaef0adb2165c76,
                competitionId: 0x5e361d7809649fb68530babe18e33537abf553d09b986b38889f606cea1cb317
            });
        }
        if (chainId == 42_161) {
            return Target({
                proxy: 0x7fFcDa0A08401AcF1d114C83B32cE439C48c3681,
                proxyAdmin: 0x0D4CbA28056f6D4C5d06C1E0d87e9F8A55C0cae0,
                owner: 0xAcc08cBbeD784Ba9b5B07ADb5F0E299Cb0fD3d95,
                oldImplementation: 0xA0e845476674Ad39319761f55dEbfba30CFcE1E0,
                oldCodeHash: 0x9f78e935c2bc6ad09cb062bba9dcb76861f56de3aeffb91dce9de87bcc58eb8a,
                competitionId: 0xda6ffb7ec090a3eb2c19f17f18e3c22e96b19b23f7043f5e56ac04f2e9aea708
            });
        }
        revert UnsupportedChain(chainId);
    }
}
