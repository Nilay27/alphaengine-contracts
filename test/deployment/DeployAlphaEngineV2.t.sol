// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    ERC20ConfidentialLib
} from "fhenix-confidential-contracts/ERC20Confidential/ERC20ConfidentialLib.sol";
import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {DeployAlphaEngineV2} from "script/DeployAlphaEngineV2.s.sol";
import {AlphaEngineV4SwapExecutor} from "src/executors/AlphaEngineV4SwapExecutor.sol";
import {
    AlphaEngineConfidentialAssetGateway
} from "src/fherc20/AlphaEngineConfidentialAssetGateway.sol";
import {
    AlphaEngineCapitalStrategyManager
} from "src/strategy/AlphaEngineCapitalStrategyManager.sol";
import {
    AlphaEngineCompetitionStrategyManager
} from "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
import {
    AlphaEngineTraderQualificationRegistry
} from "src/strategy/AlphaEngineTraderQualificationRegistry.sol";
import {
    AlphaEngineConfidentialSwapController
} from "src/swap/AlphaEngineConfidentialSwapController.sol";
import {AlphaEngineConfidentialSwapEscrow} from "src/swap/AlphaEngineConfidentialSwapEscrow.sol";

contract DeployAlphaEngineV2Test is Test {
    DeployAlphaEngineV2 private deployer;
    PoolManager private poolManager;

    address private defaultAdmin = makeAddr("defaultAdmin");
    address private proxyAdminOwner = makeAddr("proxyAdminOwner");

    function setUp() public {
        deployer = new DeployAlphaEngineV2();
        poolManager = new PoolManager(makeAddr("poolManagerOwner"));
    }

    function test_deploysFreshPausedDomainsWithIndependentAdministration() public {
        DeployAlphaEngineV2.DeploymentConfig memory config = _config();
        DeployAlphaEngineV2.Deployment memory deployment = deployer.deploy(config);

        AlphaEngineTraderQualificationRegistry qualification =
            AlphaEngineTraderQualificationRegistry(deployment.qualificationRegistryProxy);
        AlphaEngineCompetitionStrategyManager competition =
            AlphaEngineCompetitionStrategyManager(deployment.competitionManagerProxy);
        AlphaEngineCapitalStrategyManager capital =
            AlphaEngineCapitalStrategyManager(deployment.capitalManagerProxy);
        AlphaEngineConfidentialSwapController controller =
            AlphaEngineConfidentialSwapController(deployment.swapControllerProxy);
        AlphaEngineConfidentialSwapEscrow escrow =
            AlphaEngineConfidentialSwapEscrow(deployment.swapEscrowProxy);

        assertEq(deployment.confidentialTokenLibrary, address(ERC20ConfidentialLib));
        assertGt(deployment.confidentialTokenLibrary.code.length, 0);
        assertTrue(qualification.paused());
        assertTrue(competition.paused());
        assertTrue(capital.paused());
        assertTrue(controller.paused());
        assertTrue(escrow.paused());
        assertEq(address(competition.qualificationRegistry()), address(qualification));
        assertEq(address(capital.qualificationRegistry()), address(qualification));
        assertEq(escrow.swapController(), address(controller));
        assertEq(escrow.assetRegistry(), deployment.assetRegistry);
        assertEq(
            AlphaEngineConfidentialAssetGateway(deployment.assetGateway).assetRegistry(),
            deployment.assetRegistry
        );

        AlphaEngineV4SwapExecutor executor = AlphaEngineV4SwapExecutor(deployment.swapExecutor);
        assertEq(address(executor.poolManager()), address(poolManager));
        assertEq(executor.authorizedCaller(), address(escrow));
        assertEq(executor.owner(), config.roles.swapExecutorOwner);
        assertEq(controller.swapEscrow(), address(0));
        assertEq(controller.swapExecutor(), address(0));

        address[5] memory admins = [
            deployment.qualificationRegistryProxyAdmin,
            deployment.competitionManagerProxyAdmin,
            deployment.capitalManagerProxyAdmin,
            deployment.swapControllerProxyAdmin,
            deployment.swapEscrowProxyAdmin
        ];
        for (uint256 i; i < admins.length; ++i) {
            assertEq(ProxyAdmin(admins[i]).owner(), proxyAdminOwner);
            for (uint256 j = i + 1; j < admins.length; ++j) {
                assertNotEq(admins[i], admins[j]);
            }
        }
    }

    function test_adminActionsAreExplicitDeterministicAndComplete() public {
        DeployAlphaEngineV2.DeploymentConfig memory config = _config();
        DeployAlphaEngineV2.Deployment memory deployment = deployer.deploy(config);
        (address[] memory targets, bytes[] memory data) =
            deployer.buildAdminActions(deployment, config);

        assertEq(targets.length, 11);
        assertEq(data.length, 11);
        assertEq(
            deployer.adminActionsHash(deployment, config), keccak256(abi.encode(targets, data))
        );

        for (uint256 i; i < targets.length; ++i) {
            vm.prank(i == 10 ? config.roles.assetRegistryOwner : defaultAdmin);
            (bool success, bytes memory returnData) = targets[i].call(data[i]);
            if (!success) _bubble(returnData);
        }

        AlphaEngineTraderQualificationRegistry qualification =
            AlphaEngineTraderQualificationRegistry(deployment.qualificationRegistryProxy);
        AlphaEngineCompetitionStrategyManager competition =
            AlphaEngineCompetitionStrategyManager(deployment.competitionManagerProxy);
        AlphaEngineCapitalStrategyManager capital =
            AlphaEngineCapitalStrategyManager(deployment.capitalManagerProxy);
        AlphaEngineConfidentialSwapController controller =
            AlphaEngineConfidentialSwapController(deployment.swapControllerProxy);

        assertTrue(
            qualification.hasRole(
                qualification.QUALIFICATION_ISSUER_ROLE(), deployment.competitionManagerProxy
            )
        );
        assertTrue(
            competition.hasRole(
                competition.COMPETITION_CREATOR_ROLE(), config.roles.competitionCreator
            )
        );
        assertTrue(
            competition.hasRole(competition.EVALUATOR_ROLE(), config.roles.competitionEvaluator)
        );
        assertTrue(capital.hasRole(capital.EVALUATOR_ROLE(), config.roles.capitalEvaluator));
        assertTrue(capital.hasRole(capital.REVOCER_ROLE(), config.roles.capitalRevoker));
        assertEq(controller.swapEscrow(), deployment.swapEscrowProxy);
        assertEq(controller.swapExecutor(), deployment.swapExecutor);
    }

    function test_revertsOnWrongChain() public {
        DeployAlphaEngineV2.DeploymentConfig memory config = _config();
        config.expectedChainId = block.chainid + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAlphaEngineV2.UnexpectedChainId.selector,
                config.expectedChainId,
                block.chainid
            )
        );
        deployer.deploy(config);
    }

    function test_revertsOnNonContractPoolManager() public {
        DeployAlphaEngineV2.DeploymentConfig memory config = _config();
        config.poolManager = makeAddr("notAContract");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAlphaEngineV2.InvalidPoolManager.selector, config.poolManager
            )
        );
        deployer.deploy(config);
    }

    function test_revertsWhenLinkedLibraryHasNoCode() public {
        DeployAlphaEngineV2.DeploymentConfig memory config = _config();
        vm.etch(address(ERC20ConfidentialLib), "");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAlphaEngineV2.MissingConfidentialTokenLibrary.selector,
                address(ERC20ConfidentialLib)
            )
        );
        deployer.deploy(config);
    }

    function test_revertsOnProductionRoleOverlap() public {
        DeployAlphaEngineV2.DeploymentConfig memory config = _config();
        config.roles.capitalEvaluator = config.roles.defaultAdmin;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAlphaEngineV2.RoleOverlap.selector,
                bytes32("ADMIN_CAP_EVALUATOR"),
                config.roles.defaultAdmin
            )
        );
        deployer.deploy(config);
    }

    function test_allowsExplicitTestOnlyRoleCollapse() public {
        DeployAlphaEngineV2.DeploymentConfig memory config = _config();
        config.roles.capitalEvaluator = config.roles.defaultAdmin;
        config.metadata.testOnlyRoleCollapse = true;
        DeployAlphaEngineV2.Deployment memory deployment = deployer.deploy(config);
        assertTrue(deployment.capitalManagerProxy.code.length != 0);
    }

    function test_revertsOnMissingArtifactMetadata() public {
        DeployAlphaEngineV2.DeploymentConfig memory config = _config();
        config.metadata.dependencyLockHash = bytes32(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAlphaEngineV2.MissingArtifactMetadata.selector,
                bytes32("DEPENDENCY_LOCK_HASH")
            )
        );
        deployer.deploy(config);
    }

    function test_manifestRecordsReplayAndHistoricalEvidence() public {
        DeployAlphaEngineV2.DeploymentConfig memory config = _config();
        DeployAlphaEngineV2.Deployment memory deployment = deployer.deploy(config);
        string memory path = "cache/alphaengine-v2-stage-9-manifest.json";
        deployer.writeManifest(path, config, deployment);
        string memory manifest = vm.readFile(path);

        assertEq(vm.parseJsonString(manifest, ".cofheContractsVersion"), "0.2.0");
        assertEq(vm.parseJsonString(manifest, ".confidentialContractsVersion"), "0.4.0");
        assertEq(vm.parseJsonString(manifest, ".contractApiRevision"), "v2-cofhe-0.2");
        assertEq(
            vm.parseJsonAddress(manifest, ".confidentialTokenLibrary"),
            address(ERC20ConfidentialLib)
        );
        assertEq(
            vm.parseJsonBytes32(manifest, ".confidentialTokenLibraryCodeHash"),
            address(ERC20ConfidentialLib).codehash
        );
        assertEq(vm.parseJsonUint(manifest, ".schemaVersion"), 2);
        assertEq(vm.parseJsonUint(manifest, ".chainId"), block.chainid);
        assertEq(
            vm.parseJsonString(manifest, ".legacyManifestPath"),
            "deployments/arbitrum-sepolia-latest.json"
        );
        assertEq(
            vm.parseJsonString(manifest, ".legacyManifestSha256"),
            "e35253ff1c1aaa16e67cf6543942332031ac1691392bb578a07ca6fa2c5aa7e2"
        );
        assertEq(
            vm.parseJsonAddress(manifest, ".qualificationRegistryProxy"),
            deployment.qualificationRegistryProxy
        );
        assertEq(vm.parseJsonAddress(manifest, ".swapExecutor"), deployment.swapExecutor);
        assertEq(
            vm.parseJsonBytes32(manifest, ".adminActionsHash"),
            deployer.adminActionsHash(deployment, config)
        );
        assertEq(vm.parseJsonString(manifest, ".fundVaultStatus"), "not-implemented");
    }

    function _config() private returns (DeployAlphaEngineV2.DeploymentConfig memory config) {
        config.expectedChainId = block.chainid;
        config.poolManager = address(poolManager);
        config.roles = DeployAlphaEngineV2.RoleConfig({
            defaultAdmin: defaultAdmin,
            proxyAdminOwner: proxyAdminOwner,
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
        config.metadata = DeployAlphaEngineV2.ArtifactMetadata({
            deploymentGitSha: "stage-9-test",
            foundryVersion: "1.7.1",
            fhenixPackageRevision: "test-revision",
            dependencyLockHash: keccak256("dependency-lock"),
            abiBundleHash: keccak256("abi-bundle"),
            storageLayoutBundleHash: keccak256("storage-layout-bundle"),
            testOnlyRoleCollapse: false
        });
    }

    function _bubble(bytes memory returnData) private pure {
        assembly ("memory-safe") {
            revert(add(returnData, 0x20), mload(returnData))
        }
    }
}
