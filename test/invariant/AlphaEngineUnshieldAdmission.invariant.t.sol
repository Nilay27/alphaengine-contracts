// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {FHE, euint64, sharedEuint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {AssetRegistryV2, AssetGatewayV2, AssetWrapperV2} from "test/mocks/MockAssetUpgrade.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
    AlphaEngineConfidentialAssetGateway
} from "src/fherc20/AlphaEngineConfidentialAssetGateway.sol";
import {
    AlphaEngineConfidentialAssetRegistry
} from "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";

/// @dev Independent amount, admission and cooldown model; invalid requests assert exact errors.
contract UnshieldAdmissionHandler is MockCoFheTest {
    bytes32 private constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    AlphaEngineConfidentialAssetRegistry public registry;
    AlphaEngineConfidentialAssetGateway public gateway;
    address[4] private _proxies;
    address[4] private _nextImplementations;
    address[4] private _implementations;
    address[4] public adminOwners;
    uint64[2] public minimums = [uint64(1000), uint64(10)];
    uint256 public upgrades;
    uint256 public adminHandovers;
    uint256 public rejectedOldAdmins;
    uint256 public configuredWrappers;
    AlphaEngineFHERC20ERC20Wrapper[2] public wrappers;
    uint64[4][2] public balances;
    uint64[4][2] public paid;
    bytes32[4][2] public pending;
    uint64[4][2] public pendingAmounts;
    bytes32[4][2] public pendingClaimHashes;
    uint40[4][2] public cooldowns;
    uint16 public tokens = 8;
    uint40 public tokensAt;
    uint256 public successfulRequests;
    uint256 public rejectedRequests;
    uint256 public singleClaims;
    uint256 public batchClaims;

    constructor(
        AlphaEngineConfidentialAssetRegistry registry_,
        AlphaEngineConfidentialAssetGateway gateway_,
        address first,
        address second
    ) {
        registry = registry_;
        gateway = gateway_;
        wrappers[0] = AlphaEngineFHERC20ERC20Wrapper(first);
        wrappers[1] = AlphaEngineFHERC20ERC20Wrapper(second);
        _proxies = [address(registry_), address(gateway_), first, second];
        _nextImplementations = [
            address(new AssetRegistryV2()),
            address(new AssetGatewayV2()),
            address(new AssetWrapperV2()),
            address(new AssetWrapperV2())
        ];
        for (uint256 i; i < 4; ++i) {
            _implementations[i] =
                address(uint160(uint256(vm.load(_proxies[i], IMPLEMENTATION_SLOT))));
            adminOwners[i] = address(this);
        }
        tokensAt = uint40(block.timestamp);
        for (uint256 w; w < 2; ++w) {
            for (uint256 u; u < 4; ++u) {
                balances[w][u] = 100e6;
            }
        }
        _bindMockTaskManager();
    }

    function account(uint256 u) public pure returns (address) {
        return address(uint160(0x9000 + u));
    }

    function request(uint256 seed, uint64 amount, uint8 rawMode) external {
        uint256 w = seed % 2;
        uint256 u = (seed / 2) % 4;
        uint8 mode = rawMode % 3;
        uint64 minimum = minimums[w];
        address user = account(u);
        AlphaEngineFHERC20ERC20Wrapper wrapper = wrappers[w];
        uint256 available = uint256(tokens) + block.timestamp - tokensAt;
        if (available > 8) available = 8;
        bytes memory expectedError;
        if (mode == 0 && amount < minimum) {
            expectedError = abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.UnshieldAmountBelowMinimum.selector, amount, minimum
            );
        } else if (pending[w][u] != bytes32(0)) {
            expectedError = abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.PendingUnshieldClaim.selector, user, pending[w][u]
            );
        } else if (block.timestamp < cooldowns[w][u]) {
            expectedError = abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.UnshieldCooldownActive.selector,
                user,
                cooldowns[w][u]
            );
        } else if (available == 0) {
            expectedError = abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.UnshieldRateLimitExceeded.selector,
                block.timestamp + 1
            );
        }

        bytes memory callData;
        vm.startPrank(user);
        if (mode == 0) {
            callData =
                abi.encodeWithSignature("unshield(address,address,uint64)", user, user, amount);
        } else if (mode == 1) {
            euint64 encrypted = FHE.asEuint64(amount);
            sharedEuint64 shared = FHE.shareEuint64(encrypted, address(wrapper));
            callData = abi.encodeWithSignature(
                "unshield(address,address,bytes32)", user, user, sharedEuint64.unwrap(shared)
            );
        } else {
            callData = abi.encodeCall(wrapper.unshieldAll, (user));
        }
        (bool success, bytes memory result) = address(wrapper).call(callData);
        vm.stopPrank();
        if (expectedError.length != 0) {
            assertFalse(success);
            assertEq(result, expectedError);
            rejectedRequests += 1;
            return;
        }
        assertTrue(success);
        uint64 actual = mode == 2
            ? balances[w][u]
            : (amount >= minimum && amount <= balances[w][u] ? amount : 0);
        balances[w][u] -= actual;
        pending[w][u] = wrapper.pendingUnshieldClaimId(user);
        assertNotEq(pending[w][u], bytes32(0));
        pendingAmounts[w][u] = actual;
        pendingClaimHashes[w][u] = keccak256(abi.encode(wrapper.getClaim(pending[w][u])));
        assertEq(mockStorage(uint256(wrapper.getClaim(pending[w][u]).ctHash)), actual);
        if (mode == 2) cooldowns[w][u] = uint40(block.timestamp + 5 minutes);
        tokens = uint16(available - 1);
        tokensAt = uint40(block.timestamp);
        successfulRequests += 1;
    }

    function claimSingle(uint256 seed) external {
        uint256 w = seed % 2;
        uint256 u = (seed / 2) % 4;
        bytes32 id = pending[w][u];
        if (id == bytes32(0)) return; // A claim requires a live request.
        taskManager.publishDecryptResult(
            uint256(wrappers[w].getClaim(id).ctHash), pendingAmounts[w][u], ""
        );
        wrappers[w].claimUnshielded(id, pendingAmounts[w][u], "");
        _complete(w, u);
        singleClaims += 1;
    }

    function claimBatch(uint256 seed) external {
        uint256 w = seed % 2;
        uint256 count;
        for (uint256 u; u < 4; ++u) {
            if (pending[w][u] != bytes32(0)) ++count;
        }
        if (count == 0) return;
        bytes32[] memory ids = new bytes32[](count);
        uint64[] memory amounts = new uint64[](count);
        uint256 index;
        for (uint256 u; u < 4; ++u) {
            if (pending[w][u] == bytes32(0)) continue;
            ids[index] = pending[w][u];
            amounts[index] = pendingAmounts[w][u];
            taskManager.publishDecryptResult(
                uint256(wrappers[w].getClaim(ids[index]).ctHash), amounts[index], ""
            );
            ++index;
        }
        wrappers[w].claimUnshieldedBatch(ids, amounts, new bytes[](count));
        for (uint256 u; u < 4; ++u) {
            if (pending[w][u] != bytes32(0)) _complete(w, u);
        }
        batchClaims += 1;
    }

    function advanceTime(uint16 elapsed) external {
        vm.warp(block.timestamp + elapsed);
    }

    function upgrade(uint256 seed) external {
        uint256 i = seed % 4;
        vm.prank(adminOwners[i]);
        _admin(i)
            .upgradeAndCall(ITransparentUpgradeableProxy(_proxies[i]), _nextImplementations[i], "");
        _implementations[i] = _nextImplementations[i];
        upgrades += 1;
    }

    function handoverAdmin(uint256 seed) external {
        uint256 i = seed % 4;
        address previous = adminOwners[i];
        address next = previous == address(this) ? account(10) : address(this);
        ProxyAdmin proxyAdmin = _admin(i);
        vm.prank(previous);
        proxyAdmin.transferOwnership(next);
        adminOwners[i] = next;
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, previous)
        );
        vm.prank(previous);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(_proxies[i]), _nextImplementations[i], ""
        );
        adminHandovers += 1;
        rejectedOldAdmins += 1;
    }

    function configureMinimum(uint256 seed, uint64 rawMinimum) external {
        uint256 w = seed % 2;
        minimums[w] = uint64(bound(rawMinimum, 1, 2000));
        registry.setWrapperMinimums(address(wrappers[w]), 1, minimums[w]);
    }

    function configureFutureWrapper(uint256 seed) external {
        if (configuredWrappers == 4) return;
        address nextOwner = seed % 2 == 0 ? account(10) : address(this);
        registry.setWrapperDeploymentConfiguration(_nextImplementations[2], nextOwner);
        MockERC20 asset = new MockERC20("Future asset", "FUT", seed % 2 == 0 ? 6 : 18);
        address wrapper = registry.createWrapper(address(asset), "Future encrypted", "eFUT", "");
        assertEq(AssetWrapperV2(wrapper).version(), 2);
        assertEq(AlphaEngineFHERC20ERC20Wrapper(wrapper).wrapperRegistry(), address(registry));
        assertEq(registry.wrapperForUnderlying(address(asset)), wrapper);
        assertEq(registry.underlyingForWrapper(wrapper), address(asset));
        assertEq(
            ProxyAdmin(address(uint160(uint256(vm.load(wrapper, ADMIN_SLOT))))).owner(), nextOwner
        );
        configuredWrappers += 1;
        assertConfiguration();
    }

    function assertConfiguration() public view {
        assertEq(gateway.assetRegistry(), address(registry));
        for (uint256 i; i < 4; ++i) {
            assertEq(_admin(i).owner(), adminOwners[i]);
            assertEq(
                address(uint160(uint256(vm.load(_proxies[i], IMPLEMENTATION_SLOT)))),
                _implementations[i]
            );
        }
        for (uint256 w; w < 2; ++w) {
            assertEq(wrappers[w].wrapperRegistry(), address(registry));
            assertEq(
                registry.wrapperForUnderlying(address(wrappers[w].underlying())),
                address(wrappers[w])
            );
            assertEq(registry.minimumUnshieldAmount(address(wrappers[w])), minimums[w]);
        }
    }

    function _admin(uint256 i) private view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(_proxies[i], ADMIN_SLOT)))));
    }

    function _complete(uint256 w, uint256 u) private {
        uint64 amount = pendingAmounts[w][u];
        paid[w][u] += amount;
        if (amount == 0) cooldowns[w][u] = uint40(block.timestamp + 5 minutes);
        delete pending[w][u];
        delete pendingAmounts[w][u];
        delete pendingClaimHashes[w][u];
    }
}

contract AlphaEngineUnshieldAdmissionInvariantTest is StdInvariant, MockCoFheTest {
    AlphaEngineConfidentialAssetRegistry private registry;
    AlphaEngineFHERC20ERC20Wrapper[2] private wrappers;
    MockERC20[2] private assets;
    UnshieldAdmissionHandler private handler;

    function setUp() public {
        _installMockTaskManager();
        registry = _deployAssetRegistry(address(this));
        AlphaEngineConfidentialAssetGateway gateway = _deployAssetGateway(registry);
        for (uint256 w; w < 2; ++w) {
            assets[w] = new MockERC20("Underlying", "TOK", w == 0 ? 6 : 18);
            wrappers[w] = AlphaEngineFHERC20ERC20Wrapper(
                registry.createWrapper(address(assets[w]), "Encrypted", "ENC", "")
            );
            registry.setWrapperMinimums(
                address(wrappers[w]), w == 0 ? 1e6 : 100, w == 0 ? 1000 : 10
            );
            uint256 rate = wrappers[w].rate();
            assets[w].mint(address(this), 400e6 * rate);
            assets[w].approve(address(wrappers[w]), 400e6 * rate);
            for (uint256 u; u < 4; ++u) {
                wrappers[w].shield(address(uint160(0x9000 + u)), 100e6 * rate);
            }
        }
        handler = new UnshieldAdmissionHandler(
            registry, gateway, address(wrappers[0]), address(wrappers[1])
        );
        registry.transferOwnership(address(handler));
        address[4] memory proxies =
            [address(registry), address(gateway), address(wrappers[0]), address(wrappers[1])];
        for (uint256 i; i < 4; ++i) {
            ProxyAdmin(
                    address(
                        uint160(
                            uint256(
                                vm.load(
                                    proxies[i],
                                    0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
                                )
                            )
                        )
                    )
                )
                .transferOwnership(address(handler));
        }
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.request.selector;
        selectors[1] = handler.claimSingle.selector;
        selectors[2] = handler.claimBatch.selector;
        selectors[3] = handler.advanceTime.selector;
        selectors[4] = handler.upgrade.selector;
        selectors[5] = handler.handoverAdmin.selector;
        selectors[6] = handler.configureMinimum.selector;
        selectors[7] = handler.configureFutureWrapper.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
        handler.request(0, 999, 1);
        handler.request(2, 1000, 0);
        handler.request(1, 10, 0);
        handler.request(3, 9, 1);
        for (uint256 i; i < 4; ++i) {
            handler.handoverAdmin(i);
            handler.upgrade(i);
        }
        handler.configureFutureWrapper(0);
        handler.configureMinimum(0, 1000);
        handler.claimBatch(0);
        handler.claimBatch(1);
        handler.request(0, 1000, 0);
        handler.request(4, 0, 2);
        handler.claimSingle(4);
    }

    /// @dev Echidna entry point reusing the same handlers/oracle; unexpected reverts must fail.
    function exercise(uint8 action, uint256 seed, uint64 value) external {
        bytes memory data;
        action %= 8;
        if (action == 0) data = abi.encodeCall(handler.request, (seed, value, uint8(seed)));
        else if (action == 1) data = abi.encodeCall(handler.claimSingle, (seed));
        else if (action == 2) data = abi.encodeCall(handler.claimBatch, (seed));
        else if (action == 3) data = abi.encodeCall(handler.advanceTime, (uint16(value)));
        else if (action == 4) data = abi.encodeCall(handler.upgrade, (seed));
        else if (action == 5) data = abi.encodeCall(handler.handoverAdmin, (seed));
        else if (action == 6) data = abi.encodeCall(handler.configureMinimum, (seed, value));
        else data = abi.encodeCall(handler.configureFutureWrapper, (seed));
        (bool success,) = address(handler).call(data);
        assert(success);
        invariant_amountsPendingCooldownsAndBudgetMatchIndependentModel();
    }

    function invariant_amountsPendingCooldownsAndBudgetMatchIndependentModel() public view {
        handler.assertConfiguration();
        assertEq(registry.availableUnshieldTokens(), handler.tokens());
        assertEq(registry.unshieldTokensUpdatedAt(), handler.tokensAt());
        for (uint256 w; w < 2; ++w) {
            uint256 supply;
            uint256 outstanding;
            uint256 rate = wrappers[w].rate();
            for (uint256 u; u < 4; ++u) {
                address user = handler.account(u);
                uint256 balance = handler.balances(w, u);
                uint256 amount = handler.pendingAmounts(w, u);
                assertEq(
                    mockStorage(uint256(FHE.unwrap(wrappers[w].confidentialBalanceOf(user)))),
                    balance
                );
                assertEq(wrappers[w].pendingUnshieldClaimId(user), handler.pending(w, u));
                if (handler.pending(w, u) != bytes32(0)) {
                    assertEq(
                        keccak256(abi.encode(wrappers[w].getClaim(handler.pending(w, u)))),
                        handler.pendingClaimHashes(w, u)
                    );
                }
                assertTrue(
                    taskManager.isAllowed(
                        uint256(FHE.unwrap(wrappers[w].confidentialBalanceOf(user))),
                        address(wrappers[w])
                    )
                );
                assertEq(wrappers[w].unshieldCooldownUntil(user), handler.cooldowns(w, u));
                assertEq(assets[w].balanceOf(user), uint256(handler.paid(w, u)) * rate);
                assertEq(balance + amount + handler.paid(w, u), 100e6);
                supply += balance;
                outstanding += amount;
            }
            assertEq(
                mockStorage(uint256(FHE.unwrap(wrappers[w].confidentialTotalSupply()))), supply
            );
            assertEq(assets[w].balanceOf(address(wrappers[w])), (supply + outstanding) * rate);
        }
        assertGt(handler.successfulRequests(), 0);
        assertGt(handler.rejectedRequests(), 0);
        assertGt(handler.singleClaims(), 0);
        assertGt(handler.batchClaims(), 0);
        assertGe(handler.upgrades(), 4);
        assertGe(handler.adminHandovers(), 4);
        assertEq(handler.adminHandovers(), handler.rejectedOldAdmins());
        assertGt(handler.configuredWrappers(), 0);
    }
}
