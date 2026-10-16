// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {
    ERC20ConfidentialLib
} from "fhenix-confidential-contracts/ERC20Confidential/ERC20ConfidentialLib.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {AlphaEngineV4SwapExecutor} from "src/executors/AlphaEngineV4SwapExecutor.sol";
import {
    AlphaEngineConfidentialAssetGateway
} from "src/fherc20/AlphaEngineConfidentialAssetGateway.sol";
import {
    AlphaEngineConfidentialAssetRegistry
} from "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";
import {
    IAlphaEngineConfidentialAssetRegistry
} from "src/interfaces/IAlphaEngineConfidentialAssetRegistry.sol";
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

/// @title DeployAlphaEngineV2
/// @notice Deploys the first-pass AlphaEngine v2 contracts in a paused, unfunded state.
/// @dev No public network deployment is performed by repository validation. Operational role
///      grants, reciprocal swap configuration, and registry escrow trust are emitted as
///      explicit governance actions for their respective owners.
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
        // TODO(mainnet): transfer every ProxyAdmin to a Safe-controlled upgrade timelock
        // and verify its delay before unpausing. DEFAULT_ADMIN_DELAY only delays
        // default-admin transfers, not implementation upgrades.
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
        bool bootstrapRoleCollapse;
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
        address assetRegistryImplementation;
        address assetRegistryProxyAdmin;
        address assetGatewayImplementation;
        address assetGatewayProxyAdmin;
        address assetWrapperImplementation;
        address assetRegistry;
        address assetGateway;
        address swapControllerImplementation;
        address swapControllerProxy;
        address swapControllerProxyAdmin;
        address swapEscrowImplementation;
        address swapEscrowProxy;
        address swapEscrowProxyAdmin;
        address swapExecutor;
        address confidentialTokenLibrary;
    }

    error ContractDeploymentFailed(string component);
    error UnexpectedChainId(uint256 expectedChainId, uint256 actualChainId);
    error ZeroConfigurationAddress(bytes32 field);
    error InvalidPoolManager(address poolManager);
    error RoleOverlap(bytes32 relationship, address holder);
    error MissingArtifactMetadata(bytes32 field);
    error MissingConfidentialTokenLibrary(address libraryAddress);
    error UnsafeManifestPath(string path);
    error TestOnlyRoleCollapseOnUnsupportedChain(uint256 chainId);

    function run() external returns (Deployment memory deployment) {
        DeploymentConfig memory config = _readConfig();
        string memory manifestPath =
            vm.envOr("DEPLOYMENT_MANIFEST", string("deployments/v2/local-latest.json"));

        _validateManifestPath(manifestPath);

        vm.startBroadcast();
        deployment = deploy(config);
        vm.stopBroadcast();

        writeManifest(manifestPath, config, deployment);
        _logDeployment(deployment, manifestPath);
    }

    function deploy(DeploymentConfig memory config)
        public
        virtual
        returns (Deployment memory deployment)
    {
        _validateConfig(config);

        deployment.assetWrapperImplementation = _deployContract(
            "assetWrapperImplementation", type(AlphaEngineFHERC20ERC20Wrapper).creationCode
        );
        deployment.assetRegistryImplementation = _deployContract(
            "assetRegistryImplementation", type(AlphaEngineConfidentialAssetRegistry).creationCode
        );
        deployment.assetRegistry = _deployProxy(
            "assetRegistry",
            deployment.assetRegistryImplementation,
            config.roles.proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialAssetRegistry.initialize,
                (
                    config.roles.assetRegistryOwner,
                    deployment.assetWrapperImplementation,
                    config.roles.proxyAdminOwner
                )
            )
        );
        deployment.assetRegistryProxyAdmin = _proxyAdmin(deployment.assetRegistry);
        deployment.assetGatewayImplementation = _deployContract(
            "assetGatewayImplementation", type(AlphaEngineConfidentialAssetGateway).creationCode
        );
        deployment.assetGateway = _deployProxy(
            "assetGateway",
            deployment.assetGatewayImplementation,
            config.roles.proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialAssetGateway.initialize,
                (IAlphaEngineConfidentialAssetRegistry(deployment.assetRegistry))
            )
        );
        deployment.assetGatewayProxyAdmin = _proxyAdmin(deployment.assetGateway);
        AlphaEngineConfidentialAssetRegistry assetRegistry =
            AlphaEngineConfidentialAssetRegistry(deployment.assetRegistry);
        AlphaEngineConfidentialAssetGateway assetGateway =
            AlphaEngineConfidentialAssetGateway(deployment.assetGateway);

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

        AlphaEngineV4SwapExecutor swapExecutor = AlphaEngineV4SwapExecutor(
            _deployConstructedContract(
                "swapExecutor",
                type(AlphaEngineV4SwapExecutor).creationCode,
                abi.encode(
                    IPoolManager(config.poolManager),
                    config.roles.swapExecutorOwner,
                    address(swapEscrow)
                )
            )
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
            assetRegistryImplementation: deployment.assetRegistryImplementation,
            assetRegistryProxyAdmin: deployment.assetRegistryProxyAdmin,
            assetGatewayImplementation: deployment.assetGatewayImplementation,
            assetGatewayProxyAdmin: deployment.assetGatewayProxyAdmin,
            assetWrapperImplementation: deployment.assetWrapperImplementation,
            assetRegistry: address(assetRegistry),
            assetGateway: address(assetGateway),
            swapControllerImplementation: address(swapControllerImplementation),
            swapControllerProxy: address(swapController),
            swapControllerProxyAdmin: swapControllerProxyAdmin,
            swapEscrowImplementation: address(swapEscrowImplementation),
            swapEscrowProxy: address(swapEscrow),
            swapEscrowProxyAdmin: swapEscrowProxyAdmin,
            swapExecutor: address(swapExecutor),
            confidentialTokenLibrary: address(ERC20ConfidentialLib)
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
        targets = new address[](11);
        data = new bytes[](11);
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
        data[index++] = abi.encodeCall(
            AlphaEngineConfidentialSwapController.setSwapConfiguration,
            (deployment.swapEscrowProxy, deployment.swapExecutor)
        );
        targets[index] = deployment.assetRegistry;
        data[index] = abi.encodeCall(
            AlphaEngineConfidentialAssetRegistry.setTrustedSwapEscrow, (deployment.swapEscrowProxy)
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
    ) public virtual {
        _validateManifestPath(manifestPath);
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
        vm.serializeString(object, "cofheContractsVersion", "1.0.0");
        vm.serializeString(object, "confidentialContractsVersion", "0.4.0");
        vm.serializeString(object, "contractApiRevision", "v2-cofhe-0.2");
        vm.serializeBytes32(object, "dependencyLockHash", config.metadata.dependencyLockHash);
        vm.serializeBytes32(object, "abiBundleHash", config.metadata.abiBundleHash);
        vm.serializeBytes32(
            object, "storageLayoutBundleHash", config.metadata.storageLayoutBundleHash
        );
        vm.serializeBool(object, "testOnlyRoleCollapse", config.metadata.testOnlyRoleCollapse);
        // Bootstrap roles must be handed over and verified before funding or activation.
        vm.serializeBool(object, "bootstrapRoleCollapse", config.metadata.bootstrapRoleCollapse);
        vm.serializeBool(object, "deploymentTransactionHashesRecorded", false);
        vm.serializeString(object, "legacyManifestPath", LEGACY_MANIFEST_PATH);
        vm.serializeString(object, "legacyManifestSha256", LEGACY_MANIFEST_SHA256);
        // Script simulation produces candidate addresses too. Only receipt reconciliation
        // may promote these statuses to deployed/verified on a public network.
        vm.serializeString(object, "executionStatus", "candidate-pending-receipt-reconciliation");
        vm.serializeString(object, "strategyStatus", "candidate-paused-pending-admin-actions");
        vm.serializeString(object, "swapStatus", "candidate-paused-pending-admin-actions");
        vm.serializeString(object, "capitalStatus", "candidate-paused-no-execution-manager");
        vm.serializeString(object, "fundVaultStatus", "not-deployed-out-of-scope");
        vm.serializeString(object, "usdcVaultManagerStatus", "not-deployed-out-of-scope");
        vm.serializeString(object, "vaultExecutionManagerStatus", "not-deployed-out-of-scope");
        vm.serializeString(object, "vaultDecodersStatus", "not-deployed-out-of-scope");
        vm.serializeString(object, "assetUpgradeRevision", "transparent-proxy-v1");
        vm.serializeString(object, "upgradeTimelockStatus", "handover-pending");
        vm.serializeString(object, "assetWrappersStatus", "not-deployed-pending-asset-selection");
        vm.serializeString(object, "explorerVerificationStatus", "not-verified");
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
        implementation = AlphaEngineTraderQualificationRegistry(
            _deployContract(
                "qualificationRegistryImplementation",
                type(AlphaEngineTraderQualificationRegistry).creationCode
            )
        );
        TransparentUpgradeableProxy proxyContract = TransparentUpgradeableProxy(
            payable(_deployProxy(
                    "qualificationRegistryProxy",
                    address(implementation),
                    config.roles.proxyAdminOwner,
                    abi.encodeCall(
                        AlphaEngineTraderQualificationRegistry.initialize,
                        (
                            config.roles.defaultAdmin,
                            config.roles.pauser,
                            config.roles.qualificationRevoker
                        )
                    )
                ))
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
        implementation = AlphaEngineCompetitionStrategyManager(
            _deployContract(
                "competitionManagerImplementation",
                type(AlphaEngineCompetitionStrategyManager).creationCode
            )
        );
        TransparentUpgradeableProxy proxyContract = TransparentUpgradeableProxy(
            payable(_deployProxy(
                    "competitionManagerProxy",
                    address(implementation),
                    config.roles.proxyAdminOwner,
                    abi.encodeCall(
                        AlphaEngineCompetitionStrategyManager.initialize,
                        (AlphaEngineCompetitionStrategyManager.InitializationParams({
                                initialDefaultAdmin: config.roles.defaultAdmin,
                                initialPauser: config.roles.pauser,
                                initialFheOperator: config.roles.competitionFheOperator,
                                qualificationRegistry: registry
                            }))
                    )
                ))
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
        implementation = AlphaEngineCapitalStrategyManager(
            _deployContract(
                "capitalManagerImplementation", type(AlphaEngineCapitalStrategyManager).creationCode
            )
        );
        TransparentUpgradeableProxy proxyContract = TransparentUpgradeableProxy(
            payable(_deployProxy(
                    "capitalManagerProxy",
                    address(implementation),
                    config.roles.proxyAdminOwner,
                    abi.encodeCall(
                        AlphaEngineCapitalStrategyManager.initialize,
                        (AlphaEngineCapitalStrategyManager.InitializationParams({
                                initialDefaultAdmin: config.roles.defaultAdmin,
                                initialPauser: config.roles.pauser,
                                initialFheOperator: config.roles.capitalFheOperator,
                                qualificationRegistry: registry
                            }))
                    )
                ))
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
        implementation = AlphaEngineConfidentialSwapController(
            _deployContract(
                "swapControllerImplementation",
                type(AlphaEngineConfidentialSwapController).creationCode
            )
        );
        TransparentUpgradeableProxy proxyContract = TransparentUpgradeableProxy(
            payable(_deployProxy(
                    "swapControllerProxy",
                    address(implementation),
                    config.roles.proxyAdminOwner,
                    abi.encodeCall(
                        AlphaEngineConfidentialSwapController.initialize,
                        (AlphaEngineConfidentialSwapController.InitializationParams({
                                initialDefaultAdmin: config.roles.defaultAdmin,
                                initialPauser: config.roles.pauser,
                                initialSwapOperator: config.roles.swapOperator
                            }))
                    )
                ))
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
        implementation = AlphaEngineConfidentialSwapEscrow(
            _deployContract(
                "swapEscrowImplementation", type(AlphaEngineConfidentialSwapEscrow).creationCode
            )
        );
        TransparentUpgradeableProxy proxyContract = TransparentUpgradeableProxy(
            payable(_deployProxy(
                    "swapEscrowProxy",
                    address(implementation),
                    config.roles.proxyAdminOwner,
                    abi.encodeCall(
                        AlphaEngineConfidentialSwapEscrow.initialize,
                        (config.roles.defaultAdmin, config.roles.pauser, controller, registry)
                    )
                ))
        );
        proxy = AlphaEngineConfidentialSwapEscrow(address(proxyContract));
        proxyAdmin = _proxyAdmin(address(proxy));
    }

    function _deployProxy(
        string memory component,
        address implementation,
        address owner,
        bytes memory initialization
    ) private returns (address) {
        return _deployConstructedContract(
            component,
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, owner, initialization)
        );
    }

    function _deployConstructedContract(
        string memory component,
        bytes memory creationCode,
        bytes memory arguments
    ) private returns (address) {
        return _deployContract(component, abi.encodePacked(creationCode, arguments));
    }

    /// @dev One construction hook lets CREATE2 reuse the existing wiring and validation.
    function _deployContract(string memory component, bytes memory creationCode)
        internal
        virtual
        returns (address deployed)
    {
        // CREATE accepts dynamic init code; Solidity has no typed-new equivalent here.
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        if (deployed == address(0)) revert ContractDeploymentFailed(component);
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
        vm.serializeAddress(
            object, "assetRegistryImplementation", deployment.assetRegistryImplementation
        );
        vm.serializeAddress(object, "assetRegistryProxyAdmin", deployment.assetRegistryProxyAdmin);
        vm.serializeAddress(
            object, "assetGatewayImplementation", deployment.assetGatewayImplementation
        );
        vm.serializeAddress(object, "assetGatewayProxyAdmin", deployment.assetGatewayProxyAdmin);
        vm.serializeAddress(
            object, "assetWrapperImplementation", deployment.assetWrapperImplementation
        );
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
        vm.serializeAddress(object, "confidentialTokenLibrary", deployment.confidentialTokenLibrary);
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
        vm.serializeBytes32(
            object,
            "assetRegistryImplementationCodeHash",
            deployment.assetRegistryImplementation.codehash
        );
        vm.serializeBytes32(
            object,
            "assetGatewayImplementationCodeHash",
            deployment.assetGatewayImplementation.codehash
        );
        vm.serializeBytes32(
            object,
            "assetWrapperImplementationCodeHash",
            deployment.assetWrapperImplementation.codehash
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
        vm.serializeBytes32(object, "swapExecutorCodeHash", deployment.swapExecutor.codehash);
        json = vm.serializeBytes32(
            object, "confidentialTokenLibraryCodeHash", deployment.confidentialTokenLibrary.codehash
        );
    }

    function _validateConfig(DeploymentConfig memory config) internal view {
        if (config.expectedChainId != block.chainid) {
            revert UnexpectedChainId(config.expectedChainId, block.chainid);
        }
        if (config.poolManager == address(0) || config.poolManager.code.length == 0) {
            revert InvalidPoolManager(config.poolManager);
        }
        _validateConfidentialTokenLibrary();
        _requireNonzeroRoles(config.roles);
        if (
            config.metadata.testOnlyRoleCollapse && block.chainid != 421_614
                && block.chainid != 31_337
        ) revert TestOnlyRoleCollapseOnUnsupportedChain(block.chainid);
        if (!config.metadata.testOnlyRoleCollapse && !config.metadata.bootstrapRoleCollapse) {
            _validateRoleSeparation(config.roles);
        }
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

    function _validateConfidentialTokenLibrary() internal view virtual {
        if (address(ERC20ConfidentialLib).code.length == 0) {
            revert MissingConfidentialTokenLibrary(address(ERC20ConfidentialLib));
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
            testOnlyRoleCollapse: vm.envOr("TEST_ONLY_ROLE_COLLAPSE", false),
            bootstrapRoleCollapse: vm.envOr("BOOTSTRAP_ROLE_COLLAPSE", false)
        });
    }

    function _logDeployment(Deployment memory deployment, string memory manifestPath) private pure {
        console2.log("AlphaEngine v2 candidate: reconcile receipts before claiming deployment");
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

    function _validateManifestPath(string memory path) private pure {
        // Historical files and broadcast receipts must never be simulation output targets.
        string memory normalizedPath = string.concat("/", path, "/");
        if (
            !_startsWith(path, "deployments/v2/") || _contains(normalizedPath, "/../")
                || _contains(normalizedPath, "/./") || _contains(path, "\\")
        ) revert UnsafeManifestPath(path);
    }

    function _startsWith(string memory value, string memory prefix) private pure returns (bool) {
        bytes memory text = bytes(value);
        bytes memory start = bytes(prefix);
        if (text.length <= start.length) return false;
        for (uint256 i; i < start.length; ++i) {
            if (text[i] != start[i]) return false;
        }
        return true;
    }

    function _contains(string memory value, string memory fragment) private pure returns (bool) {
        bytes memory text = bytes(value);
        bytes memory needle = bytes(fragment);
        if (needle.length > text.length) return false;
        for (uint256 i; i <= text.length - needle.length; ++i) {
            bool matchFound = true;
            for (uint256 j; j < needle.length; ++j) {
                if (text[i + j] != needle[j]) {
                    matchFound = false;
                    break;
                }
            }
            if (matchFound) return true;
        }
        return false;
    }
}
