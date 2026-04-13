// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IERC7984} from "fhenix-confidential-contracts/interfaces/IERC7984.sol";
import {IFHERC20ERC20Wrapper} from
    "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {AlphaEngineConfidentialVault} from "src/vault/AlphaEngineConfidentialVault.sol";
import {VaultInvariantHandler} from "test/handlers/VaultInvariantHandler.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AlphaEngineConfidentialVaultInvariantTest is MockCoFheTest {
    uint256 private constant USER_STARTING_UNDERLYING = 1_000_000_000e6;

    AlphaEngineConfidentialVault internal vault;
    MockERC20 internal underlying;
    address internal wrapper;
    VaultInvariantHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");

    function setUp() public {
        _installMockTaskManager();

        underlying = new MockERC20("Invariant USDC", "iUSDC", 6);
        vault = _deployVault(owner);

        vm.prank(owner);
        wrapper = vault.createWrapper(address(underlying), "Encrypted Invariant USDC", "eiUSDC", "");

        handler = new VaultInvariantHandler(vault, underlying, wrapper, owner, userA, userB);

        vm.prank(owner);
        vault.setIntentController(address(handler));

        _fundAndAuthorize(userA);
        _fundAndAuthorize(userB);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = VaultInvariantHandler.depositAsA.selector;
        selectors[1] = VaultInvariantHandler.depositAsB.selector;
        selectors[2] = VaultInvariantHandler.lockAsA.selector;
        selectors[3] = VaultInvariantHandler.lockAsB.selector;
        selectors[4] = VaultInvariantHandler.requestUnshieldAsA.selector;
        selectors[5] = VaultInvariantHandler.requestUnshieldAsB.selector;
        selectors[6] = VaultInvariantHandler.claimUnshield.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_wrapperRegistryRemainsStable() public view {
        assertEq(vault.wrapperForUnderlying(address(underlying)), wrapper);
        assertEq(vault.underlyingForWrapper(wrapper), address(underlying));
        assertEq(IFHERC20ERC20Wrapper(wrapper).underlying(), address(underlying));
        assertTrue(wrapper != address(0));
        assertTrue(address(underlying) != address(0));
        assertTrue(IFHERC20ERC20Wrapper(wrapper).rate() > 0);
    }

    function invariant_lockLifecycleAndFieldsRemainConsistent() public view {
        uint256 length = handler.lockIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 intentId = handler.lockIdAt(index);
            VaultInvariantHandler.LockSnapshot memory snapshot = handler.lockSnapshot(intentId);
            AlphaEngineConfidentialVault.SwapIntentLock memory intentLock =
                vault.getSwapIntentLock(intentId);

            assertTrue(handler.knownLock(intentId));
            assertEq(intentLock.account, snapshot.account);
            assertEq(intentLock.wrapper, snapshot.wrapper);
            assertEq(euint64.unwrap(intentLock.lockedAmount), snapshot.lockedAmountHandle);
            assertEq(_evalue(intentLock.lockedAmount), snapshot.lockedValue);
            assertEq(uint8(intentLock.status), uint8(snapshot.expectedStatus));
            assertEq(
                euint64.unwrap(intentLock.unshieldRequestHandle), snapshot.unshieldRequestHandle
            );
            if (
                snapshot.expectedStatus
                    == AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested
            ) {
                assertTrue(snapshot.unshieldRequestHandle != bytes32(0));
                assertEq(_evalue(intentLock.unshieldRequestHandle), snapshot.lockedValue);
            }
            assertTrue(intentLock.account == userA || intentLock.account == userB);
            assertEq(intentLock.wrapper, wrapper);
        }
    }

    function invariant_vaultEscrowBalanceMatchesActiveAndConsumedLocks() public view {
        assertEq(_confidentialBalance(address(vault)), 0);
    }

    function invariant_userConfidentialBalancesRemainConserved() public view {
        _assertUserConservation(userA);
        _assertUserConservation(userB);
    }

    function invariant_confidentialSupplyMatchesTrackedBalances() public view {
        assertEq(
            _confidentialTotalSupply(),
            _confidentialBalance(userA) + _confidentialBalance(userB)
                + _confidentialBalance(address(vault))
        );
    }

    function invariant_underlyingReserveMatchesSupplyPlusPendingUnshield() public view {
        uint256 rate = IFHERC20ERC20Wrapper(wrapper).rate();
        assertEq(
            underlying.balanceOf(wrapper) / rate,
            _confidentialTotalSupply() + handler.totalPendingUnshieldUnits()
        );
        assertEq(
            underlying.balanceOf(address(vault)) / rate, handler.vaultClaimedSwapUnshieldUnits()
        );
    }

    function invariant_claimSnapshotsRemainConsistent() public view {
        uint256 length = handler.claimIdsLength();
        for (uint256 index = 0; index < length; ++index) {
            bytes32 requestId = handler.claimIdAt(index);
            VaultInvariantHandler.ClaimSnapshot memory snapshot = handler.claimSnapshot(requestId);

            assertEq(snapshot.requestId, requestId);
            assertTrue(snapshot.account == userA || snapshot.account == userB);
            assertTrue(snapshot.amount > 0);
        }
    }

    function invariant_vaultIntentControllerRemainsHandler() public view {
        assertEq(vault.intentController(), address(handler));
        assertEq(vault.owner(), owner);
    }

    function _assertUserConservation(address account) private view {
        assertEq(
            _confidentialBalance(account) + handler.unshieldRequestedUnitsByAccount(account),
            handler.shieldedDepositsByAccount(account)
        );
    }

    function _fundAndAuthorize(address account) private {
        underlying.mint(account, USER_STARTING_UNDERLYING);

        vm.startPrank(account);
        underlying.approve(address(vault), type(uint256).max);
        AlphaEngineFHERC20ERC20Wrapper(wrapper).setOperator(address(vault), type(uint48).max);
        vm.stopPrank();
    }

    function _confidentialBalance(address account) private view returns (uint256) {
        return _evalue(IERC7984(wrapper).confidentialBalanceOf(account));
    }

    function _confidentialTotalSupply() private view returns (uint256) {
        return _evalue(IERC7984(wrapper).confidentialTotalSupply());
    }

    function _evalue(euint64 encryptedValue) private view returns (uint256) {
        bytes32 handle = euint64.unwrap(encryptedValue);
        if (handle == bytes32(0)) {
            return 0;
        }

        return mockStorage(uint256(handle));
    }

    function _deployVault(address vaultIntentController)
        private
        returns (AlphaEngineConfidentialVault deployedVault)
    {
        AlphaEngineConfidentialVault vaultImplementation = new AlphaEngineConfidentialVault();
        TransparentUpgradeableProxy vaultProxy = new TransparentUpgradeableProxy(
            address(vaultImplementation),
            owner,
            abi.encodeCall(AlphaEngineConfidentialVault.initialize, (owner, vaultIntentController))
        );
        deployedVault = AlphaEngineConfidentialVault(address(vaultProxy));
    }
}
