// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    AlphaEngineConfidentialAssetRegistry
} from "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";
import {
    AlphaEngineConfidentialAssetGateway
} from "src/fherc20/AlphaEngineConfidentialAssetGateway.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {DeployAlphaEngineV2} from "script/DeployAlphaEngineV2.s.sol";
import {DeployAlphaEngineCreate2} from "script/DeployAlphaEngineCreate2.s.sol";
import {
    AlphaEngineCompetitionStrategyManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
import {AlphaEngineConfidentialSwapEscrow} from "src/swap/AlphaEngineConfidentialSwapEscrow.sol";
import {AlphaEngineV4SwapExecutor} from "src/executors/AlphaEngineV4SwapExecutor.sol";

contract Create2DeploymentHarness is DeployAlphaEngineCreate2 {
    function deployAs(DeploymentConfig memory config, address sender)
        external
        returns (Deployment memory deployment)
    {
        vm.startBroadcast(sender);
        deployment = deploy(config);
        vm.stopBroadcast();
    }

    function deployRawCode(string memory component, bytes memory code) external returns (address) {
        return _deployContract(component, code);
    }
}

/// @dev Separate build profile avoids changing the existing linked-library test fixtures.
contract DeployAlphaEngineCreate2Test is Test {
    address private constant TESTNET_DEPLOYER = 0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d;
    address private constant TESTNET_POOL = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;
    address private constant MAINNET_POOL = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    Create2DeploymentHarness private script;
    address private temporaryDeployer;
    DeployAlphaEngineV2.DeploymentConfig private config;

    function setUp() public {
        vm.skip(
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default")))) != keccak256("create2")
        );
        script = Create2DeploymentHarness(
            deployCode("DeployAlphaEngineCreate2.t.sol:Create2DeploymentHarness")
        );
        temporaryDeployer = vm.createWallet("create2-fork-only-deployer").addr;
        vm.etch(script.FACTORY(), script.FACTORY_RUNTIME());
        config = _config(address(new PoolManager(makeAddr("pool-owner"))));
    }

    function test_differentSendersAndNoncesKeepAllAddressesAndWiring() public {
        uint256 snapshot = vm.snapshotState();
        vm.setNonce(TESTNET_DEPLOYER, 123);
        DeployAlphaEngineV2.Deployment memory first = script.deployAs(config, TESTNET_DEPLOYER);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.chainId(42_161);
        config.expectedChainId = 42_161;
        vm.setNonce(temporaryDeployer, 7);
        DeployAlphaEngineV2.Deployment memory second = script.deployAs(config, temporaryDeployer);
        assertEq(abi.encode(first), abi.encode(second));
        _assertWiring(second);
    }

    function test_changedInitializerChangesProxyAddress() public {
        uint256 snapshot = vm.snapshotState();
        DeployAlphaEngineV2.Deployment memory first = script.deployAs(config, TESTNET_DEPLOYER);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        config.roles.pauser = makeAddr("different-pauser");
        DeployAlphaEngineV2.Deployment memory second = script.deployAs(config, temporaryDeployer);
        assertEq(first.competitionManagerImplementation, second.competitionManagerImplementation);
        assertNotEq(first.competitionManagerProxy, second.competitionManagerProxy);
    }

    function testFuzz_senderAndNonceDoNotAffectAddresses(address sender, uint64 nonce) public {
        vm.assume(sender != address(0) && sender != TESTNET_DEPLOYER && sender.code.length == 0);
        uint256 snapshot = vm.snapshotState();
        DeployAlphaEngineV2.Deployment memory first = script.deployAs(config, TESTNET_DEPLOYER);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.setNonce(sender, uint64(bound(nonce, 0, type(uint64).max - 32)));
        DeployAlphaEngineV2.Deployment memory second = script.deployAs(config, sender);
        assertEq(abi.encode(first), abi.encode(second));
    }

    function test_rejectsWrongChainBeforeLibraryDeployment() public {
        config.expectedChainId++;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAlphaEngineV2.UnexpectedChainId.selector,
                config.expectedChainId,
                block.chainid
            )
        );
        script.deploy(config);
        assertEq(_libraryAddress().code.length, 0);
    }

    function test_rejectsMainnetRoleCollapseBeforeLibraryDeployment() public {
        vm.chainId(42_161);
        config.expectedChainId = 42_161;
        config.metadata.testOnlyRoleCollapse = true;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAlphaEngineV2.TestOnlyRoleCollapseOnUnsupportedChain.selector, uint256(42_161)
            )
        );
        script.deploy(config);
        assertEq(_libraryAddress().code.length, 0);
    }

    function test_rejectsMissingOrChangedFactory() public {
        vm.etch(script.FACTORY(), hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAlphaEngineCreate2.InvalidCreate2Factory.selector, script.FACTORY().codehash
            )
        );
        script.deploy(config);
    }

    function test_rejectsOccupiedAddressAndNonce() public {
        address libraryAddress = _libraryAddress();
        vm.setNonce(libraryAddress, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAlphaEngineCreate2.Create2AddressOccupied.selector,
                "confidentialTokenLibrary",
                libraryAddress
            )
        );
        script.deploy(config);
    }

    function test_rejectsRedeployment() public {
        script.deployAs(config, TESTNET_DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAlphaEngineCreate2.Create2AddressOccupied.selector,
                "confidentialTokenLibrary",
                _libraryAddress()
            )
        );
        script.deploy(config);
    }

    function test_factoryFailureHasTypedError() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAlphaEngineCreate2.Create2DeploymentFailed.selector, "invalid", bytes("")
            )
        );
        script.deployRawCode("invalid", hex"fe");
    }

    function test_rejectsUnexpectedFactoryReturn() public {
        bytes memory code = hex"6001600c60003960016000f300";
        bytes memory returned = abi.encodePacked(makeAddr("incorrect-return"));
        vm.mockCall(
            script.FACTORY(), abi.encodePacked(script.componentSalt("bad-return"), code), returned
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAlphaEngineCreate2.Create2AddressMismatch.selector,
                "bad-return",
                script.predict("bad-return", code),
                returned
            )
        );
        script.deployRawCode("bad-return", code);
    }

    function test_manifestRetainsCandidateStatusAndDeterministicInputs() public {
        DeployAlphaEngineV2.Deployment memory deployment = script.deployAs(config, TESTNET_DEPLOYER);
        string memory path = "deployments/v2/rehearsals/create2-test.json";
        vm.createDir("deployments/v2/rehearsals", true);
        script.writeManifest(path, config, deployment);
        string memory manifest = vm.readFile(path);
        assertEq(vm.parseJsonAddress(manifest, ".create2Factory"), script.FACTORY());
        assertEq(vm.parseJsonBytes32(manifest, ".create2Namespace"), script.NAMESPACE());
        assertEq(
            vm.parseJsonBytes32(manifest, ".create2InitCodeHashes.confidentialTokenLibrary"),
            keccak256(vm.getCode("ERC20ConfidentialLib.sol:ERC20ConfidentialLib"))
        );
        assertEq(vm.parseJsonString(manifest, ".buildProfile"), "create2");
        assertFalse(vm.parseJsonBool(manifest, ".deploymentTransactionHashesRecorded"));
        assertEq(
            vm.parseJsonString(manifest, ".executionStatus"),
            "candidate-pending-receipt-reconciliation"
        );
        vm.removeFile(path);
    }

    function testFork_arbitrumNetworksWithDifferentDeployers() public {
        vm.skip(!vm.envOr("RUN_CREATE2_FORK", false));
        // Real factory and PoolManager code are read from each network, never etched here.
        uint256 testnet = vm.createFork(
            vm.envOr("CREATE2_TESTNET_RPC_URL", string("https://sepolia-rollup.arbitrum.io/rpc")),
            vm.envUint("CREATE2_TESTNET_FORK_BLOCK")
        );
        uint256 mainnet = vm.createFork(
            vm.envOr("CREATE2_MAINNET_RPC_URL", string("https://arb1.arbitrum.io/rpc")),
            vm.envUint("CREATE2_MAINNET_FORK_BLOCK")
        );
        vm.selectFork(testnet);
        script = Create2DeploymentHarness(
            deployCode("DeployAlphaEngineCreate2.t.sol:Create2DeploymentHarness")
        );
        config = _config(TESTNET_POOL);
        vm.deal(TESTNET_DEPLOYER, 10 ether);
        DeployAlphaEngineV2.Deployment memory first = script.deployAs(config, TESTNET_DEPLOYER);
        emit log_named_uint(
            "Arbitrum Sepolia RPC fork block", vm.envUint("CREATE2_TESTNET_FORK_BLOCK")
        );
        emit log_named_address("testnet sender", TESTNET_DEPLOYER);
        (address firstWrapper, address firstWrapperAdmin) = _forkWrapper(first, TESTNET_DEPLOYER);
        _writeForkManifest("testnet-fixture.json", first);
        vm.selectFork(mainnet);
        script = Create2DeploymentHarness(
            deployCode("DeployAlphaEngineCreate2.t.sol:Create2DeploymentHarness")
        );
        config = _config(MAINNET_POOL);
        vm.deal(temporaryDeployer, 10 ether);
        DeployAlphaEngineV2.Deployment memory second = script.deployAs(config, temporaryDeployer);
        emit log_named_uint("Arbitrum One RPC fork block", vm.envUint("CREATE2_MAINNET_FORK_BLOCK"));
        emit log_named_address("temporary mainnet sender", temporaryDeployer);
        (address secondWrapper, address secondWrapperAdmin) =
            _forkWrapper(second, temporaryDeployer);
        assertEq(firstWrapper, secondWrapper);
        assertEq(firstWrapperAdmin, secondWrapperAdmin);
        _writeForkManifest("mainnet-fixture.json", second);
        emit log_named_address(
            "wrapper proxy (both forks, different underlying tokens)", secondWrapper
        );
        _assertWiring(second);
        assertNotEq(first.swapExecutor, second.swapExecutor); // Network-specific PoolManager constructor.
        first.swapExecutor = second.swapExecutor;
        assertEq(abi.encode(first), abi.encode(second)); // All other 23 addresses, including 7 ProxyAdmins.
        emit log_named_address("competition proxy (both forks)", second.competitionManagerProxy);
        emit log_named_address("swap controller proxy (both forks)", second.swapControllerProxy);
        emit log_named_address("swap escrow proxy (both forks)", second.swapEscrowProxy);
    }

    function _forkWrapper(DeployAlphaEngineV2.Deployment memory deployment, address sender)
        private
        returns (address wrapper, address admin)
    {
        vm.startBroadcast(sender);
        MockERC20 underlying = new MockERC20("Fork-only token", "FORK", 6);
        vm.stopBroadcast();
        vm.prank(config.roles.assetRegistryOwner);
        wrapper = AlphaEngineConfidentialAssetRegistry(deployment.assetRegistry)
            .createWrapper(address(underlying), "Encrypted fork token", "eFORK", "");
        admin = address(
            uint160(
                uint256(
                    vm.load(
                        wrapper, 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
                    )
                )
            )
        );
        assertEq(ProxyAdmin(admin).owner(), config.roles.proxyAdminOwner);
    }

    function _writeForkManifest(
        string memory name,
        DeployAlphaEngineV2.Deployment memory deployment
    ) private {
        string memory directory = vm.envOr(
            "CREATE2_REHEARSAL_DIR",
            string("deployments/v2/rehearsals/create2-asset-upgrades-2026-10-14")
        );
        vm.createDir(directory, true);
        string memory path = string.concat(directory, "/", name);
        script.writeManifest(path, config, deployment);
        vm.writeJson('"fork-test-only-not-deployed"', path, ".executionStatus");
    }

    function _libraryAddress() private view returns (address) {
        return script.predict(
            "confidentialTokenLibrary", vm.getCode("ERC20ConfidentialLib.sol:ERC20ConfidentialLib")
        );
    }

    function _assertWiring(DeployAlphaEngineV2.Deployment memory deployment) private view {
        AlphaEngineCompetitionStrategyManager competition =
            AlphaEngineCompetitionStrategyManager(deployment.competitionManagerProxy);
        assertEq(
            AlphaEngineConfidentialAssetRegistry(deployment.assetRegistry).wrapperImplementation(),
            deployment.assetWrapperImplementation
        );
        assertEq(
            AlphaEngineConfidentialAssetRegistry(deployment.assetRegistry).owner(),
            config.roles.assetRegistryOwner
        );
        assertEq(
            AlphaEngineConfidentialAssetGateway(deployment.assetGateway).assetRegistry(),
            deployment.assetRegistry
        );
        assertTrue(competition.paused());
        assertEq(competition.submissionLimit(), 3);
        assertEq(competition.submissionWindowSeconds(), 300);
        assertEq(competition.defaultAdmin(), config.roles.defaultAdmin);
        assertEq(competition.fheOperator(), config.roles.competitionFheOperator);
        assertEq(
            address(competition.qualificationRegistry()), deployment.qualificationRegistryProxy
        );
        assertEq(
            AlphaEngineConfidentialSwapEscrow(deployment.swapEscrowProxy).swapController(),
            deployment.swapControllerProxy
        );
        assertEq(
            AlphaEngineConfidentialSwapEscrow(deployment.swapEscrowProxy).assetRegistry(),
            deployment.assetRegistry
        );
        assertEq(
            address(AlphaEngineV4SwapExecutor(deployment.swapExecutor).poolManager()),
            config.poolManager
        );
        address[7] memory admins = [
            deployment.assetRegistryProxyAdmin,
            deployment.assetGatewayProxyAdmin,
            deployment.qualificationRegistryProxyAdmin,
            deployment.competitionManagerProxyAdmin,
            deployment.capitalManagerProxyAdmin,
            deployment.swapControllerProxyAdmin,
            deployment.swapEscrowProxyAdmin
        ];
        for (uint256 i; i < admins.length; ++i) {
            assertEq(ProxyAdmin(admins[i]).owner(), config.roles.proxyAdminOwner);
        }
    }

    function _config(address pool)
        private
        returns (DeployAlphaEngineV2.DeploymentConfig memory result)
    {
        result.expectedChainId = block.chainid;
        result.poolManager = pool;
        result.roles = DeployAlphaEngineV2.RoleConfig({
            defaultAdmin: makeAddr("defaultAdmin"),
            proxyAdminOwner: makeAddr("proxyAdminOwner"),
            pauser: makeAddr("pauser"),
            qualificationRevoker: makeAddr("qualificationRevoker"),
            competitionFheOperator: makeAddr("competitionFheOperator"),
            competitionCreator: makeAddr("competitionCreator"),
            competitionCanceller: makeAddr("competitionCanceller"),
            competitionEvaluator: makeAddr("competitionEvaluator"),
            competitionFinalizer: makeAddr("competitionFinalizer"),
            competitionQualifier: makeAddr("competitionQualifier"),
            scoreRevealer: makeAddr("scoreRevealer"),
            capitalFheOperator: makeAddr("capitalFheOperator"),
            capitalEvaluator: makeAddr("capitalEvaluator"),
            capitalRevoker: makeAddr("capitalRevoker"),
            swapOperator: makeAddr("swapOperator"),
            assetRegistryOwner: makeAddr("assetRegistryOwner"),
            swapExecutorOwner: makeAddr("swapExecutorOwner")
        });
        result.metadata = DeployAlphaEngineV2.ArtifactMetadata({
            deploymentGitSha: "create2-fork-only",
            foundryVersion: "1.8.5",
            fhenixPackageRevision: "fixture",
            dependencyLockHash: keccak256("dependencies"),
            abiBundleHash: keccak256("abi"),
            storageLayoutBundleHash: keccak256("layout"),
            testOnlyRoleCollapse: false
        });
    }
}
