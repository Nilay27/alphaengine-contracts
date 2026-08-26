// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AlphaEngineV4SwapExecutor} from "src/executors/AlphaEngineV4SwapExecutor.sol";
import {AlphaEngineConfidentialAssetGateway} from
    "src/fherc20/AlphaEngineConfidentialAssetGateway.sol";
import {AlphaEngineConfidentialAssetRegistry} from
    "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";
import {IAlphaEngineConfidentialAssetRegistry} from
    "src/interfaces/IAlphaEngineConfidentialAssetRegistry.sol";
import {AlphaEngineCapitalStrategyManager} from "src/strategy/AlphaEngineCapitalStrategyManager.sol";
import {AlphaEngineCompetitionStrategyManager} from
    "src/strategy/AlphaEngineCompetitionStrategyManager.sol";
import {AlphaEngineTraderQualificationRegistry} from
    "src/strategy/AlphaEngineTraderQualificationRegistry.sol";
import {AlphaEngineConfidentialSwapController} from
    "src/swap/AlphaEngineConfidentialSwapController.sol";
import {AlphaEngineConfidentialSwapEscrow} from "src/swap/AlphaEngineConfidentialSwapEscrow.sol";

/// @title DeployAlphaEngineV2
/// @notice Deploys the first-pass AlphaEngine v2 contracts in a paused, unfunded state.
/// @dev No public network deployment is performed by repository validation. Operational role
///      grants and reciprocal swap configuration are emitted as explicit delayed-admin actions.
contract DeployAlphaEngineV2 is Script {
    uint256 public constant SCHEMA_VERSION = 2;
    string public constant BASELINE_GIT_SHA = "49d96e8a80d6903d1d30affc6f836bcc0ac13800";
    string public constant LEGACY_MANIFEST_PATH = "deployments/arbitrum-sepolia-latest.json";
    string public constant LEGACY_MANIFEST_SHA256 =
        "e35253ff1c1aaa16e67cf6543942332031ac1691392bb578a07ca6fa2c5aa7e2";
    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 internal constant COMPETITION_CREATOR_ROLE = keccak256("COMPETITION_CREATOR_ROLE");
    bytes32 internal constant COMPETITION_CANCELLER_ROLE = keccak256("COMPETITION_CANCELLER_ROLE");
    bytes32 internal constant EVALUATOR_ROLE = keccak256("EVALUATOR_ROLE");
    bytes32 internal constant FINALIZER_ROLE = keccak256("FINALIZER_ROLE");
    bytes32 internal constant QUALIFIER_ROLE = keccak256("QUALIFIER_ROLE");
    bytes32 internal constant SCORE_REVEALER_ROLE = keccak256("SCORE_REVEALER_ROLE");
    bytes32 internal constant QUALIFICATION_ISSUER_ROLE = keccak256("QUALIFICATION_ISSUER_ROLE");
    bytes32 internal constant REVOCER_ROLE = keccak256("REVOCER_ROLE");

    struct RoleConfig {
        address defaultAdmin;
        address proxyAdminOwner;
        address pauser;
        address qualificationRevoker;
        address competitionFheOperator;
        address competitionCreator;
        address competitionCanceller;
        address competitionEvaluator;
        address competitionFinalizer;
        address competitionQualifier;
        address scoreRevealer;
        address capitalFheOperator;
        address capitalEvaluator;
        address capitalRevoker;
        address swapOperator;
        address assetRegistryOwner;
        address swapExecutorOwner;
    }

    struct ArtifactMetadata {
        string deploymentGitSha;
        string foundryVersion;
        string fhenixPackageRevision;
        bytes32 dependencyLockHash;
        bytes32 abiBundleHash;
        bytes32 storageLayoutBundleHash;
        bool testOnlyRoleCollapse;
    }

    struct DeploymentConfig {
        uint256 expectedChainId;
        address poolManager;
        RoleConfig roles;
        ArtifactMetadata metadata;
    }

    struct Deployment {
        address qualificationRegistryImplementation;
        address qualificationRegistryProxy;
        address qualificationRegistryProxyAdmin;
        address competitionManagerImplementation;
        address competitionManagerProxy;
        address competitionManagerProxyAdmin;
        address capitalManagerImplementation;
        address capitalManagerProxy;
        address capitalManagerProxyAdmin;
        address assetRegistry;
        address assetGateway;
        address swapControllerImplementation;
        address swapControllerProxy;
        address swapControllerProxyAdmin;
        address swapEscrowImplementation;
        address swapEscrowProxy;
        address swapEscrowProxyAdmin;
        address swapExecutor;
    }

    error UnexpectedChainId(uint256 expectedChainId, uint256 actualChainId);
    error ZeroConfigurationAddress(bytes32 field);
    error InvalidPoolManager(address poolManager);
    error RoleOverlap(bytes32 relationship, address holder);
    error MissingArtifactMetadata(bytes32 field);

    function run() external returns (Deployment memory deployment) {
        DeploymentConfig memory config = _readConfig();
        string memory manifestPath =
            vm.envOr("DEPLOYMENT_MANIFEST", string("deployments/v2/local-latest.json"));

        vm.startBroadcast();
        deployment = deploy(config);
        vm.stopBroadcast();

        writeManifest(manifestPath, config, deployment);
        _logDeployment(deployment, manifestPath);
    }

    function deploy(DeploymentConfig memory config) public returns (Deployment memory deployment) {
        _validateConfig(config);

        AlphaEngineConfidentialAssetRegistry assetRegistry =
            new AlphaEngineConfidentialAssetRegistry(config.roles.assetRegistryOwner);
        AlphaEngineConfidentialAssetGateway assetGateway = new AlphaEngineConfidentialAssetGateway(
            IAlphaEngineConfidentialAssetRegistry(address(assetRegistry))
        );

        (
            AlphaEngineTraderQualificationRegistry qualificationRegistryImplementation,
            AlphaEngineTraderQualificationRegistry qualificationRegistry,
            address qualificationRegistryProxyAdmin
        ) = _deployQualificationRegistry(config);

        (
            AlphaEngineCompetitionStrategyManager competitionManagerImplementation,
            AlphaEngineCompetitionStrategyManager competitionManager,
            address competitionManagerProxyAdmin
        ) = _deployCompetitionManager(config, address(qualificationRegistry));

        (
            AlphaEngineCapitalStrategyManager capitalManagerImplementation,
            AlphaEngineCapitalStrategyManager capitalManager,
            address capitalManagerProxyAdmin
        ) = _deployCapitalManager(config, address(qualificationRegistry));

        (
            AlphaEngineConfidentialSwapController swapControllerImplementation,
            AlphaEngineConfidentialSwapController swapController,
            address swapControllerProxyAdmin
        ) = _deploySwapController(config);

        (
            AlphaEngineConfidentialSwapEscrow swapEscrowImplementation,
            AlphaEngineConfidentialSwapEscrow swapEscrow,
            address swapEscrowProxyAdmin
        ) = _deploySwapEscrow(config, address(swapController), address(assetRegistry));

        AlphaEngineV4SwapExecutor swapExecutor = new AlphaEngineV4SwapExecutor(
            IPoolManager(config.poolManager), config.roles.swapExecutorOwner, address(swapEscrow)
        );

        deployment = Deployment({
            qualificationRegistryImplementation: address(qualificationRegistryImplementation),
            qualificationRegistryProxy: address(qualificationRegistry),
            qualificationRegistryProxyAdmin: qualificationRegistryProxyAdmin,
            competitionManagerImplementation: address(competitionManagerImplementation),
            competitionManagerProxy: address(competitionManager),
            competitionManagerProxyAdmin: competitionManagerProxyAdmin,
            capitalManagerImplementation: address(capitalManagerImplementation),
            capitalManagerProxy: address(capitalManager),
            capitalManagerProxyAdmin: capitalManagerProxyAdmin,
            assetRegistry: address(assetRegistry),
            assetGateway: address(assetGateway),
            swapControllerImplementation: address(swapControllerImplementation),
            swapControllerProxy: address(swapController),
            swapControllerProxyAdmin: swapControllerProxyAdmin,
            swapEscrowImplementation: address(swapEscrowImplementation),
            swapEscrowProxy: address(swapEscrow),
            swapEscrowProxyAdmin: swapEscrowProxyAdmin,
            swapExecutor: address(swapExecutor)
        });
    }

    /// @notice Returns the exact delayed-admin calls required after deployment verification.
    /// @dev The caller executes these through the configured governance Safe/timelock. This
    ///      function never grants the deployment script authority over a production contract.
    function buildAdminActions(Deployment memory deployment, DeploymentConfig memory config)
        public
        pure
        returns (address[] memory targets, bytes[] memory data)
    {
        targets = new address[](10);
        data = new bytes[](10);
        uint256 index;

        targets[index] = deployment.qualificationRegistryProxy;
        data[index++] = abi.encodeCall(
            IAccessControl.grantRole,
            (QUALIFICATION_ISSUER_ROLE, deployment.competitionManagerProxy)
        );

        targets[index] = deployment.competitionManagerProxy;
        data[index++] = abi.encodeCall(
            IAccessControl.grantRole, (COMPETITION_CREATOR_ROLE, config.roles.competitionCreator)
        );
        targets[index] = deployment.competitionManagerProxy;
        data[index++] = abi.encodeCall(
            IAccessControl.grantRole,
            (COMPETITION_CANCELLER_ROLE, config.roles.competitionCanceller)
        );
        targets[index] = deployment.competitionManagerProxy;
        data[index++] = abi.encodeCall(
            IAccessControl.grantRole, (EVALUATOR_ROLE, config.roles.competitionEvaluator)
        );
        targets[index] = deployment.competitionManagerProxy;
        data[index++] = abi.encodeCall(
            IAccessControl.grantRole, (FINALIZER_ROLE, config.roles.competitionFinalizer)
        );
        targets[index] = deployment.competitionManagerProxy;
        data[index++] = abi.encodeCall(
            IAccessControl.grantRole, (QUALIFIER_ROLE, config.roles.competitionQualifier)
        );
        targets[index] = deployment.competitionManagerProxy;
        data[index++] = abi.encodeCall(
            IAccessControl.grantRole, (SCORE_REVEALER_ROLE, config.roles.scoreRevealer)
        );

        targets[index] = deployment.capitalManagerProxy;
        data[index++] = abi.encodeCall(
            IAccessControl.grantRole, (EVALUATOR_ROLE, config.roles.capitalEvaluator)
        );
        targets[index] = deployment.capitalManagerProxy;
        data[index++] =
            abi.encodeCall(IAccessControl.grantRole, (REVOCER_ROLE, config.roles.capitalRevoker));

        targets[index] = deployment.swapControllerProxy;
        data[index] = abi.encodeCall(
            AlphaEngineConfidentialSwapController.setSwapConfiguration,
            (deployment.swapEscrowProxy, deployment.swapExecutor)
        );
    }

    function adminActionsHash(Deployment memory deployment, DeploymentConfig memory config)
        public
        pure
        returns (bytes32)
    {
        (address[] memory targets, bytes[] memory data) = buildAdminActions(deployment, config);
        return keccak256(abi.encode(targets, data));
    }

    function writeManifest(
        string memory manifestPath,
        DeploymentConfig memory config,
        Deployment memory deployment
    ) public {
        string memory object = "alphaEngineV2";
        vm.serializeUint(object, "schemaVersion", SCHEMA_VERSION);
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeUint(object, "deploymentBlock", block.number);
        vm.serializeString(object, "baselineGitSha", BASELINE_GIT_SHA);
        vm.serializeString(object, "deploymentGitSha", config.metadata.deploymentGitSha);
        vm.serializeString(object, "compilerVersion", "0.8.26");
        vm.serializeString(object, "foundryVersion", config.metadata.foundryVersion);
        vm.serializeBool(object, "optimizerEnabled", true);
        vm.serializeUint(object, "optimizerRuns", 200);
        vm.serializeString(object, "evmVersion", "cancun");
        vm.serializeString(object, "fhenixPackageRevision", config.metadata.fhenixPackageRevision);
        vm.serializeBytes32(object, "dependencyLockHash", config.metadata.dependencyLockHash);
        vm.serializeBytes32(object, "abiBundleHash", config.metadata.abiBundleHash);
        vm.serializeBytes32(
            object, "storageLayoutBundleHash", config.metadata.storageLayoutBundleHash
        );
        vm.serializeBool(object, "testOnlyRoleCollapse", config.metadata.testOnlyRoleCollapse);
        vm.serializeBool(object, "deploymentTransactionHashesRecorded", false);
        vm.serializeString(object, "legacyManifestPath", LEGACY_MANIFEST_PATH);
        vm.serializeString(object, "legacyManifestSha256", LEGACY_MANIFEST_SHA256);
        vm.serializeString(object, "strategyStatus", "deployed-paused-pending-admin-actions");
        vm.serializeString(object, "swapStatus", "deployed-paused-pending-admin-actions");
        vm.serializeString(object, "fundVaultStatus", "not-implemented");
        vm.serializeAddress(object, "defaultAdmin", config.roles.defaultAdmin);
        vm.serializeAddress(object, "proxyAdminOwner", config.roles.proxyAdminOwner);
        vm.serializeAddress(object, "pauser", config.roles.pauser);
        vm.serializeAddress(object, "qualificationRevoker", config.roles.qualificationRevoker);
        vm.serializeAddress(object, "competitionFheOperator", config.roles.competitionFheOperator);
        vm.serializeAddress(object, "competitionCreator", config.roles.competitionCreator);
        vm.serializeAddress(object, "competitionCanceller", config.roles.competitionCanceller);
        vm.serializeAddress(object, "competitionEvaluator", config.roles.competitionEvaluator);
        vm.serializeAddress(object, "competitionFinalizer", config.roles.competitionFinalizer);
        vm.serializeAddress(object, "competitionQualifier", config.roles.competitionQualifier);
        vm.serializeAddress(object, "scoreRevealer", config.roles.scoreRevealer);
        vm.serializeAddress(object, "capitalFheOperator", config.roles.capitalFheOperator);
        vm.serializeAddress(object, "capitalEvaluator", config.roles.capitalEvaluator);
        vm.serializeAddress(object, "capitalRevoker", config.roles.capitalRevoker);
        vm.serializeAddress(object, "swapOperator", config.roles.swapOperator);
        vm.serializeAddress(object, "assetRegistryOwner", config.roles.assetRegistryOwner);
        vm.serializeAddress(object, "swapExecutorOwner", config.roles.swapExecutorOwner);
        vm.serializeAddress(object, "poolManager", config.poolManager);
        vm.serializeUint(object, "defaultAdminDelaySeconds", 48 hours);
        vm.serializeBytes32(object, "adminActionsHash", adminActionsHash(deployment, config));
        _serializeDeploymentAddresses(object, deployment);
        string memory json = _serializeDeploymentCodeHashes(object, deployment);
        vm.writeJson(json, manifestPath);
    }

    function _deployQualificationRegistry(DeploymentConfig memory config)
        private
        returns (
            AlphaEngineTraderQualificationRegistry implementation,
            AlphaEngineTraderQualificationRegistry proxy,
            address proxyAdmin
        )
    {
        implementation = new AlphaEngineTraderQualificationRegistry();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
            address(implementation),
            config.roles.proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineTraderQualificationRegistry.initialize,
                (config.roles.defaultAdmin, config.roles.pauser, config.roles.qualificationRevoker)
            )
        );
        proxy = AlphaEngineTraderQualificationRegistry(address(proxyContract));
        proxyAdmin = _proxyAdmin(address(proxy));
    }

    function _deployCompetitionManager(DeploymentConfig memory config, address registry)
        private
        returns (
            AlphaEngineCompetitionStrategyManager implementation,
            AlphaEngineCompetitionStrategyManager proxy,
            address proxyAdmin
        )
    {
        implementation = new AlphaEngineCompetitionStrategyManager();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
            address(implementation),
            config.roles.proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineCompetitionStrategyManager.initialize,
                (
                    AlphaEngineCompetitionStrategyManager.InitializationParams({
                        initialDefaultAdmin: config.roles.defaultAdmin,
                        initialPauser: config.roles.pauser,
                        initialFheOperator: config.roles.competitionFheOperator,
                        qualificationRegistry: registry
                    })
                )
            )
        );
        proxy = AlphaEngineCompetitionStrategyManager(address(proxyContract));
        proxyAdmin = _proxyAdmin(address(proxy));
    }

    function _deployCapitalManager(DeploymentConfig memory config, address registry)
        private
        returns (
            AlphaEngineCapitalStrategyManager implementation,
            AlphaEngineCapitalStrategyManager proxy,
            address proxyAdmin
        )
    {
        implementation = new AlphaEngineCapitalStrategyManager();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
            address(implementation),
            config.roles.proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineCapitalStrategyManager.initialize,
                (
                    AlphaEngineCapitalStrategyManager.InitializationParams({
                        initialDefaultAdmin: config.roles.defaultAdmin,
                        initialPauser: config.roles.pauser,
                        initialFheOperator: config.roles.capitalFheOperator,
                        qualificationRegistry: registry
                    })
                )
            )
        );
        proxy = AlphaEngineCapitalStrategyManager(address(proxyContract));
        proxyAdmin = _proxyAdmin(address(proxy));
    }

    function _deploySwapController(DeploymentConfig memory config)
        private
        returns (
            AlphaEngineConfidentialSwapController implementation,
            AlphaEngineConfidentialSwapController proxy,
            address proxyAdmin
        )
    {
        implementation = new AlphaEngineConfidentialSwapController();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
            address(implementation),
            config.roles.proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapController.initialize,
                (
                    AlphaEngineConfidentialSwapController.InitializationParams({
                        initialDefaultAdmin: config.roles.defaultAdmin,
                        initialPauser: config.roles.pauser,
                        initialSwapOperator: config.roles.swapOperator
                    })
                )
            )
        );
        proxy = AlphaEngineConfidentialSwapController(address(proxyContract));
        proxyAdmin = _proxyAdmin(address(proxy));
    }

    function _deploySwapEscrow(DeploymentConfig memory config, address controller, address registry)
        private
        returns (
            AlphaEngineConfidentialSwapEscrow implementation,
            AlphaEngineConfidentialSwapEscrow proxy,
            address proxyAdmin
        )
    {
        implementation = new AlphaEngineConfidentialSwapEscrow();
        TransparentUpgradeableProxy proxyContract = new TransparentUpgradeableProxy(
            address(implementation),
            config.roles.proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapEscrow.initialize,
                (config.roles.defaultAdmin, config.roles.pauser, controller, registry)
            )
        );
        proxy = AlphaEngineConfidentialSwapEscrow(address(proxyContract));
        proxyAdmin = _proxyAdmin(address(proxy));
    }

    function _serializeDeploymentAddresses(string memory object, Deployment memory deployment)
        private
    {
        vm.serializeAddress(
            object,
            "qualificationRegistryImplementation",
            deployment.qualificationRegistryImplementation
        );
        vm.serializeAddress(
            object, "qualificationRegistryProxy", deployment.qualificationRegistryProxy
        );
        vm.serializeAddress(
            object, "qualificationRegistryProxyAdmin", deployment.qualificationRegistryProxyAdmin
        );
        vm.serializeAddress(
            object, "competitionManagerImplementation", deployment.competitionManagerImplementation
        );
        vm.serializeAddress(object, "competitionManagerProxy", deployment.competitionManagerProxy);
        vm.serializeAddress(
            object, "competitionManagerProxyAdmin", deployment.competitionManagerProxyAdmin
        );
        vm.serializeAddress(
            object, "capitalManagerImplementation", deployment.capitalManagerImplementation
        );
        vm.serializeAddress(object, "capitalManagerProxy", deployment.capitalManagerProxy);
        vm.serializeAddress(object, "capitalManagerProxyAdmin", deployment.capitalManagerProxyAdmin);
        vm.serializeAddress(object, "assetRegistry", deployment.assetRegistry);
        vm.serializeAddress(object, "assetGateway", deployment.assetGateway);
        vm.serializeAddress(
            object, "swapControllerImplementation", deployment.swapControllerImplementation
        );
        vm.serializeAddress(object, "swapControllerProxy", deployment.swapControllerProxy);
        vm.serializeAddress(object, "swapControllerProxyAdmin", deployment.swapControllerProxyAdmin);
        vm.serializeAddress(object, "swapEscrowImplementation", deployment.swapEscrowImplementation);
        vm.serializeAddress(object, "swapEscrowProxy", deployment.swapEscrowProxy);
        vm.serializeAddress(object, "swapEscrowProxyAdmin", deployment.swapEscrowProxyAdmin);
        vm.serializeAddress(object, "swapExecutor", deployment.swapExecutor);
    }

    function _serializeDeploymentCodeHashes(string memory object, Deployment memory deployment)
        private
        returns (string memory json)
    {
        vm.serializeBytes32(
            object,
            "qualificationRegistryImplementationCodeHash",
            deployment.qualificationRegistryImplementation.codehash
        );
        vm.serializeBytes32(
            object,
            "competitionManagerImplementationCodeHash",
            deployment.competitionManagerImplementation.codehash
        );
        vm.serializeBytes32(
            object,
            "capitalManagerImplementationCodeHash",
            deployment.capitalManagerImplementation.codehash
        );
        vm.serializeBytes32(object, "assetRegistryCodeHash", deployment.assetRegistry.codehash);
        vm.serializeBytes32(object, "assetGatewayCodeHash", deployment.assetGateway.codehash);
        vm.serializeBytes32(
            object,
            "swapControllerImplementationCodeHash",
            deployment.swapControllerImplementation.codehash
        );
        vm.serializeBytes32(
            object, "swapEscrowImplementationCodeHash", deployment.swapEscrowImplementation.codehash
        );
        json = vm.serializeBytes32(object, "swapExecutorCodeHash", deployment.swapExecutor.codehash);
    }

    function _validateConfig(DeploymentConfig memory config) private view {
        if (config.expectedChainId != block.chainid) {
            revert UnexpectedChainId(config.expectedChainId, block.chainid);
        }
        if (config.poolManager == address(0) || config.poolManager.code.length == 0) {
            revert InvalidPoolManager(config.poolManager);
        }
        _requireNonzeroRoles(config.roles);
        if (!config.metadata.testOnlyRoleCollapse) _validateRoleSeparation(config.roles);
        if (bytes(config.metadata.deploymentGitSha).length == 0) {
            revert MissingArtifactMetadata("DEPLOYMENT_GIT_SHA");
        }
        if (bytes(config.metadata.foundryVersion).length == 0) {
            revert MissingArtifactMetadata("FOUNDRY_VERSION");
        }
        if (bytes(config.metadata.fhenixPackageRevision).length == 0) {
            revert MissingArtifactMetadata("FHENIX_REVISION");
        }
        if (config.metadata.dependencyLockHash == bytes32(0)) {
            revert MissingArtifactMetadata("DEPENDENCY_LOCK_HASH");
        }
        if (config.metadata.abiBundleHash == bytes32(0)) {
            revert MissingArtifactMetadata("ABI_BUNDLE_HASH");
        }
        if (config.metadata.storageLayoutBundleHash == bytes32(0)) {
            revert MissingArtifactMetadata("LAYOUT_BUNDLE_HASH");
        }
    }

    function _requireNonzeroRoles(RoleConfig memory roles) private pure {
        _requireNonzero(roles.defaultAdmin, "DEFAULT_ADMIN");
        _requireNonzero(roles.proxyAdminOwner, "PROXY_ADMIN_OWNER");
        _requireNonzero(roles.pauser, "PAUSER");
        _requireNonzero(roles.qualificationRevoker, "QUALIFICATION_REVOKER");
        _requireNonzero(roles.competitionFheOperator, "COMPETITION_FHE_OPERATOR");
        _requireNonzero(roles.competitionCreator, "COMPETITION_CREATOR");
        _requireNonzero(roles.competitionCanceller, "COMPETITION_CANCELLER");
        _requireNonzero(roles.competitionEvaluator, "COMPETITION_EVALUATOR");
        _requireNonzero(roles.competitionFinalizer, "COMPETITION_FINALIZER");
        _requireNonzero(roles.competitionQualifier, "COMPETITION_QUALIFIER");
        _requireNonzero(roles.scoreRevealer, "SCORE_REVEALER");
        _requireNonzero(roles.capitalFheOperator, "CAPITAL_FHE_OPERATOR");
        _requireNonzero(roles.capitalEvaluator, "CAPITAL_EVALUATOR");
        _requireNonzero(roles.capitalRevoker, "CAPITAL_REVOCER");
        _requireNonzero(roles.swapOperator, "SWAP_OPERATOR");
        _requireNonzero(roles.assetRegistryOwner, "ASSET_REGISTRY_OWNER");
        _requireNonzero(roles.swapExecutorOwner, "SWAP_EXECUTOR_OWNER");
    }

    function _validateRoleSeparation(RoleConfig memory roles) private pure {
        _rejectOverlap("ADMIN_PROXY_ADMIN", roles.defaultAdmin, roles.proxyAdminOwner);
        _rejectOverlap("ADMIN_PAUSER", roles.defaultAdmin, roles.pauser);
        _rejectOverlap("ADMIN_COMP_EVALUATOR", roles.defaultAdmin, roles.competitionEvaluator);
        _rejectOverlap("ADMIN_CAP_EVALUATOR", roles.defaultAdmin, roles.capitalEvaluator);
        _rejectOverlap("ADMIN_SWAP_OPERATOR", roles.defaultAdmin, roles.swapOperator);
        _rejectOverlap(
            "COMP_FHE_EVALUATOR", roles.competitionFheOperator, roles.competitionEvaluator
        );
        _rejectOverlap("CAP_FHE_EVALUATOR", roles.capitalFheOperator, roles.capitalEvaluator);
        _rejectOverlap("COMP_CAP_EVALUATOR", roles.competitionEvaluator, roles.capitalEvaluator);
        _rejectOverlap("COMP_EVALUATOR_SWAP", roles.competitionEvaluator, roles.swapOperator);
        _rejectOverlap("CAP_EVALUATOR_SWAP", roles.capitalEvaluator, roles.swapOperator);
    }

    function _requireNonzero(address value, bytes32 field) private pure {
        if (value == address(0)) revert ZeroConfigurationAddress(field);
    }

    function _rejectOverlap(bytes32 relationship, address first, address second) private pure {
        if (first == second) revert RoleOverlap(relationship, first);
    }

    function _proxyAdmin(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
    }

    function _readConfig() private view returns (DeploymentConfig memory config) {
        config.expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        config.poolManager = vm.envAddress("POOL_MANAGER");
        config.roles = RoleConfig({
            defaultAdmin: vm.envAddress("DEFAULT_ADMIN"),
            proxyAdminOwner: vm.envAddress("PROXY_ADMIN_OWNER"),
            pauser: vm.envAddress("PAUSER"),
            qualificationRevoker: vm.envAddress("QUALIFICATION_REVOKER"),
            competitionFheOperator: vm.envAddress("COMPETITION_FHE_OPERATOR"),
            competitionCreator: vm.envAddress("COMPETITION_CREATOR"),
            competitionCanceller: vm.envAddress("COMPETITION_CANCELLER"),
            competitionEvaluator: vm.envAddress("COMPETITION_EVALUATOR"),
            competitionFinalizer: vm.envAddress("COMPETITION_FINALIZER"),
            competitionQualifier: vm.envAddress("COMPETITION_QUALIFIER"),
            scoreRevealer: vm.envAddress("SCORE_REVEALER"),
            capitalFheOperator: vm.envAddress("CAPITAL_FHE_OPERATOR"),
            capitalEvaluator: vm.envAddress("CAPITAL_EVALUATOR"),
            capitalRevoker: vm.envAddress("CAPITAL_REVOCER"),
            swapOperator: vm.envAddress("SWAP_OPERATOR"),
            assetRegistryOwner: vm.envAddress("ASSET_REGISTRY_OWNER"),
            swapExecutorOwner: vm.envAddress("SWAP_EXECUTOR_OWNER")
        });
        config.metadata = ArtifactMetadata({
            deploymentGitSha: vm.envString("DEPLOYMENT_GIT_SHA"),
            foundryVersion: vm.envString("FOUNDRY_VERSION"),
            fhenixPackageRevision: vm.envString("FHENIX_PACKAGE_REVISION"),
            dependencyLockHash: vm.envBytes32("DEPENDENCY_LOCK_HASH"),
            abiBundleHash: vm.envBytes32("ABI_BUNDLE_HASH"),
            storageLayoutBundleHash: vm.envBytes32("STORAGE_LAYOUT_BUNDLE_HASH"),
            testOnlyRoleCollapse: vm.envOr("TEST_ONLY_ROLE_COLLAPSE", false)
        });
    }

    function _logDeployment(Deployment memory deployment, string memory manifestPath)
        private
        pure
    {
        console2.log("AlphaEngine v2 local deployment rehearsal");
        console2.log("qualification registry proxy:", deployment.qualificationRegistryProxy);
        console2.log("competition manager proxy:", deployment.competitionManagerProxy);
        console2.log("capital manager proxy:", deployment.capitalManagerProxy);
        console2.log("asset registry:", deployment.assetRegistry);
        console2.log("asset gateway:", deployment.assetGateway);
        console2.log("swap controller proxy:", deployment.swapControllerProxy);
        console2.log("swap escrow proxy:", deployment.swapEscrowProxy);
        console2.log("swap executor:", deployment.swapExecutor);
        console2.log("manifest:", manifestPath);
    }
}
