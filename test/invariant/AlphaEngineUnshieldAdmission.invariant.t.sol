// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {
    FHE,
    euint64,
    sharedEuint64,
    externalEuint64
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20, MockZeroTransferRevertingERC20} from "test/mocks/MockERC20.sol";
import {MockCoFheTaskManager} from "test/mocks/MockCoFheTaskManager.sol";
import {
    FHERC20WrapperClaims
} from "fhenix-confidential-contracts/FHERC20/utils/FHERC20WrapperClaims.sol";
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
    // AS-01/04/06/08/10/14/17: independent source/recipient and governance histories.
    uint256[4][2] public endowments;
    uint256[4][2] public exited;
    uint256[4][2] public pendingRecipients;
    address public businessOwner;
    uint16 public refillPerSecond = 1;
    uint16 public burst = 8;
    uint256 public deposits;
    uint256 public transfers;
    uint256 public budgetUpdates;
    uint256 public businessHandovers;
    uint256 public rejectedClaims;
    uint256 public rejectedShares;
    uint256 public rejectedInputDomains;
    uint256 public duplicateRegistrations;
    uint256 public delegatedClaims;
    uint256 public rejectedUnauthorizedDebits;
    uint256 public rejectedDecryptions;
    uint256 public escrowRotations;
    UnshieldEscrowProbe[2] private _escrows;
    address public trustedEscrow;
    uint256 public postRequestFunding;

    struct CompletedClaim {
        uint256 wrapperIndex;
        bytes32 id;
        uint64 amount;
    }
    CompletedClaim[] private _completed;
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
        businessOwner = address(this);
        _escrows[0] = new UnshieldEscrowProbe(address(registry_));
        _escrows[1] = new UnshieldEscrowProbe(address(registry_));
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
                endowments[w][u] = 100e6;
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
        uint256 available = _availableTokens();
        uint256 recipient = (seed / 8) % 4;
        bytes32 beforeState = _stateHash(w, u);
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
            callData = abi.encodeWithSignature(
                "unshield(address,address,uint64)", user, account(recipient), amount
            );
        } else if (mode == 1) {
            euint64 encrypted = FHE.asEuint64(amount);
            sharedEuint64 shared = FHE.shareEuint64(encrypted, address(wrapper));
            callData = abi.encodeWithSignature(
                "unshield(address,address,bytes32)",
                user,
                account(recipient),
                sharedEuint64.unwrap(shared)
            );
        } else {
            callData = abi.encodeCall(wrapper.unshieldAll, (account(recipient)));
        }
        (bool success, bytes memory result) = address(wrapper).call(callData);
        vm.stopPrank();
        if (expectedError.length != 0) {
            assertFalse(success);
            assertEq(result, expectedError);
            assertEq(_stateHash(w, u), beforeState);
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
        pendingRecipients[w][u] = recipient;
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
        vm.prank(account(12)); // Anyone may pay the fixed recorded recipient.
        wrappers[w].claimUnshielded(id, pendingAmounts[w][u], "");
        delegatedClaims += 1;
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
        vm.prank(businessOwner);
        registry.setWrapperMinimums(address(wrappers[w]), 1, minimums[w]);
    }

    function configureFutureWrapper(uint256 seed) external {
        if (configuredWrappers == 4) return;
        address nextOwner = seed % 2 == 0 ? account(10) : address(this);
        vm.prank(businessOwner);
        registry.setWrapperDeploymentConfiguration(_nextImplementations[2], nextOwner);
        MockERC20 asset = new MockERC20("Future asset", "FUT", seed % 2 == 0 ? 6 : 18);
        vm.prank(businessOwner);
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
        assertEq(registry.owner(), businessOwner);
        assertEq(registry.trustedSwapEscrow(), trustedEscrow);
        assertEq(registry.unshieldRequestsPerSecond(), refillPerSecond);
        assertEq(registry.unshieldBurst(), burst);
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

    // AS-01/10: later funding cannot change an existing claim's burned amount.
    function depositAgain(uint256 seed, uint64 rawUnits) external {
        uint256 w = seed % 2;
        uint256 u = (seed / 2) % 4;
        uint64 units = uint64(bound(rawUnits, 1, 1e9));
        MockERC20 asset = MockERC20(address(wrappers[w].underlying()));
        uint256 amount = uint256(units) * wrappers[w].rate();
        asset.mint(address(this), amount);
        asset.approve(address(gateway), amount);
        gateway.depositAndShield(address(asset), amount, account(u));
        balances[w][u] += units;
        endowments[w][u] += units;
        if (pending[w][u] != bytes32(0)) postRequestFunding += 1;
        deposits += 1;
    }

    function transferConfidential(uint256 seed, uint64 rawUnits) external {
        uint256 w = seed % 2;
        uint256 from = (seed / 2) % 4;
        uint256 to = (from + 1 + (seed / 8) % 3) % 4;
        uint64 requested = rawUnits;
        uint64 actual = requested <= balances[w][from] ? requested : 0;
        vm.startPrank(account(from));
        euint64 amount = FHE.asEuint64(requested);
        sharedEuint64 shared = FHE.shareEuint64(amount, address(wrappers[w]));
        wrappers[w].confidentialTransfer(account(to), shared);
        vm.stopPrank();
        balances[w][from] -= actual;
        balances[w][to] += actual;
        endowments[w][from] -= actual;
        endowments[w][to] += actual;
        transfers += 1;
    }

    // AS-08: checkpoint old-rate accrual before applying the new capacity/rate.
    function configureBudget(uint16 rawRate, uint16 rawBurst) external {
        uint16 rate = uint16(bound(rawRate, 1, 16));
        uint16 capacity = uint16(bound(rawBurst, rate, 128));
        uint256 credit = _availableTokens();
        tokens = uint16(credit > capacity ? capacity : credit);
        tokensAt = uint40(block.timestamp);
        vm.prank(businessOwner);
        registry.setUnshieldRateLimits(rate, capacity);
        refillPerSecond = rate;
        burst = capacity;
        budgetUpdates += 1;
        assertEq(registry.availableUnshieldTokens(), tokens);
    }

    // AS-03: an ACL grant cannot replace the directed one-use share authentication.
    function rejectUnauthenticatedShare(uint256 seed) external {
        uint256 w = seed % 2;
        uint256 u = (seed / 2) % 4;
        AlphaEngineFHERC20ERC20Wrapper wrapper = wrappers[w];
        bytes32 beforeState = _stateHash(w, u);
        vm.startPrank(account(u));
        euint64 amount = FHE.asEuint64(17 + seed % 1000);
        FHE.allow(amount, address(wrapper));
        vm.expectRevert(
            abi.encodeWithSelector(
                MockCoFheTaskManager.NotShared.selector,
                uint256(FHE.unwrap(amount)),
                address(wrapper)
            )
        );
        wrapper.unshield(account(u), account(u), sharedEuint64.wrap(FHE.unwrap(amount)));
        vm.stopPrank();
        assertEq(_stateHash(w, u), beforeState);
        rejectedShares += 1;
    }

    // AS-04: a ciphertext is never a claim ID, and a paid ID cannot debit later claims.
    function rejectClaimReplay(uint256 seed) external {
        if (_completed.length == 0) return;
        CompletedClaim memory done = _completed[seed % _completed.length];
        AlphaEngineFHERC20ERC20Wrapper wrapper = wrappers[done.wrapperIndex];
        bytes32 beforeState = keccak256(
            abi.encode(
                wrapper.confidentialTotalSupply(),
                MockERC20(address(wrapper.underlying())).balanceOf(address(wrapper)),
                registry.availableUnshieldTokens(),
                registry.unshieldTokensUpdatedAt()
            )
        );
        vm.expectRevert(FHERC20WrapperClaims.AlreadyClaimed.selector);
        wrapper.claimUnshielded(done.id, done.amount, "");
        bytes32 ciphertext = wrapper.getClaim(done.id).ctHash;
        assertNotEq(ciphertext, done.id);
        vm.expectRevert(FHERC20WrapperClaims.ClaimNotFound.selector);
        wrapper.claimUnshielded(ciphertext, done.amount, "");
        assertEq(
            beforeState,
            keccak256(
                abi.encode(
                    wrapper.confidentialTotalSupply(),
                    MockERC20(address(wrapper.underlying())).balanceOf(address(wrapper)),
                    registry.availableUnshieldTokens(),
                    registry.unshieldTokensUpdatedAt()
                )
            )
        );
        rejectedClaims += 1;
    }

    // AS-12: registered assets cannot be rebound after claims/upgrades/config changes.
    function rejectDuplicateRegistration(uint256 seed) external {
        uint256 w = seed % 2;
        address asset = wrappers[w].underlying();
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.WrapperAlreadyRegistered.selector,
                asset,
                address(wrappers[w])
            )
        );
        vm.prank(businessOwner);
        registry.registerWrapper(asset, address(wrappers[1 - w]));
        assertConfiguration();
        duplicateRegistrations += 1;
    }

    // AS-14/17: actual registry Ownable authority transfers immediately, independently
    // of all four ProxyAdmins. No two-step ownership behavior is assumed.
    function handoverBusinessOwnership(uint256 seed) external {
        address previous = businessOwner;
        address next = previous == address(this) ? account(11) : address(this);
        vm.prank(previous);
        registry.transferOwnership(next);
        businessOwner = next;
        bytes[4] memory calls = [
            abi.encodeCall(
                registry.setWrapperMinimums, (address(wrappers[0]), uint64(1), minimums[0])
            ),
            abi.encodeCall(registry.setUnshieldRateLimits, (refillPerSecond, burst)),
            abi.encodeCall(
                registry.setWrapperDeploymentConfiguration, (_nextImplementations[2], next)
            ),
            abi.encodeCall(registry.setTrustedSwapEscrow, (address(wrappers[seed % 2])))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(previous);
            (bool success, bytes memory reason) = address(registry).call(calls[i]);
            assertFalse(success);
            assertEq(
                reason,
                abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, previous)
            );
        }
        vm.prank(next);
        registry.setWrapperMinimums(address(wrappers[0]), 1, minimums[0]);
        businessHandovers += 1;
        assertConfiguration();
    }

    // AS-03/06: neither the request caller nor a claimant can redirect a debit.
    // AS-03: external proofs bind the source, consumer and chain. These are
    // cryptographic verifier fixtures; live-network parity remains AS-16.
    function rejectInputDomainMutation(uint256 seed, uint8 rawMode) external {
        uint256 w = seed % 2;
        uint256 u = (seed / 2) % 4;
        uint8 mode = rawMode % 3;
        address user = account(u);
        externalEuint64 amount = createExternalEuint64(17, user);
        address proofConsumer = mode == 0 ? address(wrappers[1 - w]) : address(wrappers[w]);
        bytes memory proof = _inputProof(proofConsumer, amount);
        bytes32 beforeState = _stateHash(w, u);
        uint256 chain = block.chainid;
        if (mode == 1) vm.chainId(chain + 1);
        address caller = mode == 2 ? account((u + 1) % 4) : user;
        if (mode == 2) {
            vm.expectRevert(
                abi.encodeWithSelector(MockCoFheTaskManager.SenderMismatch.selector, user, caller)
            );
        } else {
            vm.expectPartialRevert(MockCoFheTaskManager.InvalidSigner.selector);
        }
        vm.prank(caller);
        wrappers[w].confidentialTransfer(account((u + 1) % 4), amount, proof);
        if (mode == 1) vm.chainId(chain);
        assertEq(_stateHash(w, u), beforeState);
        rejectedInputDomains += 1;
    }

    function rejectUnauthorizedDebit(uint256 seed) external {
        uint256 w = seed % 2;
        uint256 u = (seed / 2) % 4;
        address stranger = account(12);
        bytes32 beforeState = _stateHash(w, u);
        vm.expectRevert(
            abi.encodeWithSignature(
                "FHERC20UnauthorizedSpender(address,address)", account(u), stranger
            )
        );
        vm.prank(stranger);
        wrappers[w].unshield(account(u), stranger, minimums[w]);
        assertEq(_stateHash(w, u), beforeState);
        rejectedUnauthorizedDebits += 1;
    }

    function rejectIncorrectDecryption(uint256 seed) external {
        uint256 w = seed % 2;
        uint256 u = (seed / 2) % 4;
        bytes32 id = pending[w][u];
        if (id == bytes32(0)) return;
        bytes32 handle = wrappers[w].getClaim(id).ctHash;
        uint64 actual = pendingAmounts[w][u];
        uint64 wrong = actual == type(uint64).max ? actual - 1 : actual + 1;
        taskManager.publishDecryptResult(uint256(handle), actual, "");
        bytes32 beforeState = keccak256(abi.encode(wrappers[w].getClaim(id), _stateHash(w, u)));
        vm.expectRevert(
            abi.encodeWithSelector(
                MockCoFheTaskManager.InvalidDecryptResult.selector,
                uint256(handle),
                uint256(actual),
                uint256(wrong)
            )
        );
        wrappers[w].claimUnshielded(id, wrong, "");
        assertEq(keccak256(abi.encode(wrappers[w].getClaim(id), _stateHash(w, u))), beforeState);
        rejectedDecryptions += 1;
    }

    // AS-11/17: ordinary pending claims keep their source/recipient/amount when
    // an authorized business owner rotates the separate swap bypass identity.
    function rotateTrustedEscrow(uint256 seed) external {
        trustedEscrow = address(_escrows[seed % 2]);
        vm.prank(businessOwner);
        registry.setTrustedSwapEscrow(trustedEscrow);
        escrowRotations += 1;
    }

    function _availableTokens() private view returns (uint256 available) {
        available = uint256(tokens) + (block.timestamp - tokensAt) * refillPerSecond;
        if (available > burst) available = burst;
    }

    function _stateHash(uint256 w, uint256 u) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                wrappers[w].confidentialBalanceOf(account(u)),
                wrappers[w].pendingUnshieldClaimId(account(u)),
                wrappers[w].unshieldCooldownUntil(account(u)),
                registry.availableUnshieldTokens(),
                registry.unshieldTokensUpdatedAt()
            )
        );
    }

    function _admin(uint256 i) private view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(_proxies[i], ADMIN_SLOT)))));
    }

    function _complete(uint256 w, uint256 u) private {
        uint64 amount = pendingAmounts[w][u];
        uint256 recipient = pendingRecipients[w][u];
        paid[w][recipient] += amount;
        exited[w][u] += amount;
        _completed.push(CompletedClaim(w, pending[w][u], amount));
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
            assets[w] = w == 0
                ? new MockZeroTransferRevertingERC20("Zero rejecting underlying", "ZR", 6)
                : new MockERC20("Underlying", "TOK", 18);
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
        bytes4[] memory selectors = new bytes4[](19);
        selectors[0] = handler.request.selector;
        selectors[1] = handler.claimSingle.selector;
        selectors[2] = handler.claimBatch.selector;
        selectors[3] = handler.advanceTime.selector;
        selectors[4] = handler.upgrade.selector;
        selectors[5] = handler.handoverAdmin.selector;
        selectors[6] = handler.configureMinimum.selector;
        selectors[7] = handler.configureFutureWrapper.selector;
        selectors[8] = handler.depositAgain.selector;
        selectors[9] = handler.transferConfidential.selector;
        selectors[10] = handler.configureBudget.selector;
        selectors[11] = handler.rejectUnauthenticatedShare.selector;
        selectors[12] = handler.rejectClaimReplay.selector;
        selectors[13] = handler.rejectDuplicateRegistration.selector;
        selectors[14] = handler.handoverBusinessOwnership.selector;
        selectors[15] = handler.rejectUnauthorizedDebit.selector;
        selectors[16] = handler.rejectIncorrectDecryption.selector;
        selectors[17] = handler.rotateTrustedEscrow.selector;
        selectors[18] = handler.rejectInputDomainMutation.selector;
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
        handler.depositAgain(0, 1000);
        handler.transferConfidential(0, 100);
        handler.configureBudget(2, 16);
        handler.rejectUnauthenticatedShare(0);
        handler.rejectClaimReplay(0);
        handler.rejectDuplicateRegistration(0);
        handler.handoverBusinessOwnership(0);
        handler.request(6, 0, 2);
        handler.depositAgain(6, 777);
        handler.rotateTrustedEscrow(0);
        handler.rejectIncorrectDecryption(6);
        handler.rejectUnauthorizedDebit(6);
        handler.rejectInputDomainMutation(6, 0);
        handler.rejectInputDomainMutation(6, 1);
        handler.rejectInputDomainMutation(6, 2);
        handler.claimSingle(6);
    }

    /// @dev Echidna entry point reusing the same handlers/oracle; unexpected reverts must fail.
    function exercise(uint8 action, uint256 seed, uint64 value) external {
        bytes memory data;
        action %= 19;
        if (action == 0) {
            data = abi.encodeCall(handler.request, (seed, value, uint8(seed)));
        } else if (action == 1) {
            data = abi.encodeCall(handler.claimSingle, (seed));
        } else if (action == 2) {
            data = abi.encodeCall(handler.claimBatch, (seed));
        } else if (action == 3) {
            data = abi.encodeCall(handler.advanceTime, (uint16(value)));
        } else if (action == 4) {
            data = abi.encodeCall(handler.upgrade, (seed));
        } else if (action == 5) {
            data = abi.encodeCall(handler.handoverAdmin, (seed));
        } else if (action == 6) {
            data = abi.encodeCall(handler.configureMinimum, (seed, value));
        } else if (action == 7) {
            data = abi.encodeCall(handler.configureFutureWrapper, (seed));
        } else if (action == 8) {
            data = abi.encodeCall(handler.depositAgain, (seed, value));
        } else if (action == 9) {
            data = abi.encodeCall(handler.transferConfidential, (seed, value));
        } else if (action == 10) {
            data = abi.encodeCall(handler.configureBudget, (uint16(value), uint16(seed)));
        } else if (action == 11) {
            data = abi.encodeCall(handler.rejectUnauthenticatedShare, (seed));
        } else if (action == 12) {
            data = abi.encodeCall(handler.rejectClaimReplay, (seed));
        } else if (action == 13) {
            data = abi.encodeCall(handler.rejectDuplicateRegistration, (seed));
        } else if (action == 14) {
            data = abi.encodeCall(handler.handoverBusinessOwnership, (seed));
        } else if (action == 15) {
            data = abi.encodeCall(handler.rejectUnauthorizedDebit, (seed));
        } else if (action == 16) {
            data = abi.encodeCall(handler.rejectIncorrectDecryption, (seed));
        } else if (action == 17) {
            data = abi.encodeCall(handler.rotateTrustedEscrow, (seed));
        } else {
            data = abi.encodeCall(handler.rejectInputDomainMutation, (seed, uint8(value)));
        }
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
                assertEq(balance + amount + handler.exited(w, u), handler.endowments(w, u));
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
        assertGt(handler.deposits(), 0);
        assertGt(handler.transfers(), 0);
        assertGt(handler.budgetUpdates(), 0);
        assertGt(handler.businessHandovers(), 0);
        assertGt(handler.rejectedShares(), 0);
        assertGt(handler.rejectedInputDomains(), 2);
        assertGt(handler.rejectedClaims(), 0);
        assertGt(handler.duplicateRegistrations(), 0);
        assertGt(handler.delegatedClaims(), 0);
        assertGt(handler.rejectedUnauthorizedDebits(), 0);
        assertGt(handler.rejectedDecryptions(), 0);
        assertGt(handler.escrowRotations(), 0);
        assertGt(handler.postRequestFunding(), 0);
    }
}

/// @dev Valid registry-bound governance surface; it never receives confidential balances.
contract UnshieldEscrowProbe {
    address public immutable assetRegistry;
    uint256 public constant liveSwapLockCount = 0;

    constructor(address registry) {
        assetRegistry = registry;
    }
}
