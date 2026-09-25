// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FHE, euint64, sharedEuint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ERC20ConfidentialLib
} from "fhenix-confidential-contracts/ERC20Confidential/ERC20ConfidentialLib.sol";
import {FHERC20} from "fhenix-confidential-contracts/FHERC20/FHERC20.sol";
import {
    FHERC20ERC20Wrapper
} from "fhenix-confidential-contracts/FHERC20/extensions/FHERC20ERC20Wrapper.sol";
import {
    FHERC20InvalidReceiver,
    FHERC20UnauthorizedSpender
} from "fhenix-confidential-contracts/FHERC20/utils/FHERC20Errors.sol";
import {
    IAlphaEngineConfidentialAssetRegistry
} from "../interfaces/IAlphaEngineConfidentialAssetRegistry.sol";

contract AlphaEngineFHERC20ERC20Wrapper is FHERC20ERC20Wrapper {
    using SafeERC20 for IERC20;

    error ZeroUnderlying();
    error InvalidUnderlying(address underlying);
    error UnshieldAmountBelowMinimum(uint64 supplied, uint64 minimum);
    error PendingUnshieldClaim(address account, bytes32 claimId);

    uint64 public immutable minimumUnshieldAmount;
    address public immutable wrapperRegistry;

    /// @notice Latest unique claim ID created for a recipient. Read atomically after unshield.
    mapping(address recipient => bytes32 claimId) public latestUnshieldClaimId;
    mapping(address account => bytes32 claimId) public pendingUnshieldClaimId;
    mapping(bytes32 claimId => address account) private _claimSource;

    constructor(
        IERC20 underlying_,
        string memory name_,
        string memory symbol_,
        string memory contractURI_
    )
        FHERC20(name_, symbol_, _cappedDecimals(underlying_), contractURI_)
        FHERC20ERC20Wrapper(underlying_)
    {
        if (address(underlying_) == address(0)) {
            revert ZeroUnderlying();
        }
        if (address(underlying_).code.length == 0) {
            revert InvalidUnderlying(address(underlying_));
        }
        wrapperRegistry = msg.sender;
        uint8 precision = decimals();
        minimumUnshieldAmount = precision > 3 ? uint64(10 ** (precision - 3)) : 1;
    }

    function unshield(address from, address to, uint64 amount)
        public
        override
        returns (sharedEuint64)
    {
        if (amount < minimumUnshieldAmount) {
            revert UnshieldAmountBelowMinimum(amount, minimumUnshieldAmount);
        }
        return super.unshield(from, to, amount);
    }

    /// @dev Upstream unshield returns only a shared ciphertext. Retain the official claim ID
    ///      here so callers can obtain it in O(1), without enumerating every pending claim.
    ///      Both inherited, non-reentrant unshield overloads use this hook.
    function _unshield(address from, address to, euint64 amount)
        internal
        virtual
        override
        returns (euint64 unshieldAmount)
    {
        if (to == address(0)) {
            revert FHERC20InvalidReceiver(to);
        }
        if (from != msg.sender && !isOperator(from, msg.sender)) {
            revert FHERC20UnauthorizedSpender(from, msg.sender);
        }
        bool trustedEscrow = _isTrustedSwapEscrow(from);
        if (!trustedEscrow && pendingUnshieldClaimId[from] != bytes32(0)) {
            revert PendingUnshieldClaim(from, pendingUnshieldClaimId[from]);
        }
        unshieldAmount = _burn(from, amount);
        FHE.allowPublic(unshieldAmount);
        bytes32 claimId = _createClaim(to, unshieldAmount);
        latestUnshieldClaimId[to] = claimId;
        if (!trustedEscrow) {
            pendingUnshieldClaimId[from] = claimId;
            _claimSource[claimId] = from;
        }

        emit Unshielded(to, unshieldAmount);
    }

    function claimUnshielded(bytes32 id, uint64 decryptedAmount, bytes memory decryptionProof)
        public
        override
        nonReentrant
    {
        ERC20ConfidentialLib.Claim memory claim = _handleClaim(id, decryptedAmount, decryptionProof);
        uint256 underlyingAmount = uint256(claim.decryptedAmount) * rate();
        if (underlyingAmount != 0) IERC20(underlying()).safeTransfer(claim.to, underlyingAmount);
        _clearPendingClaim(id);
        emit ClaimedUnshielded(claim.to, id, FHE.wrapEuint64(claim.ctHash), claim.decryptedAmount);
    }

    function claimUnshieldedBatch(
        bytes32[] memory ids,
        uint64[] memory decryptedAmounts,
        bytes[] memory decryptionProofs
    ) public override nonReentrant {
        ERC20ConfidentialLib.Claim[] memory claims = _handleClaimBatch(
            ids, decryptedAmounts, decryptionProofs
        );
        for (uint256 i = 0; i < claims.length; i++) {
            uint256 underlyingAmount = uint256(claims[i].decryptedAmount) * rate();
            if (underlyingAmount != 0) {
                IERC20(underlying()).safeTransfer(claims[i].to, underlyingAmount);
            }
            _clearPendingClaim(ids[i]);
            emit ClaimedUnshielded(
                claims[i].to, ids[i], FHE.wrapEuint64(claims[i].ctHash), claims[i].decryptedAmount
            );
        }
    }

    function _clearPendingClaim(bytes32 id) private {
        address source = _claimSource[id];
        if (source != address(0)) {
            delete pendingUnshieldClaimId[source];
            delete _claimSource[id];
        }
    }

    function _isTrustedSwapEscrow(address from) private view returns (bool) {
        if (from != msg.sender || from.code.length == 0) return false;
        (bool success, bytes memory encodedEscrow) = wrapperRegistry.staticcall(
            abi.encodeCall(IAlphaEngineConfidentialAssetRegistry.trustedSwapEscrow, ())
        );
        return success && encodedEscrow.length == 32 && abi.decode(encodedEscrow, (address)) == from;
    }

    function _cappedDecimals(IERC20 token) private view returns (uint8) {
        (bool success, bytes memory encodedDecimals) =
            address(token).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        uint8 tokenDecimals =
            success && encodedDecimals.length == 32 ? abi.decode(encodedDecimals, (uint8)) : 18;
        uint8 maxDecimals = _maxDecimals();

        return tokenDecimals > maxDecimals ? maxDecimals : tokenDecimals;
    }
}
