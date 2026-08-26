// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AlphaEngineV4SwapExecutor} from "src/executors/AlphaEngineV4SwapExecutor.sol";

contract AlphaEngineV4SwapExecutorTest is Test {
    address private owner = makeAddr("owner");
    address private escrow = makeAddr("escrow");
    address private replacementEscrow = makeAddr("replacementEscrow");
    PoolManager private poolManager;
    AlphaEngineV4SwapExecutor private executor;

    function setUp() public {
        poolManager = new PoolManager(owner);
        executor = new AlphaEngineV4SwapExecutor(IPoolManager(address(poolManager)), owner, escrow);
    }

    function test_constructorRejectsZeroDependenciesAndOwner() public {
        vm.expectRevert(AlphaEngineV4SwapExecutor.ZeroPoolManager.selector);
        new AlphaEngineV4SwapExecutor(IPoolManager(address(0)), owner, escrow);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AlphaEngineV4SwapExecutor(IPoolManager(address(poolManager)), address(0), escrow);

        vm.expectRevert(AlphaEngineV4SwapExecutor.ZeroAuthorizedCaller.selector);
        new AlphaEngineV4SwapExecutor(IPoolManager(address(poolManager)), owner, address(0));
    }

    function test_authorizedCallerRotationIsOwnerOnlyAndRejectsZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        executor.setAuthorizedCaller(replacementEscrow);

        vm.prank(owner);
        vm.expectRevert(AlphaEngineV4SwapExecutor.ZeroAuthorizedCaller.selector);
        executor.setAuthorizedCaller(address(0));

        vm.prank(owner);
        executor.setAuthorizedCaller(replacementEscrow);
        assertEq(executor.authorizedCaller(), replacementEscrow);
    }

    function test_executeRejectsUnauthorizedAndInvalidCommonInputsBeforePoolCall() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineV4SwapExecutor.UnauthorizedCaller.selector, address(this)
            )
        );
        executor.executeExactInput(address(1), address(2), 1, 0, address(3), "");

        vm.startPrank(escrow);
        vm.expectRevert(AlphaEngineV4SwapExecutor.ZeroAmountIn.selector);
        executor.executeExactInput(address(1), address(2), 0, 0, address(3), "");

        vm.expectRevert(AlphaEngineV4SwapExecutor.ZeroRecipient.selector);
        executor.executeExactInput(address(1), address(2), 1, 0, address(0), "");

        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineV4SwapExecutor.InvalidInputToken.selector, address(0))
        );
        executor.executeExactInput(address(0), address(2), 1, 0, address(3), "");

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineV4SwapExecutor.InvalidOutputToken.selector, address(0)
            )
        );
        executor.executeExactInput(address(1), address(0), 1, 0, address(3), "");
        vm.stopPrank();
    }
}
