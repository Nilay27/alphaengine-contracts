// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IAlphaEngineFundVault} from "src/interfaces/IAlphaEngineFundVault.sol";
import {AlphaEngineFundVault} from "src/vault/AlphaEngineFundVault.sol";
import {MockERC20, MockSelectiveFeeERC20} from "test/mocks/MockERC20.sol";
import {
    MockFundVaultCallTarget,
    MockFundVaultExecutionManager,
    MockRecoveryVault
} from "test/mocks/MockFundVaultExecution.sol";

contract AlphaEngineFundVaultExecutionTest is Test {
    address private constant USER = address(0xB0B);
    address private constant EMERGENCY_AUTHORITY = address(0xE911);

    MockERC20 private usdc;
    AlphaEngineFundVault private vault;
    MockFundVaultCallTarget private accountingManager;
    MockFundVaultExecutionManager private executionManager;
    MockRecoveryVault private recoveryVault;
    MockFundVaultCallTarget private firstTarget;
    MockFundVaultCallTarget private secondTarget;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new AlphaEngineFundVault(address(this), usdc);
        accountingManager = new MockFundVaultCallTarget();
        executionManager = new MockFundVaultExecutionManager(address(this));
        recoveryVault = new MockRecoveryVault();
        firstTarget = new MockFundVaultCallTarget();
        secondTarget = new MockFundVaultCallTarget();

        vault.setUsdcManager(address(accountingManager));
        vault.setExecutionManager(address(executionManager));
        vault.setEmergencyConfiguration(EMERGENCY_AUTHORITY, address(recoveryVault));
        vault.unpause();
    }

    function testConfigurationMustBeCompleteAndLocksEveryAuthority() public {
        AlphaEngineFundVault freshVault = new AlphaEngineFundVault(address(this), usdc);
        MockFundVaultCallTarget localAccountingManager = new MockFundVaultCallTarget();
        MockFundVaultExecutionManager localExecutionManager =
            new MockFundVaultExecutionManager(address(this));
        MockRecoveryVault localRecoveryVault = new MockRecoveryVault();

        vm.expectRevert(AlphaEngineFundVault.IncompleteConfiguration.selector);
        freshVault.unpause();

        freshVault.setUsdcManager(address(localAccountingManager));
        freshVault.setExecutionManager(address(localExecutionManager));
        freshVault.setEmergencyConfiguration(EMERGENCY_AUTHORITY, address(localRecoveryVault));
        freshVault.unpause();

        assertEq(freshVault.usdcManager(), address(localAccountingManager));
        assertEq(freshVault.executionManager(), address(localExecutionManager));
        assertEq(freshVault.emergencyAuthority(), EMERGENCY_AUTHORITY);
        assertEq(freshVault.recoveryVault(), address(localRecoveryVault));

        vm.expectRevert(AlphaEngineFundVault.USDCManagerAlreadySet.selector);
        freshVault.setUsdcManager(address(firstTarget));
        vm.expectRevert(AlphaEngineFundVault.ExecutionManagerAlreadySet.selector);
        freshVault.setExecutionManager(address(firstTarget));
        vm.expectRevert(AlphaEngineFundVault.EmergencyConfigurationAlreadySet.selector);
        freshVault.setEmergencyConfiguration(USER, address(firstTarget));
    }

    function testInvalidAndOverlappingAuthoritiesFailClosed() public {
        AlphaEngineFundVault freshVault = new AlphaEngineFundVault(address(this), usdc);

        vm.expectRevert(AlphaEngineFundVault.ZeroAddress.selector);
        new AlphaEngineFundVault(address(this), IERC20(address(0)));

        vm.expectRevert(abi.encodeWithSelector(AlphaEngineFundVault.InvalidContract.selector, USER));
        freshVault.setUsdcManager(USER);
        vm.expectRevert(abi.encodeWithSelector(AlphaEngineFundVault.InvalidContract.selector, USER));
        freshVault.setExecutionManager(USER);

        freshVault.setUsdcManager(address(accountingManager));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.AuthorityOverlap.selector, address(accountingManager)
            )
        );
        freshVault.setExecutionManager(address(accountingManager));

        vm.expectRevert(AlphaEngineFundVault.ZeroAddress.selector);
        freshVault.setEmergencyConfiguration(address(0), address(recoveryVault));
        vm.expectRevert(abi.encodeWithSelector(AlphaEngineFundVault.InvalidContract.selector, USER));
        freshVault.setEmergencyConfiguration(EMERGENCY_AUTHORITY, USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.AuthorityOverlap.selector, address(freshVault)
            )
        );
        freshVault.setEmergencyConfiguration(EMERGENCY_AUTHORITY, address(freshVault));

        AlphaEngineFundVault reverseOrderVault = new AlphaEngineFundVault(address(this), usdc);
        reverseOrderVault.setExecutionManager(address(executionManager));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.AuthorityOverlap.selector, address(executionManager)
            )
        );
        reverseOrderVault.setUsdcManager(address(executionManager));

        AlphaEngineFundVault configuredManagersVault = new AlphaEngineFundVault(address(this), usdc);
        configuredManagersVault.setUsdcManager(address(accountingManager));
        configuredManagersVault.setExecutionManager(address(executionManager));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.AuthorityOverlap.selector, address(accountingManager)
            )
        );
        configuredManagersVault.setEmergencyConfiguration(
            address(accountingManager), address(recoveryVault)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.AuthorityOverlap.selector, address(executionManager)
            )
        );
        configuredManagersVault.setEmergencyConfiguration(
            EMERGENCY_AUTHORITY, address(executionManager)
        );
    }

    function testAccountingAndExecutionSelectorsAreDisjoint() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory targetData) =
            _singleAddCall(firstTarget, 1);

        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.UnauthorizedExecutionManager.selector, USER)
        );
        vm.prank(USER);
        vault.executeBatch(targets, values, targetData);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.UnauthorizedExecutionManager.selector,
                address(accountingManager)
            )
        );
        vm.prank(address(accountingManager));
        vault.executeBatch(targets, values, targetData);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.UnauthorizedUSDCManager.selector, address(executionManager)
            )
        );
        vm.prank(address(executionManager));
        vault.mintFeeShares(USER, 1);
    }

    function testBatchExecutesInOrderAndReturnsEveryResult() public {
        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory targetData = new bytes[](3);
        targets[0] = address(firstTarget);
        targets[1] = address(secondTarget);
        targets[2] = address(firstTarget);
        targetData[0] = abi.encodeCall(MockFundVaultCallTarget.add, (2));
        targetData[1] = abi.encodeCall(MockFundVaultCallTarget.add, (7));
        targetData[2] = abi.encodeCall(MockFundVaultCallTarget.add, (3));

        bytes32 batchHash = keccak256(abi.encode(targets, values, targetData));
        vm.expectEmit(true, true, false, true, address(vault));
        emit AlphaEngineFundVault.BatchExecuted(address(executionManager), batchHash, 3);
        bytes[] memory results = executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );

        assertEq(firstTarget.total(), 5);
        assertEq(secondTarget.total(), 7);
        assertEq(abi.decode(results[0], (uint256)), 2);
        assertEq(abi.decode(results[1], (uint256)), 7);
        assertEq(abi.decode(results[2], (uint256)), 5);
    }

    function testBatchRevertsEveryEarlierEffectWhenOneCallFails() public {
        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory targetData = new bytes[](3);
        targets[0] = address(firstTarget);
        targets[1] = address(secondTarget);
        targets[2] = address(firstTarget);
        targetData[0] = abi.encodeCall(MockFundVaultCallTarget.add, (9));
        targetData[1] = abi.encodeCall(MockFundVaultCallTarget.fail, (77));
        targetData[2] = abi.encodeCall(MockFundVaultCallTarget.add, (100));

        bytes memory downstreamRevert =
            abi.encodeWithSelector(MockFundVaultCallTarget.ForcedFailure.selector, 77);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.BatchCallFailed.selector,
                uint256(1),
                address(secondTarget),
                downstreamRevert
            )
        );
        executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );

        assertEq(firstTarget.total(), 0);
        assertEq(secondTarget.total(), 0);
    }

    function testBatchBoundsLengthsAndTargetsFailBeforeExecution() public {
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);
        bytes[] memory targetData = new bytes[](0);
        vm.expectRevert(AlphaEngineFundVault.EmptyBatch.selector);
        executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );

        targets = new address[](1);
        values = new uint256[](1);
        targetData = new bytes[](0);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.BatchLengthMismatch.selector, 1, 1, 0)
        );
        executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );

        targets = new address[](17);
        values = new uint256[](17);
        targetData = new bytes[](17);
        vm.expectRevert(abi.encodeWithSelector(AlphaEngineFundVault.BatchTooLarge.selector, 17, 16));
        executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );

        targets = new address[](1);
        values = new uint256[](0);
        targetData = new bytes[](1);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.BatchLengthMismatch.selector, 1, 0, 1)
        );
        executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );

        (targets, values, targetData) = _singleRawCall(USER, bytes(""));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.InvalidBatchTarget.selector, uint256(0), USER
            )
        );
        executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );

        (targets, values, targetData) = _singleAddCall(firstTarget, 1);
        targets[0] = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.InvalidBatchTarget.selector, uint256(0), address(0)
            )
        );
        executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );
        assertEq(firstTarget.total(), 0);
    }

    function testExactMaximumBatchExecutesAndLaterInvalidTargetPreflightsAtomically() public {
        uint256 maximum = vault.MAX_BATCH_CALLS();
        address[] memory targets = new address[](maximum);
        uint256[] memory values = new uint256[](maximum);
        bytes[] memory targetData = new bytes[](maximum);
        for (uint256 i; i < maximum; ++i) {
            targets[i] = address(firstTarget);
            targetData[i] = abi.encodeCall(MockFundVaultCallTarget.add, (1));
        }

        bytes[] memory results = executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );
        assertEq(results.length, maximum);
        assertEq(firstTarget.total(), maximum);

        targets = new address[](2);
        values = new uint256[](2);
        targetData = new bytes[](2);
        targets[0] = address(secondTarget);
        targets[1] = USER;
        targetData[0] = abi.encodeCall(MockFundVaultCallTarget.add, (99));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.InvalidBatchTarget.selector, uint256(1), USER
            )
        );
        executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );
        assertEq(secondTarget.total(), 0);
    }

    function testVaultAndBothManagersAreProtectedBatchTargets() public {
        _expectProtectedTarget(address(vault));
        _expectProtectedTarget(address(accountingManager));
        _expectProtectedTarget(address(executionManager));
        _expectProtectedTarget(EMERGENCY_AUTHORITY);
        _expectProtectedTarget(address(recoveryVault));
        _expectProtectedTarget(address(this));
    }

    function testEmergencyAndOwnerPauseButOnlyOwnerCanUnpause() public {
        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.UnauthorizedPauser.selector, USER)
        );
        vm.prank(USER);
        vault.pause();

        vm.prank(EMERGENCY_AUTHORITY);
        vault.pause();
        assertTrue(vault.paused());

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, EMERGENCY_AUTHORITY)
        );
        vm.prank(EMERGENCY_AUTHORITY);
        vault.unpause();

        vault.unpause();
        vault.pause();
        assertTrue(vault.paused());
    }

    function testPausedVaultRejectsExecutionButStillPermitsExactRecovery() public {
        uint256 amount = 1000e6;
        usdc.mint(address(vault), amount);
        vm.prank(EMERGENCY_AUTHORITY);
        vault.pause();

        (address[] memory targets, uint256[] memory values, bytes[] memory targetData) =
            _singleAddCall(firstTarget, 1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );

        vm.expectEmit(true, true, false, true, address(vault));
        emit AlphaEngineFundVault.AssetRecovered(address(usdc), address(recoveryVault), amount);
        vm.prank(EMERGENCY_AUTHORITY);
        assertEq(vault.recoverAsset(usdc), amount);

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(recoveryVault)), amount);
        assertTrue(vault.recoveryActivated());
        vm.expectRevert(AlphaEngineFundVault.RecoveryAlreadyActivated.selector);
        vault.unpause();
    }

    function testRecoveryAuthorityAssetAndExactTransferBoundariesFailClosed() public {
        MockERC20 position = new MockERC20("Position", "POS", 18);
        position.mint(address(vault), 100e18);
        vm.prank(EMERGENCY_AUTHORITY);
        vault.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.UnauthorizedEmergencyAuthority.selector, USER
            )
        );
        vm.prank(USER);
        vault.recoverAsset(position);

        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.AssetNotRecoverable.selector, address(0))
        );
        vm.prank(EMERGENCY_AUTHORITY);
        vault.recoverAsset(IERC20(address(0)));

        vm.expectRevert(
            abi.encodeWithSelector(AlphaEngineFundVault.AssetNotRecoverable.selector, USER)
        );
        vm.prank(EMERGENCY_AUTHORITY);
        vault.recoverAsset(IERC20(USER));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.AssetNotRecoverable.selector, address(vault)
            )
        );
        vm.prank(EMERGENCY_AUTHORITY);
        vault.recoverAsset(IERC20(address(vault)));

        MockERC20 emptyPosition = new MockERC20("Empty", "EMPTY", 18);
        vm.expectRevert(AlphaEngineFundVault.ZeroAssets.selector);
        vm.prank(EMERGENCY_AUTHORITY);
        vault.recoverAsset(emptyPosition);

        MockSelectiveFeeERC20 feeToken = new MockSelectiveFeeERC20("Fee", "FEE", 18);
        feeToken.mint(address(vault), 10e18);
        feeToken.setFeeRoute(address(vault), address(recoveryVault));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.AssetTransferMismatch.selector, 10e18, 10e18 - 1
            )
        );
        vm.prank(EMERGENCY_AUTHORITY);
        vault.recoverAsset(feeToken);

        assertEq(feeToken.balanceOf(address(vault)), 10e18);
        assertEq(feeToken.balanceOf(address(recoveryVault)), 0);
        assertFalse(vault.recoveryActivated());
    }

    function testFuzzBatchOrderAndAccountingSupplyRemainUnchanged(
        uint96 first,
        uint96 second,
        uint96 third
    ) public {
        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory targetData = new bytes[](3);
        targets[0] = address(firstTarget);
        targets[1] = address(firstTarget);
        targets[2] = address(secondTarget);
        targetData[0] = abi.encodeCall(MockFundVaultCallTarget.add, (first));
        targetData[1] = abi.encodeCall(MockFundVaultCallTarget.add, (second));
        targetData[2] = abi.encodeCall(MockFundVaultCallTarget.add, (third));

        uint256 supplyBefore = vault.totalSupply();
        executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );

        assertEq(firstTarget.total(), uint256(first) + uint256(second));
        assertEq(secondTarget.total(), third);
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    function _expectProtectedTarget(address protectedTarget) private {
        (address[] memory targets, uint256[] memory values, bytes[] memory targetData) =
            _singleRawCall(protectedTarget, bytes(""));
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaEngineFundVault.ProtectedBatchTarget.selector, uint256(0), protectedTarget
            )
        );
        executionManager.executeBatch(
            IAlphaEngineFundVault(address(vault)), targets, values, targetData
        );
    }

    function _singleAddCall(MockFundVaultCallTarget target, uint256 amount)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory targetData)
    {
        return
            _singleRawCall(address(target), abi.encodeCall(MockFundVaultCallTarget.add, (amount)));
    }

    function _singleRawCall(address target, bytes memory data)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory targetData)
    {
        targets = new address[](1);
        values = new uint256[](1);
        targetData = new bytes[](1);
        targets[0] = target;
        targetData[0] = data;
    }
}
