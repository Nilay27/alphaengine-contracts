// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {FHE, InEuint64, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IFHERC20ERC20Wrapper} from
    "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {FHERC20WrapperClaimHelper} from
    "fhenix-confidential-contracts/FHERC20/utils/FHERC20WrapperClaimHelper.sol";
import {AlphaEngineConfidentialVault} from "../../src/vault/AlphaEngineConfidentialVault.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "../../src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {MockCoFheTest} from "../mocks/MockCoFheTest.sol";
import {MockERC20, MockSelectiveFeeERC20} from "../mocks/MockERC20.sol";

contract AlphaEngineConfidentialVaultUnitTest is MockCoFheTest {
    event IntentControllerUpdated(
        address indexed previousIntentController, address indexed newIntentController
    );
    event ConfidentialWrapperRegistered(address indexed underlying, address indexed wrapper);
    event DepositedAndShielded(
        address indexed underlying,
        address indexed wrapper,
        address indexed depositor,
        address recipient,
        uint256 amount,
        euint64 shieldedAmount
    );
    event UnshieldRequested(
        address indexed wrapper,
        address indexed account,
        address indexed recipient,
        uint64 amount,
        euint64 unshieldRequestHandle
    );
    event UnshieldClaimed(
        address indexed wrapper, bytes32 indexed unshieldRequestId, uint64 decryptedAmount
    );
    event SwapIntentLocked(
        bytes32 indexed intentId,
        address indexed account,
        address indexed wrapper,
        euint64 lockedAmount
    );
    event SwapIntentLockConsumed(
        bytes32 indexed intentId,
        address indexed account,
        address indexed wrapper,
        euint64 consumedAmount
    );
    event SwapIntentUnshieldRequested(
        bytes32 indexed intentId,
        address indexed account,
        address indexed inputWrapper,
        euint64 unshieldRequestHandle
    );
    event Paused(address account);
    event Unpaused(address account);

    AlphaEngineConfidentialVault private implementation;
    AlphaEngineConfidentialVault private vault;
    TransparentUpgradeableProxy private proxy;
    MockERC20 private underlying;

    address private owner = address(0xA11CE);
    address private intentController = address(0x1A7E17);
    address private user = address(0xB0B);
    address private recipient = address(0xC0DE);

    function setUp() public {
        _installMockTaskManager();

        underlying = new MockERC20("USD Coin", "USDC", 6);

        implementation = new AlphaEngineConfidentialVault();
        proxy = new TransparentUpgradeableProxy(
            address(implementation),
            owner,
            abi.encodeCall(AlphaEngineConfidentialVault.initialize, (owner, intentController))
        );
        vault = AlphaEngineConfidentialVault(address(proxy));
    }

    function testConstructorDisablesImplementationInitializer() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, intentController);
    }

    function testInitializeEmitsIntentControllerUpdated() public {
        AlphaEngineConfidentialVault freshVault = new AlphaEngineConfidentialVault();
        bytes memory initData =
            abi.encodeCall(AlphaEngineConfidentialVault.initialize, (owner, intentController));

        vm.expectEmit(true, true, true, true);
        emit IntentControllerUpdated(address(0), intentController);

        new TransparentUpgradeableProxy(address(freshVault), owner, initData);
    }

    function testInitializePersistsOwnerAndIntentController() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.intentController(), intentController);
    }

    function testInitializeRejectsZeroOwner() public {
        AlphaEngineConfidentialVault freshVault = new AlphaEngineConfidentialVault();
        bytes memory initData =
            abi.encodeCall(AlphaEngineConfidentialVault.initialize, (address(0), intentController));

        vm.expectRevert(AlphaEngineConfidentialVault.ZeroOwner.selector);
        new TransparentUpgradeableProxy(address(freshVault), owner, initData);
    }

    function testInitializeRejectsZeroIntentController() public {
        AlphaEngineConfidentialVault freshVault = new AlphaEngineConfidentialVault();
        bytes memory initData =
            abi.encodeCall(AlphaEngineConfidentialVault.initialize, (owner, address(0)));

        vm.expectRevert(AlphaEngineConfidentialVault.ZeroIntentController.selector);
        new TransparentUpgradeableProxy(address(freshVault), owner, initData);
    }

    function testInitializeRejectsReinitialization() public {
        vm.expectRevert();
        vault.initialize(owner, intentController);
    }

    function testOwnerCanSetIntentController() public {
        address newIntentController = address(0xCA11);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IntentControllerUpdated(intentController, newIntentController);

        vm.prank(owner);
        vault.setIntentController(newIntentController);

        assertEq(vault.intentController(), newIntentController);
    }

    function testSetIntentControllerRejectsUnauthorizedCaller() public {
        vm.prank(user);
        vm.expectRevert();
        vault.setIntentController(address(0xCA11));
    }

    function testSetIntentControllerRejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AlphaEngineConfidentialVault.ZeroIntentController.selector);
        vault.setIntentController(address(0));
    }

    function testOwnerCanCreateWrapperForUnderlying() public {
        vm.recordLogs();

        vm.prank(owner);
        address wrapper = vault.createWrapper(address(underlying), "Encrypted USDC", "eUSDC", "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(vault.wrapperForUnderlying(address(underlying)), wrapper);
        assertEq(vault.underlyingForWrapper(wrapper), address(underlying));
        assertEq(IFHERC20ERC20Wrapper(wrapper).underlying(), address(underlying));
        assertEq(AlphaEngineFHERC20ERC20Wrapper(wrapper).name(), "Encrypted USDC");
        assertEq(AlphaEngineFHERC20ERC20Wrapper(wrapper).symbol(), "eUSDC");
        assertEq(AlphaEngineFHERC20ERC20Wrapper(wrapper).decimals(), 6);
        _assertWrapperRegisteredLog(logs, address(underlying), wrapper);
    }

    function testCreateWrapperCapsDecimalsAtFHERC20Precision() public {
        MockERC20 highPrecisionToken = new MockERC20("High Precision", "HIGH", 18);

        vm.prank(owner);
        address wrapper =
            vault.createWrapper(address(highPrecisionToken), "Encrypted HIGH", "eHIGH", "");

        assertEq(AlphaEngineFHERC20ERC20Wrapper(wrapper).decimals(), 6);
        assertEq(IFHERC20ERC20Wrapper(wrapper).rate(), 1e12);
    }

    function testCreateWrapperUsesFallbackDecimalsWhenUnderlyingOmitsMetadata() public {
        NonMetadataERC20 nonMetadataToken = new NonMetadataERC20();

        vm.prank(owner);
        address wrapper =
            vault.createWrapper(address(nonMetadataToken), "Encrypted Token", "eTOKEN", "");

        assertEq(AlphaEngineFHERC20ERC20Wrapper(wrapper).decimals(), 6);
        assertEq(IFHERC20ERC20Wrapper(wrapper).rate(), 1e12);
    }

    function testCreateWrapperRejectsUnauthorizedCaller() public {
        vm.prank(user);
        vm.expectRevert();
        vault.createWrapper(address(underlying), "Encrypted USDC", "eUSDC", "");
    }

    function testCreateWrapperRejectsZeroUnderlying() public {
        vm.prank(owner);
        vm.expectRevert(AlphaEngineConfidentialVault.ZeroUnderlying.selector);
        vault.createWrapper(address(0), "Encrypted Zero", "eZERO", "");
    }

    function testCreateWrapperRejectsNonContractUnderlying() public {
        address invalidUnderlying = address(0xE0A);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.InvalidUnderlying.selector, invalidUnderlying
            )
        );
        vault.createWrapper(invalidUnderlying, "Encrypted Invalid", "eINVALID", "");
    }

    function testCreateWrapperRejectsDuplicateUnderlying() public {
        vm.startPrank(owner);
        address wrapper = vault.createWrapper(address(underlying), "Encrypted USDC", "eUSDC", "");

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.WrapperAlreadyRegistered.selector,
                address(underlying),
                wrapper
            )
        );
        vault.createWrapper(address(underlying), "Encrypted USDC 2", "eUSDC2", "");
        vm.stopPrank();
    }

    function testOwnerCanRegisterExistingWrapper() public {
        AlphaEngineFHERC20ERC20Wrapper wrapper =
            new AlphaEngineFHERC20ERC20Wrapper(underlying, "Encrypted USDC", "eUSDC", "");

        vm.expectEmit(true, true, true, true, address(vault));
        emit ConfidentialWrapperRegistered(address(underlying), address(wrapper));

        vm.prank(owner);
        vault.registerWrapper(address(underlying), address(wrapper));

        assertEq(vault.wrapperForUnderlying(address(underlying)), address(wrapper));
        assertEq(vault.underlyingForWrapper(address(wrapper)), address(underlying));
    }

    function testRegisterWrapperRejectsDuplicateUnderlying() public {
        AlphaEngineFHERC20ERC20Wrapper wrapper =
            new AlphaEngineFHERC20ERC20Wrapper(underlying, "Encrypted USDC", "eUSDC", "");

        vm.startPrank(owner);
        vault.registerWrapper(address(underlying), address(wrapper));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.WrapperAlreadyRegistered.selector,
                address(underlying),
                address(wrapper)
            )
        );
        vault.registerWrapper(address(underlying), address(0xF0));
        vm.stopPrank();
    }

    function testRegisterWrapperRejectsDuplicateWrapper() public {
        MockERC20 otherUnderlying = new MockERC20("Other Token", "OTHER", 6);
        AlphaEngineFHERC20ERC20Wrapper wrapper =
            new AlphaEngineFHERC20ERC20Wrapper(underlying, "Encrypted USDC", "eUSDC", "");

        vm.startPrank(owner);
        vault.registerWrapper(address(underlying), address(wrapper));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.WrapperAlreadyRegistered.selector,
                address(underlying),
                address(wrapper)
            )
        );
        vault.registerWrapper(address(otherUnderlying), address(wrapper));
        vm.stopPrank();
    }

    function testRegisterWrapperRejectsZeroUnderlying() public {
        vm.prank(owner);
        vm.expectRevert(AlphaEngineConfidentialVault.ZeroUnderlying.selector);
        vault.registerWrapper(address(0), address(0xF0));
    }

    function testRegisterWrapperRejectsNonContractUnderlying() public {
        address invalidUnderlying = address(0xE0A);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.InvalidUnderlying.selector, invalidUnderlying
            )
        );
        vault.registerWrapper(invalidUnderlying, address(0xF0));
    }

    function testRegisterWrapperRejectsZeroWrapper() public {
        vm.prank(owner);
        vm.expectRevert(AlphaEngineConfidentialVault.ZeroWrapper.selector);
        vault.registerWrapper(address(underlying), address(0));
    }

    function testRegisterWrapperRejectsNonContractWrapper() public {
        address invalidWrapper = address(0xF0);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.InvalidWrapper.selector, invalidWrapper
            )
        );
        vault.registerWrapper(address(underlying), invalidWrapper);
    }

    function testRegisterWrapperRejectsWrapperWithoutUnderlyingSurface() public {
        address invalidWrapper = address(new NoWrapperSurface());

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.InvalidWrapper.selector, invalidWrapper
            )
        );
        vault.registerWrapper(address(underlying), invalidWrapper);
    }

    function testRegisterWrapperRejectsMalformedUnderlyingSurface() public {
        address invalidWrapper = address(new MalformedWrapperSurface());

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.InvalidWrapper.selector, invalidWrapper
            )
        );
        vault.registerWrapper(address(underlying), invalidWrapper);
    }

    function testRegisterWrapperRejectsWrapperWithoutRateSurface() public {
        address invalidWrapper = address(new NoRateWrapperSurface(address(underlying)));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.InvalidWrapper.selector, invalidWrapper
            )
        );
        vault.registerWrapper(address(underlying), invalidWrapper);
    }

    function testRegisterWrapperRejectsZeroRateWrapper() public {
        address invalidWrapper = address(new ZeroRateWrapperSurface(address(underlying)));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.InvalidWrapper.selector, invalidWrapper
            )
        );
        vault.registerWrapper(address(underlying), invalidWrapper);
    }

    function testRegisterWrapperRejectsUnderlyingMismatch() public {
        MockERC20 otherUnderlying = new MockERC20("Other Token", "OTHER", 6);
        AlphaEngineFHERC20ERC20Wrapper wrapper =
            new AlphaEngineFHERC20ERC20Wrapper(underlying, "Encrypted USDC", "eUSDC", "");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.WrapperUnderlyingMismatch.selector,
                address(wrapper),
                address(otherUnderlying),
                address(underlying)
            )
        );
        vault.registerWrapper(address(otherUnderlying), address(wrapper));
    }

    function testDepositAndShieldUsesRegisteredWrapperAndEmitsEvent() public {
        address wrapper = _createDefaultWrapper();
        uint256 amount = 100e6;
        underlying.mint(user, amount);

        vm.startPrank(user);
        underlying.approve(address(vault), amount);

        vm.expectEmit(true, true, true, false, address(vault));
        emit DepositedAndShielded(
            address(underlying), wrapper, user, recipient, amount, euint64.wrap(bytes32(0))
        );

        (address returnedWrapper, euint64 shieldedAmount) =
            vault.depositAndShield(address(underlying), amount, recipient);
        vm.stopPrank();

        assertEq(returnedWrapper, wrapper);
        assertEq(underlying.balanceOf(user), 0);
        assertEq(underlying.balanceOf(address(vault)), 0);
        assertEq(underlying.balanceOf(wrapper), amount);
        assertEq(mockStorage(uint256(euint64.unwrap(shieldedAmount))), amount);

        euint64 recipientBalance =
            AlphaEngineFHERC20ERC20Wrapper(wrapper).confidentialBalanceOf(recipient);
        assertEq(mockStorage(uint256(euint64.unwrap(recipientBalance))), amount);
    }

    function testDepositAndShieldRejectsUnregisteredUnderlying() public {
        MockERC20 unregisteredToken = new MockERC20("Unregistered", "NOPE", 6);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.UnderlyingNotRegistered.selector,
                address(unregisteredToken)
            )
        );
        vault.depositAndShield(address(unregisteredToken), 1, recipient);
    }

    function testDepositAndShieldRejectsZeroRecipient() public {
        _createDefaultWrapper();

        vm.prank(user);
        vm.expectRevert(AlphaEngineConfidentialVault.ZeroRecipient.selector);
        vault.depositAndShield(address(underlying), 1, address(0));
    }

    function testDepositAndShieldRejectsZeroAmount() public {
        _createDefaultWrapper();

        vm.prank(user);
        vm.expectRevert(AlphaEngineConfidentialVault.ZeroAmount.selector);
        vault.depositAndShield(address(underlying), 0, recipient);
    }

    function testDepositAndShieldRejectsAmountNotMultipleOfRate() public {
        MockERC20 highPrecisionToken = new MockERC20("High Precision", "HIGH", 18);

        vm.prank(owner);
        vault.createWrapper(address(highPrecisionToken), "Encrypted HIGH", "eHIGH", "");

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.AmountNotMultipleOfRate.selector, 1, 1e12
            )
        );
        vault.depositAndShield(address(highPrecisionToken), 1, recipient);
    }

    function testDepositAndShieldRejectsAmountBeyondFHERC20Precision() public {
        MockERC20 highPrecisionToken = new MockERC20("High Precision", "HIGH", 18);
        uint256 amount = (uint256(type(uint64).max) + 1) * 1e12;

        vm.prank(owner);
        vault.createWrapper(address(highPrecisionToken), "Encrypted HIGH", "eHIGH", "");

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.AmountExceedsFHERC20Precision.selector, amount, 1e12
            )
        );
        vault.depositAndShield(address(highPrecisionToken), amount, recipient);
    }

    function testDepositAndShieldRejectsFeeOnUserTransfer() public {
        MockSelectiveFeeERC20 feeToken = new MockSelectiveFeeERC20("Fee Token", "FEE", 6);
        vm.prank(owner);
        vault.createWrapper(address(feeToken), "Encrypted FEE", "eFEE", "");

        uint256 amount = 100e6;
        feeToken.mint(user, amount);
        feeToken.setFeeRoute(user, address(vault));

        vm.startPrank(user);
        feeToken.approve(address(vault), amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.UnexpectedUnderlyingBalance.selector,
                address(vault),
                address(feeToken),
                amount,
                amount - 1
            )
        );
        vault.depositAndShield(address(feeToken), amount, recipient);
        vm.stopPrank();
    }

    function testDepositAndShieldRejectsFeeOnWrapperTransfer() public {
        MockSelectiveFeeERC20 feeToken = new MockSelectiveFeeERC20("Fee Token", "FEE", 6);
        vm.prank(owner);
        address wrapper = vault.createWrapper(address(feeToken), "Encrypted FEE", "eFEE", "");

        uint256 amount = 100e6;
        feeToken.mint(user, amount);
        feeToken.setFeeRoute(address(vault), wrapper);

        vm.startPrank(user);
        feeToken.approve(address(vault), amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.UnexpectedUnderlyingBalance.selector,
                wrapper,
                address(feeToken),
                amount,
                amount - 1
            )
        );
        vault.depositAndShield(address(feeToken), amount, recipient);
        vm.stopPrank();
    }

    function testRequestUnshieldAndClaimUsesRegisteredWrapper() public {
        address wrapper = _createDefaultWrapper();
        uint256 depositAmount = 100e6;
        uint64 unshieldAmount = 40e6;
        underlying.mint(user, depositAmount);

        vm.startPrank(user);
        underlying.approve(address(vault), depositAmount);
        vault.depositAndShield(address(underlying), depositAmount, user);
        AlphaEngineFHERC20ERC20Wrapper(wrapper).setOperator(
            address(vault), uint48(block.timestamp + 1 hours)
        );

        vm.expectEmit(true, true, true, false, address(vault));
        emit UnshieldRequested(wrapper, user, user, unshieldAmount, euint64.wrap(bytes32(0)));

        euint64 unshieldHandle = vault.requestUnshield(wrapper, user, unshieldAmount);
        vm.stopPrank();

        bytes32 unshieldRequestId = euint64.unwrap(unshieldHandle);
        assertEq(mockStorage(uint256(unshieldRequestId)), unshieldAmount);

        FHERC20WrapperClaimHelper.Claim memory claim =
            AlphaEngineFHERC20ERC20Wrapper(wrapper).getClaim(unshieldRequestId);
        assertEq(claim.to, user);
        assertEq(claim.ctHash, unshieldRequestId);
        assertEq(claim.requestedAmount, unshieldAmount);
        assertFalse(claim.claimed);
        assertEq(underlying.balanceOf(user), 0);

        taskManager.publishDecryptResult(uint256(unshieldRequestId), unshieldAmount, "");

        vm.expectEmit(true, true, true, true, address(vault));
        emit UnshieldClaimed(wrapper, unshieldRequestId, unshieldAmount);

        vault.claimUnshielded(wrapper, unshieldRequestId, unshieldAmount, "");
        assertEq(underlying.balanceOf(user), unshieldAmount);

        FHERC20WrapperClaimHelper.Claim memory claimed =
            AlphaEngineFHERC20ERC20Wrapper(wrapper).getClaim(unshieldRequestId);
        assertTrue(claimed.claimed);
        assertEq(claimed.decryptedAmount, unshieldAmount);
    }

    function testRequestUnshieldRejectsUnregisteredWrapper() public {
        address unregisteredWrapper = address(0xF00D);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.WrapperNotRegistered.selector, unregisteredWrapper
            )
        );
        vault.requestUnshield(unregisteredWrapper, user, 1);
    }

    function testRequestUnshieldRejectsZeroRecipient() public {
        address wrapper = _createDefaultWrapper();

        vm.prank(user);
        vm.expectRevert(AlphaEngineConfidentialVault.ZeroRecipient.selector);
        vault.requestUnshield(wrapper, address(0), 1);
    }

    function testRequestUnshieldRejectsZeroAmount() public {
        address wrapper = _createDefaultWrapper();

        vm.prank(user);
        vm.expectRevert(AlphaEngineConfidentialVault.ZeroAmount.selector);
        vault.requestUnshield(wrapper, user, 0);
    }

    function testClaimUnshieldedRejectsUnregisteredWrapper() public {
        address unregisteredWrapper = address(0xF00D);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.WrapperNotRegistered.selector, unregisteredWrapper
            )
        );
        vault.claimUnshielded(unregisteredWrapper, bytes32("request"), 1, "");
    }

    function testIntentControllerCanLockSwapIntent() public {
        (VaultIntentControllerHarness controller, address wrapper) = _prepareLockController();
        bytes32 intentId = keccak256("intent-a");
        uint64 lockAmount = 40e6;
        InEuint64 memory encryptedLockAmount = createInEuint64(lockAmount, user);

        vm.expectEmit(true, true, true, false, address(vault));
        emit SwapIntentLocked(intentId, user, wrapper, euint64.wrap(bytes32(0)));

        vm.prank(user);
        euint64 lockedAmount =
            controller.lockWithInput(intentId, user, wrapper, encryptedLockAmount);

        AlphaEngineConfidentialVault.SwapIntentLock memory intentLock =
            vault.getSwapIntentLock(intentId);
        assertEq(intentLock.account, user);
        assertEq(intentLock.wrapper, wrapper);
        assertEq(euint64.unwrap(intentLock.lockedAmount), euint64.unwrap(lockedAmount));
        assertEq(
            uint8(intentLock.status),
            uint8(AlphaEngineConfidentialVault.SwapIntentLockStatus.UnshieldRequested)
        );
        assertEq(mockStorage(uint256(euint64.unwrap(lockedAmount))), lockAmount);
        assertEq(mockStorage(uint256(euint64.unwrap(intentLock.unshieldRequestHandle))), lockAmount);

        euint64 userBalance = AlphaEngineFHERC20ERC20Wrapper(wrapper).confidentialBalanceOf(user);
        euint64 vaultBalance =
            AlphaEngineFHERC20ERC20Wrapper(wrapper).confidentialBalanceOf(address(vault));
        assertEq(mockStorage(uint256(euint64.unwrap(userBalance))), 60e6);
        assertEq(mockStorage(uint256(euint64.unwrap(vaultBalance))), 0);

        FHERC20WrapperClaimHelper.Claim memory claim = AlphaEngineFHERC20ERC20Wrapper(wrapper)
            .getClaim(euint64.unwrap(intentLock.unshieldRequestHandle));
        assertEq(claim.to, address(vault));
        assertEq(claim.ctHash, euint64.unwrap(intentLock.unshieldRequestHandle));
        assertEq(claim.requestedAmount, 0);
        assertFalse(claim.claimed);
    }

    function testLockForSwapIntentRejectsUnauthorizedCaller() public {
        address wrapper = _createDefaultWrapper();

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.UnauthorizedIntentController.selector, user
            )
        );
        vault.lockForSwapIntent(keccak256("intent"), user, wrapper, euint64.wrap(bytes32("a")));
    }

    function testLockForSwapIntentRejectsZeroIntentId() public {
        (VaultIntentControllerHarness controller, address wrapper) = _prepareLockController();
        InEuint64 memory encryptedLockAmount = createInEuint64(40e6, user);

        vm.prank(user);
        vm.expectRevert(AlphaEngineConfidentialVault.ZeroIntentId.selector);
        controller.lockWithInput(bytes32(0), user, wrapper, encryptedLockAmount);
    }

    function testLockForSwapIntentRejectsZeroAccount() public {
        (VaultIntentControllerHarness controller, address wrapper) = _prepareLockController();
        InEuint64 memory encryptedLockAmount = createInEuint64(40e6, user);

        vm.prank(user);
        vm.expectRevert(AlphaEngineConfidentialVault.ZeroAccount.selector);
        controller.lockWithInput(keccak256("intent"), address(0), wrapper, encryptedLockAmount);
    }

    function testLockForSwapIntentRejectsUninitializedAmount() public {
        VaultIntentControllerHarness controller = _installControllerHarness();
        address wrapper = _createDefaultWrapper();

        vm.expectRevert(AlphaEngineConfidentialVault.UninitializedEncryptedAmount.selector);
        controller.lockWithHandle(keccak256("intent"), user, wrapper, euint64.wrap(bytes32(0)));
    }

    function testLockForSwapIntentRejectsUnregisteredWrapper() public {
        VaultIntentControllerHarness controller = _installControllerHarness();

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.WrapperNotRegistered.selector, address(0xF00D)
            )
        );
        controller.lockWithHandle(
            keccak256("intent"), user, address(0xF00D), euint64.wrap(bytes32("a"))
        );
    }

    function testLockForSwapIntentRejectsDuplicateIntentId() public {
        (VaultIntentControllerHarness controller, address wrapper) = _prepareLockController();
        bytes32 intentId = keccak256("intent-a");
        InEuint64 memory firstLockAmount = createInEuint64(40e6, user);
        InEuint64 memory secondLockAmount = createInEuint64(20e6, user);

        vm.prank(user);
        controller.lockWithInput(intentId, user, wrapper, firstLockAmount);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.SwapIntentLockAlreadyExists.selector, intentId
            )
        );
        controller.lockWithInput(intentId, user, wrapper, secondLockAmount);
    }

    function testLockForSwapIntentRejectsUninitializedReturnedLockHandle() public {
        ZeroTransferWrapperSurface wrapper = new ZeroTransferWrapperSurface(address(underlying));
        VaultIntentControllerHarness controller = _installControllerHarness();

        vm.prank(owner);
        vault.registerWrapper(address(underlying), address(wrapper));

        vm.expectRevert(AlphaEngineConfidentialVault.UninitializedEncryptedAmount.selector);
        controller.lockWithHandle(
            keccak256("intent"), user, address(wrapper), euint64.wrap(bytes32("a"))
        );
    }

    function testIntentControllerCanConsumeSwapIntentLock() public {
        (
            VaultIntentControllerHarness controller,
            address wrapper,
            bytes32 intentId,
            euint64 lockedAmount
        ) = _createLockedSwapIntent();

        vm.expectEmit(true, true, true, false, address(vault));
        emit SwapIntentLockConsumed(intentId, user, wrapper, euint64.wrap(bytes32(0)));

        euint64 consumedAmount = controller.consume(intentId);

        AlphaEngineConfidentialVault.SwapIntentLock memory intentLock =
            vault.getSwapIntentLock(intentId);
        assertEq(
            uint8(intentLock.status),
            uint8(AlphaEngineConfidentialVault.SwapIntentLockStatus.Consumed)
        );
        assertEq(euint64.unwrap(consumedAmount), euint64.unwrap(lockedAmount));
        assertEq(mockStorage(uint256(euint64.unwrap(consumedAmount))), 40e6);
    }

    function testConsumeSwapIntentLockRejectsUnauthorizedCaller() public {
        bytes32 intentId = keccak256("intent-a");

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.UnauthorizedIntentController.selector, user
            )
        );
        vault.consumeSwapIntentLock(intentId);
    }

    function testConsumeSwapIntentLockRejectsUnknownIntentId() public {
        VaultIntentControllerHarness controller = _installControllerHarness();
        bytes32 intentId = keccak256("missing-intent");

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.SwapIntentLockNotFound.selector, intentId
            )
        );
        controller.consume(intentId);
    }

    function testConsumeSwapIntentLockRejectsInactiveLock() public {
        (VaultIntentControllerHarness controller,, bytes32 intentId,) = _createLockedSwapIntent();
        controller.consume(intentId);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialVault.SwapIntentLockNotActive.selector,
                intentId,
                AlphaEngineConfidentialVault.SwapIntentLockStatus.Consumed
            )
        );
        controller.consume(intentId);
    }

    function testConsumeSwapIntentLockRejectsWhenPaused() public {
        (VaultIntentControllerHarness controller,, bytes32 intentId,) = _createLockedSwapIntent();

        vm.prank(owner);
        vault.pause();

        vm.expectRevert();
        controller.consume(intentId);
    }

    function testPauseAndUnpause() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit Paused(owner);

        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());

        vm.expectEmit(true, true, true, true, address(vault));
        emit Unpaused(owner);

        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function testWrapperRejectsZeroUnderlying() public {
        vm.expectRevert(AlphaEngineFHERC20ERC20Wrapper.ZeroUnderlying.selector);
        new AlphaEngineFHERC20ERC20Wrapper(IERC20(address(0)), "Encrypted Zero", "eZERO", "");
    }

    function testWrapperRejectsNonContractUnderlying() public {
        address invalidUnderlying = address(0xE0A);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFHERC20ERC20Wrapper.InvalidUnderlying.selector, invalidUnderlying
            )
        );
        new AlphaEngineFHERC20ERC20Wrapper(
            IERC20(invalidUnderlying), "Encrypted Invalid", "eINVALID", ""
        );
    }

    function _createDefaultWrapper() private returns (address wrapper) {
        vm.prank(owner);
        wrapper = vault.createWrapper(address(underlying), "Encrypted USDC", "eUSDC", "");
    }

    function _installControllerHarness()
        private
        returns (VaultIntentControllerHarness controller)
    {
        controller = new VaultIntentControllerHarness(vault);
        vm.prank(owner);
        vault.setIntentController(address(controller));
    }

    function _prepareLockController()
        private
        returns (VaultIntentControllerHarness controller, address wrapper)
    {
        wrapper = _createDefaultWrapper();
        controller = _installControllerHarness();

        uint256 depositAmount = 100e6;
        underlying.mint(user, depositAmount);

        vm.startPrank(user);
        underlying.approve(address(vault), depositAmount);
        vault.depositAndShield(address(underlying), depositAmount, user);
        AlphaEngineFHERC20ERC20Wrapper(wrapper).setOperator(
            address(vault), uint48(block.timestamp + 1 hours)
        );
        vm.stopPrank();
    }

    function _createLockedSwapIntent()
        private
        returns (
            VaultIntentControllerHarness controller,
            address wrapper,
            bytes32 intentId,
            euint64 lockedAmount
        )
    {
        (controller, wrapper) = _prepareLockController();
        intentId = keccak256("intent-a");
        InEuint64 memory encryptedLockAmount = createInEuint64(40e6, user);

        vm.prank(user);
        lockedAmount = controller.lockWithInput(intentId, user, wrapper, encryptedLockAmount);
    }

    function _assertWrapperRegisteredLog(
        Vm.Log[] memory logs,
        address expectedUnderlying,
        address expectedWrapper
    ) private pure {
        bytes32 eventTopic = keccak256("ConfidentialWrapperRegistered(address,address)");

        bool found;
        for (uint256 index = 0; index < logs.length; ++index) {
            Vm.Log memory logEntry = logs[index];
            if (logEntry.topics.length == 3 && logEntry.topics[0] == eventTopic) {
                assertEq(address(uint160(uint256(logEntry.topics[1]))), expectedUnderlying);
                assertEq(address(uint160(uint256(logEntry.topics[2]))), expectedWrapper);
                found = true;
                break;
            }
        }

        assertTrue(found, "ConfidentialWrapperRegistered log not found");
    }
}

contract VaultIntentControllerHarness {
    AlphaEngineConfidentialVault private immutable _vault;

    constructor(AlphaEngineConfidentialVault vault_) {
        _vault = vault_;
    }

    function lockWithInput(
        bytes32 intentId,
        address account,
        address wrapper,
        InEuint64 calldata encryptedAmount
    ) external returns (euint64) {
        euint64 amount = FHE.asEuint64(encryptedAmount);
        FHE.allow(amount, address(_vault));
        return _vault.lockForSwapIntent(intentId, account, wrapper, amount);
    }

    function lockWithHandle(bytes32 intentId, address account, address wrapper, euint64 amount)
        external
        returns (euint64)
    {
        return _vault.lockForSwapIntent(intentId, account, wrapper, amount);
    }

    function consume(bytes32 intentId) external returns (euint64) {
        return _vault.consumeSwapIntentLock(intentId);
    }
}

contract ZeroTransferWrapperSurface {
    address private immutable _underlying;

    constructor(address underlying_) {
        _underlying = underlying_;
    }

    function underlying() external view returns (address) {
        return _underlying;
    }

    function rate() external pure returns (uint256) {
        return 1;
    }

    function confidentialTransferFrom(address, address, euint64) external pure returns (euint64) {
        return euint64.wrap(bytes32(0));
    }
}

contract ZeroRefundWrapperSurface {
    address private immutable _underlying;

    constructor(address underlying_) {
        _underlying = underlying_;
    }

    function underlying() external view returns (address) {
        return _underlying;
    }

    function rate() external pure returns (uint256) {
        return 1;
    }

    function confidentialTransferFrom(address, address, euint64 amount)
        external
        pure
        returns (euint64)
    {
        return amount;
    }

    function confidentialTransfer(address, euint64) external pure returns (euint64) {
        return euint64.wrap(bytes32(0));
    }
}

contract NonMetadataERC20 {
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 allowanceAmount)) public allowance;

    uint256 public totalSupply;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract NoWrapperSurface {}

contract MalformedWrapperSurface {
    function underlying() external pure returns (address, address) {
        return (address(0x01), address(0x02));
    }
}

contract NoRateWrapperSurface {
    address private immutable _underlying;

    constructor(address underlying_) {
        _underlying = underlying_;
    }

    function underlying() external view returns (address) {
        return _underlying;
    }
}

contract ZeroRateWrapperSurface {
    address private immutable _underlying;

    constructor(address underlying_) {
        _underlying = underlying_;
    }

    function underlying() external view returns (address) {
        return _underlying;
    }

    function rate() external pure returns (uint256) {
        return 0;
    }
}
