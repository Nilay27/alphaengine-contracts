// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IFHERC20ERC20Wrapper} from
    "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {AlphaEngineConfidentialVault} from "../../src/vault/AlphaEngineConfidentialVault.sol";
import {AlphaEngineFHERC20ERC20Wrapper} from "../../src/fherc20/AlphaEngineFHERC20ERC20Wrapper.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract AlphaEngineConfidentialVaultUnitTest is Test {
    event IntentControllerUpdated(
        address indexed previousIntentController, address indexed newIntentController
    );
    event ConfidentialWrapperRegistered(address indexed underlying, address indexed wrapper);
    event Paused(address account);
    event Unpaused(address account);

    AlphaEngineConfidentialVault private implementation;
    AlphaEngineConfidentialVault private vault;
    TransparentUpgradeableProxy private proxy;
    MockERC20 private underlying;

    address private owner = address(0xA11CE);
    address private intentController = address(0x1A7E17);
    address private user = address(0xB0B);

    function setUp() public {
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
