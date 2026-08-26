// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {FHE, InEuint64, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IERC7984} from "fhenix-confidential-contracts/interfaces/IERC7984.sol";
import {IFHERC20ERC20Wrapper} from
    "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {FHERC20ZeroBalance} from "fhenix-confidential-contracts/FHERC20/utils/FHERC20Errors.sol";
import {AlphaEngineConfidentialAssetRegistry} from
    "src/fherc20/AlphaEngineConfidentialAssetRegistry.sol";
import {AlphaEngineConfidentialAssetGateway} from
    "src/fherc20/AlphaEngineConfidentialAssetGateway.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {IAlphaEngineConfidentialAssetRegistry} from
    "src/interfaces/IAlphaEngineConfidentialAssetRegistry.sol";
import {IAlphaEngineConfidentialSwapEscrow} from
    "src/interfaces/IAlphaEngineConfidentialSwapEscrow.sol";
import {IAlphaEngineSwapExecutor} from "src/interfaces/IAlphaEngineSwapExecutor.sol";
import {AlphaEngineConfidentialSwapEscrow} from "src/swap/AlphaEngineConfidentialSwapEscrow.sol";
import {MockCoFheTest} from "test/mocks/MockCoFheTest.sol";
import {MockERC20, MockSelectiveFeeERC20} from "test/mocks/MockERC20.sol";
import {MockMintingSwapExecutor} from "test/mocks/MockMintingSwapExecutor.sol";

contract AlphaEngineConfidentialAssetRegistryTest is MockCoFheTest {
    AlphaEngineConfidentialAssetRegistry private registry;
    MockERC20 private underlying;

    address private owner = makeAddr("registry-owner");
    address private outsider = makeAddr("registry-outsider");

    function setUp() public {
        _installMockTaskManager();
        registry = new AlphaEngineConfidentialAssetRegistry(owner);
        underlying = new MockERC20("USD Coin", "USDC", 6);
    }

    function test_constructorSetsOwnerAndRejectsZeroOwner() public {
        assertEq(registry.owner(), owner);

        vm.expectRevert(AlphaEngineConfidentialAssetRegistry.ZeroInitialOwner.selector);
        new AlphaEngineConfidentialAssetRegistry(address(0));
    }

    function test_createWrapperStoresImmutableBijectionAndMetadata() public {
        address expectedWrapper = vm.computeCreateAddress(address(registry), 1);
        vm.expectEmit(true, true, true, true, address(registry));
        emit AlphaEngineConfidentialAssetRegistry.ConfidentialWrapperRegistered(
            address(underlying), expectedWrapper
        );

        vm.prank(owner);
        address wrapper =
            registry.createWrapper(address(underlying), "Encrypted USDC", "eUSDC", "uri");

        assertEq(registry.wrapperForUnderlying(address(underlying)), wrapper);
        assertEq(registry.underlyingForWrapper(wrapper), address(underlying));
        assertTrue(registry.isUnderlyingRegistered(address(underlying)));
        assertTrue(registry.isWrapperRegistered(wrapper));
        assertEq(IFHERC20ERC20Wrapper(wrapper).underlying(), address(underlying));
        assertEq(AlphaEngineFHERC20ERC20Wrapper(wrapper).name(), "Encrypted USDC");
        assertEq(AlphaEngineFHERC20ERC20Wrapper(wrapper).symbol(), "eUSDC");
    }

    function test_createWrapperCapsPrecisionAndRejectsInvalidOrDuplicateUnderlying() public {
        MockERC20 highPrecision = new MockERC20("High", "HIGH", 18);
        vm.prank(owner);
        address wrapper = registry.createWrapper(address(highPrecision), "Encrypted", "eHIGH", "");
        assertEq(AlphaEngineFHERC20ERC20Wrapper(wrapper).decimals(), 6);
        assertEq(IFHERC20ERC20Wrapper(wrapper).rate(), 1e12);

        vm.prank(owner);
        vm.expectRevert(AlphaEngineConfidentialAssetRegistry.ZeroUnderlying.selector);
        registry.createWrapper(address(0), "Zero", "ZERO", "");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.InvalidUnderlying.selector, outsider
            )
        );
        registry.createWrapper(outsider, "Invalid", "INVALID", "");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.WrapperAlreadyRegistered.selector,
                address(highPrecision),
                wrapper
            )
        );
        registry.createWrapper(address(highPrecision), "Duplicate", "DUP", "");
    }

    function test_onlyOwnerCanCreateOrRegister() public {
        vm.prank(outsider);
        vm.expectRevert();
        registry.createWrapper(address(underlying), "Encrypted", "eUSDC", "");

        vm.prank(outsider);
        vm.expectRevert();
        registry.registerWrapper(address(underlying), outsider);
    }

    function test_registerExistingWrapperValidatesBijectionSurfaceAndRate() public {
        AlphaEngineFHERC20ERC20Wrapper wrapper =
            new AlphaEngineFHERC20ERC20Wrapper(underlying, "Encrypted USDC", "eUSDC", "");

        vm.prank(owner);
        registry.registerWrapper(address(underlying), address(wrapper));
        assertEq(registry.wrapperForUnderlying(address(underlying)), address(wrapper));
        assertEq(registry.underlyingForWrapper(address(wrapper)), address(underlying));

        MockERC20 otherUnderlying = new MockERC20("Other", "OTHER", 6);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.WrapperAlreadyRegistered.selector,
                address(underlying),
                address(wrapper)
            )
        );
        registry.registerWrapper(address(otherUnderlying), address(wrapper));

        Stage7WrapperSurface mismatched = new Stage7WrapperSurface(address(underlying), 1);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.WrapperUnderlyingMismatch.selector,
                address(mismatched),
                address(otherUnderlying),
                address(underlying)
            )
        );
        registry.registerWrapper(address(otherUnderlying), address(mismatched));
    }

    function test_registerRejectsZeroInvalidAndZeroRateWrappers() public {
        vm.prank(owner);
        vm.expectRevert(AlphaEngineConfidentialAssetRegistry.ZeroWrapper.selector);
        registry.registerWrapper(address(underlying), address(0));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.InvalidWrapper.selector, outsider
            )
        );
        registry.registerWrapper(address(underlying), outsider);

        Stage7WrapperSurface zeroRate = new Stage7WrapperSurface(address(underlying), 0);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetRegistry.InvalidWrapper.selector, address(zeroRate)
            )
        );
        registry.registerWrapper(address(underlying), address(zeroRate));
    }
}

contract AlphaEngineConfidentialAssetGatewayTest is MockCoFheTest {
    AlphaEngineConfidentialAssetRegistry private registry;
    AlphaEngineConfidentialAssetGateway private gateway;
    MockERC20 private underlying;
    address private wrapper;

    address private owner = makeAddr("gateway-registry-owner");
    address private user = makeAddr("gateway-user");
    address private recipient = makeAddr("gateway-recipient");

    function setUp() public {
        _installMockTaskManager();
        registry = new AlphaEngineConfidentialAssetRegistry(owner);
        underlying = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(owner);
        wrapper = registry.createWrapper(address(underlying), "Encrypted USDC", "eUSDC", "");
        gateway = new AlphaEngineConfidentialAssetGateway(registry);
    }

    function test_constructorPinsRegistryAndRejectsInvalidRegistry() public {
        assertEq(gateway.assetRegistry(), address(registry));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetGateway.InvalidAssetRegistry.selector, address(0)
            )
        );
        new AlphaEngineConfidentialAssetGateway(IAlphaEngineConfidentialAssetRegistry(address(0)));

        Stage7NoRegistrySurface invalidRegistry = new Stage7NoRegistrySurface();
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetGateway.InvalidAssetRegistry.selector,
                address(invalidRegistry)
            )
        );
        new AlphaEngineConfidentialAssetGateway(
            IAlphaEngineConfidentialAssetRegistry(address(invalidRegistry))
        );
    }

    function test_depositAndShieldUsesRegistryAndRetainsNoUnderlying() public {
        uint256 amount = 100e6;
        underlying.mint(user, amount);

        vm.startPrank(user);
        underlying.approve(address(gateway), amount);
        (address returnedWrapper, euint64 shieldedAmount) =
            gateway.depositAndShield(address(underlying), amount, recipient);
        vm.stopPrank();

        assertEq(returnedWrapper, wrapper);
        assertEq(underlying.balanceOf(address(gateway)), 0);
        assertEq(underlying.balanceOf(wrapper), amount);
        assertEq(_evalue(shieldedAmount), amount);
        assertEq(_evalue(IERC7984(wrapper).confidentialBalanceOf(recipient)), amount);
        assertEq(underlying.allowance(address(gateway), wrapper), 0);
    }

    function test_depositRejectsInvalidInputsAndUnregisteredUnderlying() public {
        MockERC20 unregistered = new MockERC20("Nope", "NOPE", 6);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetGateway.UnderlyingNotRegistered.selector,
                address(unregistered)
            )
        );
        gateway.depositAndShield(address(unregistered), 1, recipient);

        vm.prank(user);
        vm.expectRevert(AlphaEngineConfidentialAssetGateway.ZeroRecipient.selector);
        gateway.depositAndShield(address(underlying), 1, address(0));

        vm.prank(user);
        vm.expectRevert(AlphaEngineConfidentialAssetGateway.ZeroAmount.selector);
        gateway.depositAndShield(address(underlying), 0, recipient);
    }

    function test_depositRejectsNonIntegralAndOverPrecisionAmounts() public {
        MockERC20 highPrecision = new MockERC20("High", "HIGH", 18);
        vm.prank(owner);
        registry.createWrapper(address(highPrecision), "Encrypted", "eHIGH", "");

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetGateway.AmountNotMultipleOfRate.selector, 1, 1e12
            )
        );
        gateway.depositAndShield(address(highPrecision), 1, recipient);

        uint256 tooLarge = (uint256(type(uint64).max) + 1) * 1e12;
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetGateway.AmountExceedsFHERC20Precision.selector,
                tooLarge,
                1e12
            )
        );
        gateway.depositAndShield(address(highPrecision), tooLarge, recipient);
    }

    function test_depositRejectsFeeOnTransferAtEitherBoundary() public {
        MockSelectiveFeeERC20 feeToken = new MockSelectiveFeeERC20("Fee", "FEE", 6);
        vm.prank(owner);
        address feeWrapper = registry.createWrapper(address(feeToken), "Encrypted FEE", "eFEE", "");
        uint256 amount = 100e6;
        feeToken.mint(user, amount * 2);
        vm.prank(user);
        feeToken.approve(address(gateway), amount * 2);

        feeToken.setFeeRoute(user, address(gateway));
        vm.prank(user);
        vm.expectRevert();
        gateway.depositAndShield(address(feeToken), amount, user);

        feeToken.setFeeRoute(user, address(0));
        feeToken.setFeeRoute(address(gateway), feeWrapper);
        vm.prank(user);
        vm.expectRevert();
        gateway.depositAndShield(address(feeToken), amount, user);

        assertEq(feeToken.balanceOf(address(gateway)), 0);
        assertEq(feeToken.allowance(address(gateway), feeWrapper), 0);
    }

    function test_requestAndClaimUnshieldUsesRegisteredWrapper() public {
        uint256 depositAmount = 100e6;
        uint64 unshieldAmount = 40e6;
        underlying.mint(user, depositAmount);

        vm.startPrank(user);
        underlying.approve(address(gateway), depositAmount);
        gateway.depositAndShield(address(underlying), depositAmount, user);
        AlphaEngineFHERC20ERC20Wrapper(wrapper).setOperator(
            address(gateway), uint48(block.timestamp + 1 hours)
        );
        euint64 requestHandle = gateway.requestUnshield(wrapper, user, unshieldAmount);
        vm.stopPrank();

        bytes32 requestId = euint64.unwrap(requestHandle);
        taskManager.publishDecryptResult(uint256(requestId), unshieldAmount, "");
        gateway.claimUnshielded(wrapper, requestId, unshieldAmount, "");

        assertEq(underlying.balanceOf(user), unshieldAmount);
        assertEq(underlying.balanceOf(address(gateway)), 0);
        assertTrue(AlphaEngineFHERC20ERC20Wrapper(wrapper).getClaim(requestId).claimed);
    }

    function test_unshieldRejectsUnregisteredWrapperZeroRecipientAndZeroAmount() public {
        address unknown = makeAddr("unknown-wrapper");
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialAssetGateway.WrapperNotRegistered.selector, unknown
            )
        );
        gateway.requestUnshield(unknown, user, 1);

        vm.prank(user);
        vm.expectRevert(AlphaEngineConfidentialAssetGateway.ZeroRecipient.selector);
        gateway.requestUnshield(wrapper, address(0), 1);

        vm.prank(user);
        vm.expectRevert(AlphaEngineConfidentialAssetGateway.ZeroAmount.selector);
        gateway.requestUnshield(wrapper, user, 0);
    }

    function _evalue(euint64 encryptedValue) private view returns (uint256) {
        return mockStorage(uint256(euint64.unwrap(encryptedValue)));
    }
}

contract AlphaEngineConfidentialSwapEscrowTest is MockCoFheTest {
    AlphaEngineConfidentialAssetRegistry private registry;
    AlphaEngineConfidentialAssetGateway private gateway;
    AlphaEngineConfidentialSwapEscrow private implementation;
    AlphaEngineConfidentialSwapEscrow private escrow;
    Stage7SwapControllerHarness private controller;
    MockERC20 private inputUnderlying;
    MockERC20 private outputUnderlying;
    address private inputWrapper;
    address private outputWrapper;

    address private admin = makeAddr("escrow-admin");
    address private pauser = makeAddr("escrow-pauser");
    address private proxyAdminOwner = makeAddr("escrow-proxy-admin");
    address private user = makeAddr("escrow-user");

    function setUp() public {
        _installMockTaskManager();
        registry = new AlphaEngineConfidentialAssetRegistry(admin);
        gateway = new AlphaEngineConfidentialAssetGateway(registry);
        inputUnderlying = new MockERC20("USD Coin", "USDC", 6);
        outputUnderlying = new MockERC20("Tether", "USDT", 6);

        vm.startPrank(admin);
        inputWrapper =
            registry.createWrapper(address(inputUnderlying), "Encrypted USDC", "eUSDC", "");
        outputWrapper =
            registry.createWrapper(address(outputUnderlying), "Encrypted USDT", "eUSDT", "");
        vm.stopPrank();

        controller = new Stage7SwapControllerHarness();
        implementation = new AlphaEngineConfidentialSwapEscrow();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapEscrow.initialize,
                (admin, pauser, address(controller), address(registry))
            )
        );
        escrow = AlphaEngineConfidentialSwapEscrow(address(proxy));
        controller.setEscrow(escrow);

        vm.prank(admin);
        escrow.unpause();
    }

    function test_constructorDisablesInitializerAndProxyStartsWithSeparatedRoles() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(admin, pauser, address(controller), address(registry));

        assertEq(escrow.swapController(), address(controller));
        assertEq(escrow.assetRegistry(), address(registry));
        assertTrue(escrow.hasRole(escrow.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(escrow.hasRole(escrow.PAUSER_ROLE(), pauser));
        assertFalse(escrow.paused());
    }

    function test_initializeRejectsInvalidAddressesAndSurfaces() public {
        AlphaEngineConfidentialSwapEscrow fresh = new AlphaEngineConfidentialSwapEscrow();
        vm.expectRevert(AlphaEngineConfidentialSwapEscrow.ZeroInitialDefaultAdmin.selector);
        new TransparentUpgradeableProxy(
            address(fresh),
            proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapEscrow.initialize,
                (address(0), pauser, address(controller), address(registry))
            )
        );

        AlphaEngineConfidentialSwapEscrow freshTwo = new AlphaEngineConfidentialSwapEscrow();
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapEscrow.InvalidSwapController.selector, user
            )
        );
        new TransparentUpgradeableProxy(
            address(freshTwo),
            proxyAdminOwner,
            abi.encodeCall(
                AlphaEngineConfidentialSwapEscrow.initialize,
                (admin, pauser, user, address(registry))
            )
        );
    }

    function test_pauseDomainsAndConfigurationRotationRequireGovernanceAndNoLocks() public {
        vm.prank(pauser);
        escrow.pause();
        assertTrue(escrow.paused());

        Stage7SwapControllerHarness replacement = new Stage7SwapControllerHarness();
        vm.prank(admin);
        escrow.setSwapController(address(replacement));
        assertEq(escrow.swapController(), address(replacement));

        AlphaEngineConfidentialAssetRegistry replacementRegistry =
            new AlphaEngineConfidentialAssetRegistry(admin);
        vm.prank(admin);
        escrow.setAssetRegistry(address(replacementRegistry));
        assertEq(escrow.assetRegistry(), address(replacementRegistry));

        vm.prank(pauser);
        vm.expectRevert();
        escrow.unpause();
    }

    function test_configRotationRejectsActiveLock() public {
        _lock(keccak256("active"), 40e6);
        vm.prank(pauser);
        escrow.pause();
        Stage7SwapControllerHarness replacement = new Stage7SwapControllerHarness();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapEscrow.ActiveSwapLocksPresent.selector, 1
            )
        );
        escrow.setSwapController(address(replacement));
    }

    function test_lockStoresCanonicalReturnedHandleAndImmediateUnshieldRequest() public {
        bytes32 intentId = keccak256("canonical-lock");
        euint64 lockedAmount = _lock(intentId, 40e6);
        IAlphaEngineConfidentialSwapEscrow.SwapIntentLock memory intentLock =
            escrow.getSwapIntentLock(intentId);

        assertTrue(escrow.existsSwapIntentLock(intentId));
        assertEq(escrow.liveSwapLockCount(), 1);
        assertEq(intentLock.account, user);
        assertEq(intentLock.wrapper, inputWrapper);
        assertEq(euint64.unwrap(intentLock.lockedAmount), euint64.unwrap(lockedAmount));
        assertEq(_evalue(intentLock.lockedAmount), 40e6);
        assertEq(_evalue(intentLock.unshieldRequestHandle), 40e6);
        assertEq(
            uint8(intentLock.status),
            uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.UnshieldRequested)
        );
    }

    function test_lockAboveBalanceCreatesZeroLockThatRefundCanClear() public {
        _fundAndShield(40e6);
        bytes32 intentId = keccak256("overdraw-zero-lock");
        InEuint64 memory input = createInEuint64(40e6 + 1, user);

        vm.prank(user);
        euint64 lockedAmount = controller.lockWithInput(intentId, user, inputWrapper, input);
        IAlphaEngineConfidentialSwapEscrow.SwapIntentLock memory intentLock =
            escrow.getSwapIntentLock(intentId);

        assertEq(_evalue(lockedAmount), 0);
        assertEq(_evalue(intentLock.unshieldRequestHandle), 0);
        assertEq(_confidentialBalance(inputWrapper, user), 40e6);
        assertEq(escrow.liveSwapLockCount(), 1);

        bytes32 requestId = euint64.unwrap(intentLock.unshieldRequestHandle);
        taskManager.publishDecryptResult(uint256(requestId), 0, "");

        vm.expectEmit(true, true, true, true, address(escrow));
        emit AlphaEngineConfidentialSwapEscrow.SwapIntentLockRefunded(
            intentId, user, inputWrapper, 0, euint64.wrap(bytes32(0))
        );
        bytes32 refundedHandle = controller.refund(intentId, 0, "");

        assertEq(refundedHandle, bytes32(0));
        assertEq(_confidentialBalance(inputWrapper, user), 40e6);
        assertEq(escrow.liveSwapLockCount(), 0);
        assertTrue(AlphaEngineFHERC20ERC20Wrapper(inputWrapper).getClaim(requestId).claimed);
        assertEq(
            uint8(escrow.getSwapIntentLock(intentId).status),
            uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Refunded)
        );
    }

    function test_lockFromUninitializedAccountRetainsDependencyTypedFailure() public {
        address uninitializedAccount = makeAddr("uninitialized-confidential-account");
        vm.prank(uninitializedAccount);
        AlphaEngineFHERC20ERC20Wrapper(inputWrapper).setOperator(
            address(escrow), uint48(block.timestamp + 1 days)
        );
        InEuint64 memory input = createInEuint64(1, uninitializedAccount);

        vm.prank(uninitializedAccount);
        vm.expectRevert(abi.encodeWithSelector(FHERC20ZeroBalance.selector, uninitializedAccount));
        controller.lockWithInput(
            keccak256("uninitialized-account"), uninitializedAccount, inputWrapper, input
        );

        assertEq(escrow.liveSwapLockCount(), 0);
    }

    function test_lockRejectsUnauthorizedInvalidDuplicateAndUnknownWrapper() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapEscrow.UnauthorizedSwapController.selector, user
            )
        );
        escrow.lockForSwapIntent(
            keccak256("unauthorized"), user, inputWrapper, euint64.wrap(bytes32(uint256(1)))
        );

        _fundAndShield(100e6);
        InEuint64 memory input = createInEuint64(40e6, user);
        vm.prank(user);
        vm.expectRevert(AlphaEngineConfidentialSwapEscrow.ZeroIntentId.selector);
        controller.lockWithInput(bytes32(0), user, inputWrapper, input);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapEscrow.WrapperNotRegistered.selector,
                makeAddr("unknown-wrapper")
            )
        );
        controller.lockWithInput(keccak256("unknown"), user, makeAddr("unknown-wrapper"), input);

        bytes32 duplicateId = keccak256("duplicate");
        vm.prank(user);
        controller.lockWithInput(duplicateId, user, inputWrapper, input);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapEscrow.SwapIntentLockAlreadyExists.selector, duplicateId
            )
        );
        controller.lockWithInput(duplicateId, user, inputWrapper, input);
    }

    function test_unknownGetterFailsTypedAndExistsReturnsFalse() public {
        bytes32 missing = keccak256("missing");
        assertFalse(escrow.existsSwapIntentLock(missing));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapEscrow.SwapIntentLockNotFound.selector, missing
            )
        );
        escrow.getSwapIntentLock(missing);
    }

    function test_settleConsumesOnceShieldsExactOutputAndLeavesNoResidualBalances() public {
        bytes32 intentId = keccak256("settle");
        _lock(intentId, 40e6);
        bytes32 requestId = euint64.unwrap(escrow.getSwapIntentLock(intentId).unshieldRequestHandle);
        taskManager.publishDecryptResult(uint256(requestId), 40e6, "");
        MockMintingSwapExecutor executor = new MockMintingSwapExecutor();

        (uint256 outputAmount, bytes32 shieldedOutputHandle) = controller.settle(
            intentId, address(executor), outputWrapper, 40e6, 39e6, "", abi.encode(39e6)
        );

        assertEq(outputAmount, 39e6);
        assertEq(_evalue(euint64.wrap(shieldedOutputHandle)), 39e6);
        assertEq(_confidentialBalance(outputWrapper, user), 39e6);
        assertEq(escrow.liveSwapLockCount(), 0);
        assertEq(inputUnderlying.balanceOf(address(escrow)), 0);
        assertEq(outputUnderlying.balanceOf(address(escrow)), 0);
        assertEq(inputUnderlying.balanceOf(address(executor)), 0);
        assertEq(outputUnderlying.balanceOf(address(executor)), 0);
        assertEq(inputUnderlying.allowance(address(escrow), inputWrapper), 0);
        assertEq(outputUnderlying.allowance(address(escrow), outputWrapper), 0);
    }

    function test_settleReconcilesPermissionlessPreclaimWithoutStrandingInput() public {
        bytes32 intentId = keccak256("preclaimed-settle");
        _lock(intentId, 40e6);
        bytes32 requestId = euint64.unwrap(escrow.getSwapIntentLock(intentId).unshieldRequestHandle);
        taskManager.publishDecryptResult(uint256(requestId), 40e6, "");

        vm.prank(makeAddr("permissionless-preclaimer"));
        AlphaEngineFHERC20ERC20Wrapper(inputWrapper).claimUnshielded(requestId, 40e6, "");
        assertEq(inputUnderlying.balanceOf(address(escrow)), 40e6);

        MockMintingSwapExecutor executor = new MockMintingSwapExecutor();
        (uint256 outputAmount,) = controller.settle(
            intentId, address(executor), outputWrapper, 40e6, 39e6, "", abi.encode(39e6)
        );

        assertEq(outputAmount, 39e6);
        assertEq(_confidentialBalance(outputWrapper, user), 39e6);
        assertEq(inputUnderlying.balanceOf(address(escrow)), 0);
        assertEq(escrow.liveSwapLockCount(), 0);
        assertEq(
            uint8(escrow.getSwapIntentLock(intentId).status),
            uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Consumed)
        );
    }

    function test_refundReconcilesPermissionlessPreclaimWithoutDoubleClaiming() public {
        bytes32 intentId = keccak256("preclaimed-refund");
        _lock(intentId, 40e6);
        bytes32 requestId = euint64.unwrap(escrow.getSwapIntentLock(intentId).unshieldRequestHandle);
        taskManager.publishDecryptResult(uint256(requestId), 40e6, "");

        vm.prank(makeAddr("permissionless-preclaimer"));
        AlphaEngineFHERC20ERC20Wrapper(inputWrapper).claimUnshielded(requestId, 40e6, "");
        assertEq(inputUnderlying.balanceOf(address(escrow)), 40e6);

        bytes32 refundedHandle = controller.refund(intentId, 40e6, "");

        assertEq(_evalue(euint64.wrap(refundedHandle)), 40e6);
        assertEq(_confidentialBalance(inputWrapper, user), 100e6);
        assertEq(inputUnderlying.balanceOf(address(escrow)), 0);
        assertEq(escrow.liveSwapLockCount(), 0);
        assertEq(
            uint8(escrow.getSwapIntentLock(intentId).status),
            uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Refunded)
        );
    }

    function test_settleEnforcesMinimumEvenWhenExecutorIgnoresIt() public {
        bytes32 intentId = keccak256("independent-minimum");
        _lock(intentId, 40e6);
        bytes32 requestId = euint64.unwrap(escrow.getSwapIntentLock(intentId).unshieldRequestHandle);
        taskManager.publishDecryptResult(uint256(requestId), 40e6, "");
        Stage7IgnoringMinimumExecutor executor = new Stage7IgnoringMinimumExecutor();

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapEscrow.OutputAmountBelowMinimum.selector,
                uint256(40e6),
                uint256(39e6)
            )
        );
        controller.settle(
            intentId, address(executor), outputWrapper, 40e6, 40e6, "", abi.encode(39e6)
        );

        assertEq(escrow.liveSwapLockCount(), 1);
        assertEq(
            uint8(escrow.getSwapIntentLock(intentId).status),
            uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.UnshieldRequested)
        );
    }

    function test_settleRejectsFeeOnTransferOutputBeforeUndercollateralizedMint() public {
        MockSelectiveFeeERC20 feeOutput = new MockSelectiveFeeERC20("Fee Output", "FOUT", 6);
        vm.prank(admin);
        address feeWrapper =
            registry.createWrapper(address(feeOutput), "Encrypted FOUT", "eFOUT", "");
        feeOutput.setFeeRoute(address(escrow), feeWrapper);

        bytes32 intentId = keccak256("fee-output");
        _lock(intentId, 40e6);
        bytes32 requestId = euint64.unwrap(escrow.getSwapIntentLock(intentId).unshieldRequestHandle);
        taskManager.publishDecryptResult(uint256(requestId), 40e6, "");
        MockMintingSwapExecutor executor = new MockMintingSwapExecutor();

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineConfidentialSwapEscrow.UnexpectedUnderlyingBalance.selector,
                feeWrapper,
                address(feeOutput),
                uint256(39e6),
                uint256(39e6 - 1)
            )
        );
        controller.settle(intentId, address(executor), feeWrapper, 40e6, 1, "", abi.encode(39e6));

        assertEq(escrow.liveSwapLockCount(), 1);
        assertFalse(AlphaEngineFHERC20ERC20Wrapper(inputWrapper).getClaim(requestId).claimed);
        assertEq(_confidentialBalance(feeWrapper, user), 0);
        assertEq(feeOutput.balanceOf(feeWrapper), 0);
    }

    function test_refundRemainsAvailableWhilePausedAndRestoresExactConfidentialAmount() public {
        bytes32 intentId = keccak256("refund");
        _lock(intentId, 40e6);
        bytes32 requestId = euint64.unwrap(escrow.getSwapIntentLock(intentId).unshieldRequestHandle);
        taskManager.publishDecryptResult(uint256(requestId), 40e6, "");

        vm.prank(pauser);
        escrow.pause();
        bytes32 refundedHandle = controller.refund(intentId, 40e6, "");

        assertEq(_evalue(euint64.wrap(refundedHandle)), 40e6);
        assertEq(_confidentialBalance(inputWrapper, user), 100e6);
        assertEq(escrow.liveSwapLockCount(), 0);
        assertEq(inputUnderlying.balanceOf(address(escrow)), 0);
        assertEq(
            uint8(escrow.getSwapIntentLock(intentId).status),
            uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Refunded)
        );
    }

    function test_dustSettlementShieldsRepresentableAmountAndReturnsRemainder() public {
        bytes32 intentId = keccak256("dust");
        _lock(intentId, 40e6);
        bytes32 requestId = euint64.unwrap(escrow.getSwapIntentLock(intentId).unshieldRequestHandle);
        taskManager.publishDecryptResult(uint256(requestId), 40e6, "");
        MockMintingSwapExecutor executor = new MockMintingSwapExecutor();
        MockERC20 highPrecisionOutput = new MockERC20("High Precision", "HIGH", 18);
        vm.prank(admin);
        address highPrecisionWrapper = registry.createWrapper(
            address(highPrecisionOutput), "Encrypted High Precision", "eHIGH", ""
        );
        uint256 dustOutputAmount = 1e18 - 1;
        uint256 rate = 1e12;
        uint256 expectedDust = dustOutputAmount % rate;
        uint256 expectedShieldedUnderlying = dustOutputAmount - expectedDust;

        vm.expectEmit(true, true, true, true, address(escrow));
        emit AlphaEngineConfidentialSwapEscrow.SwapSettlementDustReturned(
            intentId, user, address(highPrecisionOutput), expectedDust
        );
        (uint256 actualOutput, bytes32 shieldedHandle) = controller.settle(
            intentId,
            address(executor),
            highPrecisionWrapper,
            40e6,
            1,
            "",
            abi.encode(dustOutputAmount)
        );

        assertEq(actualOutput, dustOutputAmount);
        assertEq(_evalue(euint64.wrap(shieldedHandle)), expectedShieldedUnderlying / rate);
        assertEq(
            _confidentialBalance(highPrecisionWrapper, user), expectedShieldedUnderlying / rate
        );
        assertEq(highPrecisionOutput.balanceOf(highPrecisionWrapper), expectedShieldedUnderlying);
        assertEq(highPrecisionOutput.balanceOf(user), expectedDust);
        assertEq(
            uint8(escrow.getSwapIntentLock(intentId).status),
            uint8(IAlphaEngineConfidentialSwapEscrow.SwapIntentLockStatus.Consumed)
        );
        assertEq(escrow.liveSwapLockCount(), 0);
        assertTrue(AlphaEngineFHERC20ERC20Wrapper(inputWrapper).getClaim(requestId).claimed);
        assertEq(inputUnderlying.balanceOf(address(escrow)), 0);
        assertEq(highPrecisionOutput.balanceOf(address(escrow)), 0);
        assertEq(highPrecisionOutput.balanceOf(address(executor)), 0);
    }

    function testFuzz_lockRefundRoundTripPreservesAmount(uint64 rawAmount) public {
        uint64 amount = uint64(bound(rawAmount, 1, 1_000_000e6));
        bytes32 intentId = keccak256(abi.encode("fuzz-refund", amount));
        _lock(intentId, amount);
        bytes32 requestId = euint64.unwrap(escrow.getSwapIntentLock(intentId).unshieldRequestHandle);
        taskManager.publishDecryptResult(uint256(requestId), amount, "");

        bytes32 refundedHandle = controller.refund(intentId, amount, "");
        assertEq(_evalue(euint64.wrap(refundedHandle)), amount);
        assertEq(_confidentialBalance(inputWrapper, user), uint256(amount) + 60e6);
        assertEq(escrow.liveSwapLockCount(), 0);
    }

    function _lock(bytes32 intentId, uint64 amount) private returns (euint64 lockedAmount) {
        _fundAndShield(amount + 60e6);
        InEuint64 memory input = createInEuint64(amount, user);
        vm.prank(user);
        lockedAmount = controller.lockWithInput(intentId, user, inputWrapper, input);
    }

    function _fundAndShield(uint256 amount) private {
        inputUnderlying.mint(user, amount);
        vm.startPrank(user);
        inputUnderlying.approve(address(gateway), amount);
        gateway.depositAndShield(address(inputUnderlying), amount, user);
        AlphaEngineFHERC20ERC20Wrapper(inputWrapper).setOperator(
            address(escrow), uint48(block.timestamp + 1 days)
        );
        vm.stopPrank();
    }

    function _confidentialBalance(address wrapperAddress, address account)
        private
        view
        returns (uint256)
    {
        return _evalue(IERC7984(wrapperAddress).confidentialBalanceOf(account));
    }

    function _evalue(euint64 encryptedValue) private view returns (uint256) {
        bytes32 handle = euint64.unwrap(encryptedValue);
        return handle == bytes32(0) ? 0 : mockStorage(uint256(handle));
    }
}

contract Stage7SwapControllerHarness {
    AlphaEngineConfidentialSwapEscrow private _escrow;

    function setEscrow(AlphaEngineConfidentialSwapEscrow escrow_) external {
        _escrow = escrow_;
    }

    function lockWithInput(
        bytes32 intentId,
        address account,
        address wrapper,
        InEuint64 calldata encryptedAmount
    ) external returns (euint64 lockedAmount) {
        euint64 amount = FHE.asEuint64(encryptedAmount);
        FHE.allow(amount, address(_escrow));
        return _escrow.lockForSwapIntent(intentId, account, wrapper, amount);
    }

    function settle(
        bytes32 intentId,
        address executor,
        address outputWrapper,
        uint64 decryptedInputAmount,
        uint256 minOutputAmount,
        bytes calldata decryptionProof,
        bytes calldata executionData
    ) external returns (uint256 outputUnderlyingAmount, bytes32 shieldedOutputHandle) {
        return _escrow.settleSwapIntent(
            intentId,
            executor,
            outputWrapper,
            decryptedInputAmount,
            minOutputAmount,
            decryptionProof,
            executionData
        );
    }

    function refund(bytes32 intentId, uint64 decryptedInputAmount, bytes calldata decryptionProof)
        external
        returns (bytes32 refundedShieldedHandle)
    {
        return _escrow.refundSwapIntent(intentId, decryptedInputAmount, decryptionProof);
    }
}

contract Stage7WrapperSurface {
    address private immutable UNDERLYING;
    uint256 private immutable RATE;

    constructor(address underlying_, uint256 rate_) {
        UNDERLYING = underlying_;
        RATE = rate_;
    }

    function underlying() external view returns (address) {
        return UNDERLYING;
    }

    function rate() external view returns (uint256) {
        return RATE;
    }
}

contract Stage7NoRegistrySurface {}

contract Stage7IgnoringMinimumExecutor is IAlphaEngineSwapExecutor {
    using SafeERC20 for IERC20;

    function executeExactInput(
        address inputToken,
        address outputToken,
        uint256 amountIn,
        uint256,
        address recipient,
        bytes calldata executionData
    ) external returns (uint256 amountOut) {
        amountOut = abi.decode(executionData, (uint256));
        IERC20(inputToken).safeTransfer(address(0xBEEF), amountIn);
        MockERC20(outputToken).mint(recipient, amountOut);
    }
}
