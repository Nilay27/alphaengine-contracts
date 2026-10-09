// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {FHE, euint64, sharedEuint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {
    AlphaEngineConfidentialAssetRegistry
} from "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";

/// @dev Independent amount, admission and cooldown model; invalid requests assert exact errors.
contract UnshieldAdmissionHandler is MockCoFheTest {
    AlphaEngineConfidentialAssetRegistry public registry;
    AlphaEngineFHERC20ERC20Wrapper[2] public wrappers;
    uint64[4][2] public balances;
    uint64[4][2] public paid;
    bytes32[4][2] public pending;
    uint64[4][2] public pendingAmounts;
    uint40[4][2] public cooldowns;
    uint16 public tokens = 8;
    uint40 public tokensAt;
    uint256 public successfulRequests;
    uint256 public rejectedRequests;
    uint256 public singleClaims;
    uint256 public batchClaims;

    constructor(AlphaEngineConfidentialAssetRegistry registry_, address first, address second) {
        registry = registry_;
        wrappers[0] = AlphaEngineFHERC20ERC20Wrapper(first);
        wrappers[1] = AlphaEngineFHERC20ERC20Wrapper(second);
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
        uint64 minimum = w == 0 ? 1000 : 10;
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

    function _complete(uint256 w, uint256 u) private {
        uint64 amount = pendingAmounts[w][u];
        paid[w][u] += amount;
        if (amount == 0) cooldowns[w][u] = uint40(block.timestamp + 5 minutes);
        delete pending[w][u];
        delete pendingAmounts[w][u];
    }
}

contract AlphaEngineUnshieldAdmissionInvariantTest is StdInvariant, MockCoFheTest {
    AlphaEngineConfidentialAssetRegistry private registry;
    AlphaEngineFHERC20ERC20Wrapper[2] private wrappers;
    MockERC20[2] private assets;
    UnshieldAdmissionHandler private handler;

    function setUp() public {
        _installMockTaskManager();
        registry = new AlphaEngineConfidentialAssetRegistry(address(this));
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
        handler = new UnshieldAdmissionHandler(registry, address(wrappers[0]), address(wrappers[1]));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.request.selector;
        selectors[1] = handler.claimSingle.selector;
        selectors[2] = handler.claimBatch.selector;
        selectors[3] = handler.advanceTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
        handler.request(0, 999, 1);
        handler.request(2, 1000, 0);
        handler.claimBatch(0);
        handler.request(0, 1000, 0);
        handler.request(4, 0, 2);
        handler.claimSingle(4);
    }

    function invariant_amountsPendingCooldownsAndBudgetMatchIndependentModel() public view {
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
    }
}
