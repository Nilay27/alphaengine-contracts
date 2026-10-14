// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FHE, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {
    AlphaEngineConfidentialAssetRegistry
} from "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";
import {
    AlphaEngineConfidentialAssetGateway
} from "src/fherc20/AlphaEngineConfidentialAssetGateway.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {
    IAlphaEngineConfidentialAssetRegistry
} from "src/interfaces/IAlphaEngineConfidentialAssetRegistry.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AssetRegistryV2 is AlphaEngineConfidentialAssetRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract AssetGatewayV2 is AlphaEngineConfidentialAssetGateway {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract AssetWrapperV2 is AlphaEngineFHERC20ERC20Wrapper {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract AlphaEngineAssetUpgradeTest is MockCoFheTest {
    bytes32 private constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address private user = makeAddr("asset-user");
    AlphaEngineConfidentialAssetRegistry private registry;
    AlphaEngineConfidentialAssetGateway private gateway;
    AlphaEngineFHERC20ERC20Wrapper private wrapper;
    MockERC20 private token;
    event Upgraded(address indexed implementation);

    function setUp() public {
        _installMockTaskManager();
        registry = _deployAssetRegistry(address(this));
        gateway = _deployAssetGateway(registry);
        token = new MockERC20("USD Coin", "USDC", 6);
        wrapper = AlphaEngineFHERC20ERC20Wrapper(
            registry.createWrapper(address(token), "Encrypted USDC", "eUSDC", "uri")
        );
        registry.setWrapperMinimums(address(wrapper), 1, 1);
    }

    function test_implementationsAndProxiesRejectInitializationReplay() public {
        AlphaEngineConfidentialAssetRegistry r = new AlphaEngineConfidentialAssetRegistry();
        AlphaEngineConfidentialAssetGateway g = new AlphaEngineConfidentialAssetGateway();
        AlphaEngineFHERC20ERC20Wrapper w = new AlphaEngineFHERC20ERC20Wrapper();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        r.initialize(address(this), address(w), address(this));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        g.initialize(registry);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        w.initialize(token, "", "", "", address(registry));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(user, address(w), user);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        gateway.initialize(registry);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wrapper.initialize(token, "", "", "", address(registry));
    }

    function test_wrapperInitializerRejectsInvalidBindings() public {
        AlphaEngineFHERC20ERC20Wrapper fresh = AlphaEngineFHERC20ERC20Wrapper(
            _uninitialized(address(new AlphaEngineFHERC20ERC20Wrapper()))
        );
        vm.expectRevert(AlphaEngineFHERC20ERC20Wrapper.ZeroUnderlying.selector);
        fresh.initialize(IERC20(address(0)), "", "", "", address(registry));
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFHERC20ERC20Wrapper.InvalidUnderlying.selector, user)
        );
        fresh.initialize(IERC20(user), "", "", "", address(registry));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.InvalidWrapperRegistry.selector, address(0)
            )
        );
        fresh.initialize(token, "", "", "", address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.InvalidWrapperRegistry.selector, user
            )
        );
        fresh.initialize(token, "", "", "", user);
    }

    function test_registryInitializerRejectsInvalidDeploymentConfiguration() public {
        AlphaEngineConfidentialAssetRegistry fresh = AlphaEngineConfidentialAssetRegistry(
            _uninitialized(address(new AlphaEngineConfidentialAssetRegistry()))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.InvalidWrapperImplementation.selector, user
            )
        );
        fresh.initialize(address(this), user, address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.InvalidWrapperImplementation.selector,
                address(token)
            )
        );
        fresh.initialize(address(this), address(token), address(this));
        address wrapperImplementation = registry.wrapperImplementation();
        vm.expectRevert(AlphaEngineConfidentialAssetRegistry.ZeroWrapperProxyAdminOwner.selector);
        fresh.initialize(address(this), wrapperImplementation, address(0));
        assertEq(fresh.owner(), address(0));
    }

    function test_upgradeRequiresEachProxyAdminOwner() public {
        address next = address(new AssetWrapperV2());
        address[3] memory proxies = [address(registry), address(gateway), address(wrapper)];
        for (uint256 i; i < proxies.length; ++i) {
            ProxyAdmin admin = _admin(proxies[i]);
            assertEq(admin.owner(), address(this));
            vm.prank(user);
            vm.expectRevert(
                abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user)
            );
            admin.upgradeAndCall(ITransparentUpgradeableProxy(proxies[i]), next, "");
        }
        assertNotEq(address(_admin(address(wrapper))), address(_admin(address(registry))));
    }

    function testFuzz_upgradesPreserveBalancesPermissionsAndPendingWithdrawal(uint64 amount)
        public
    {
        amount = uint64(bound(amount, 1, 100e6));
        token.mint(user, 100e6);
        vm.startPrank(user);
        token.approve(address(gateway), 100e6);
        gateway.depositAndShield(address(token), 100e6, user);
        wrapper.setOperator(address(gateway), uint48(block.timestamp + 1 hours));
        (euint64 handle, bytes32 claimId) = gateway.requestUnshield(address(wrapper), user, amount);
        vm.stopPrank();
        euint64 balance = wrapper.confidentialBalanceOf(user);
        uint256 reserves = token.balanceOf(address(wrapper));
        bytes32 claimHash = keccak256(abi.encode(wrapper.getClaim(claimId)));
        uint40 budgetUpdatedAt = registry.unshieldTokensUpdatedAt();

        _upgrade(address(registry), address(new AssetRegistryV2()));
        _upgrade(address(gateway), address(new AssetGatewayV2()));
        _upgrade(address(wrapper), address(new AssetWrapperV2()));
        assertEq(AssetRegistryV2(address(registry)).version(), 2);
        assertEq(AssetGatewayV2(address(gateway)).version(), 2);
        assertEq(AssetWrapperV2(address(wrapper)).version(), 2);
        assertEq(registry.owner(), address(this));
        assertEq(registry.wrapperForUnderlying(address(token)), address(wrapper));
        assertEq(registry.underlyingForWrapper(address(wrapper)), address(token));
        assertEq(registry.availableUnshieldTokens(), 7);
        assertEq(registry.unshieldTokensUpdatedAt(), budgetUpdatedAt);
        assertEq(registry.minimumUnshieldAmount(address(wrapper)), 1);
        assertEq(gateway.assetRegistry(), address(registry));
        assertEq(wrapper.wrapperRegistry(), address(registry));
        assertEq(wrapper.underlying(), address(token));
        assertEq(wrapper.name(), "Encrypted USDC");
        assertEq(wrapper.decimals(), 6);
        assertEq(wrapper.rate(), 1);
        assertEq(euint64.unwrap(wrapper.confidentialBalanceOf(user)), euint64.unwrap(balance));
        assertEq(taskManager.mockValue(uint256(euint64.unwrap(balance))), 100e6 - amount);
        assertTrue(taskManager.isAllowed(uint256(euint64.unwrap(balance)), address(wrapper)));
        assertTrue(wrapper.isOperator(user, address(gateway)));
        assertEq(token.balanceOf(address(wrapper)), reserves);
        assertEq(wrapper.latestUnshieldClaimId(user), claimId);
        assertEq(wrapper.pendingUnshieldClaimId(user), claimId);
        assertEq(keccak256(abi.encode(wrapper.getClaim(claimId))), claimHash);

        taskManager.publishDecryptResult(uint256(euint64.unwrap(handle)), amount, "");
        gateway.claimUnshielded(address(wrapper), claimId, amount, "");
        assertTrue(wrapper.getClaim(claimId).claimed);
        assertEq(wrapper.pendingUnshieldClaimId(user), bytes32(0));
        assertEq(token.balanceOf(user), amount);
        assertEq(token.balanceOf(address(wrapper)), 100e6 - amount);
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    function test_zeroWithdrawalCompletesAfterUpgrade() public {
        token.mint(user, 1e6);
        vm.startPrank(user);
        token.approve(address(gateway), 1e6);
        gateway.depositAndShield(address(token), 1e6, user);
        wrapper.setOperator(address(gateway), uint48(block.timestamp + 1 hours));
        (euint64 handle, bytes32 claimId) = gateway.requestUnshield(address(wrapper), user, 2e6);
        vm.stopPrank();
        assertEq(taskManager.mockValue(uint256(euint64.unwrap(handle))), 0);
        _upgrade(address(wrapper), address(new AssetWrapperV2()));
        taskManager.publishDecryptResult(uint256(euint64.unwrap(handle)), 0, "");
        gateway.claimUnshielded(address(wrapper), claimId, 0, "");
        assertTrue(wrapper.getClaim(claimId).claimed);
        assertEq(wrapper.pendingUnshieldClaimId(user), bytes32(0));
        assertEq(wrapper.unshieldCooldownUntil(user), block.timestamp + 5 minutes);
        assertEq(token.balanceOf(address(wrapper)), 1e6);
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    function test_futureWrapperConfigurationDoesNotChangeExistingProxies() public {
        address next = address(new AssetWrapperV2());
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        registry.setWrapperDeploymentConfiguration(next, user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.InvalidWrapperImplementation.selector, user
            )
        );
        registry.setWrapperDeploymentConfiguration(user, user);
        vm.expectRevert(AlphaEngineConfidentialAssetRegistry.ZeroWrapperProxyAdminOwner.selector);
        registry.setWrapperDeploymentConfiguration(next, address(0));
        vm.expectEmit(false, false, false, true, address(registry));
        emit AlphaEngineConfidentialAssetRegistry.WrapperDeploymentConfigurationUpdated(next, user);
        registry.setWrapperDeploymentConfiguration(next, user);
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        address otherWrapper =
            registry.createWrapper(address(other), "Encrypted Other", "eOTHER", "");
        assertEq(AssetWrapperV2(otherWrapper).version(), 2);
        assertEq(_admin(otherWrapper).owner(), user);
        assertEq(_admin(address(wrapper)).owner(), address(this));
        assertNotEq(vm.load(address(wrapper), IMPLEMENTATION_SLOT), bytes32(uint256(uint160(next))));
        assertEq(registry.wrapperForUnderlying(address(token)), address(wrapper));
        assertEq(AlphaEngineFHERC20ERC20Wrapper(otherWrapper).rate(), 1e12);
    }

    function _upgrade(address proxy, address implementation) private {
        vm.expectEmit(true, false, false, false, proxy);
        emit Upgraded(implementation);
        _admin(proxy).upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, "");
        assertEq(vm.load(proxy, IMPLEMENTATION_SLOT), bytes32(uint256(uint160(implementation))));
    }

    function _admin(address proxy) private view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(proxy, ADMIN_SLOT)))));
    }

    function _uninitialized(address implementation) private returns (address) {
        // Deliberately uninitialized only to exercise invalid-initialization branches.
        return address(new TransparentUpgradeableProxy(implementation, address(this), ""));
    }
}
