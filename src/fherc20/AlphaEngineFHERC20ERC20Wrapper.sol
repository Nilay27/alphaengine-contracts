// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FHE, euint64, sharedEuint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ERC20ConfidentialLib
} from "fhenix-confidential-contracts/ERC20Confidential/ERC20ConfidentialLib.sol";
import {
    FHERC20ERC20WrapperUpgradeable
} from "fhenix-confidential-contracts/FHERC20/extensions/FHERC20ERC20WrapperUpgradeable.sol";
import {
    FHERC20InvalidReceiver,
    FHERC20UnauthorizedSpender
} from "fhenix-confidential-contracts/FHERC20/utils/FHERC20Errors.sol";
import {
    IAlphaEngineConfidentialAssetRegistry
} from "../interfaces/IAlphaEngineConfidentialAssetRegistry.sol";

contract AlphaEngineFHERC20ERC20Wrapper is FHERC20ERC20WrapperUpgradeable {
    using SafeERC20 for IERC20;

    error ZeroUnderlying();
    error InvalidUnderlying(address underlying);
    error UnshieldAmountBelowMinimum(uint64 supplied, uint64 minimum);
    error PendingUnshieldClaim(address account, bytes32 claimId);
    error InvalidWrapperRegistry(address registry);
    error UnshieldMinimumNotConfigured();
    error UnshieldCooldownActive(address account, uint256 nextAvailableAt);

    uint256 public constant UNSHIELD_COOLDOWN = 5 minutes;
    address public wrapperRegistry;
    mapping(address account => uint40 availableAt) public unshieldCooldownUntil;

    event UnshieldCooldownStarted(address indexed account, uint40 availableAt);
    event FullBalanceUnshieldRequested(
        address indexed account, address indexed recipient, bytes32 claimId
    );

    /// @notice Latest unique claim ID created for a recipient. Read atomically after unshield.
    mapping(address recipient => bytes32 claimId) public latestUnshieldClaimId;
    mapping(address account => bytes32 claimId) public pendingUnshieldClaimId;
    mapping(bytes32 claimId => address account) private _claimSource;
    uint256[45] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 underlying_,
        string memory name_,
        string memory symbol_,
        string memory contractURI_,
        address registry_
    ) external initializer {
        if (address(underlying_) == address(0)) {
            revert ZeroUnderlying();
        }
        if (address(underlying_).code.length == 0) {
            revert InvalidUnderlying(address(underlying_));
        }
        if (registry_ == address(0) || registry_.code.length == 0) {
            revert InvalidWrapperRegistry(registry_);
        }
        __FHERC20_init(name_, symbol_, _cappedDecimals(underlying_), contractURI_);
        __FHERC20ERC20Wrapper_init(underlying_);
        wrapperRegistry = registry_;
    }

    function minimumUnshieldAmount() public view returns (uint64) {
        return
            IAlphaEngineConfidentialAssetRegistry(wrapperRegistry)
                .minimumUnshieldAmount(address(this));
    }

    function unshield(address from, address to, uint64 amount)
        public
        override
        nonReentrant
        returns (sharedEuint64)
    {
        uint64 minimum = _configuredMinimum();
        if (amount < minimum) {
            revert UnshieldAmountBelowMinimum(amount, minimum);
        }
        bool trustedEscrow = _admitUnshield(from, to);
        // Plaintext minimum is already checked; avoid a redundant encrypted comparison.
        return FHE.shareEuint64(
            _burnAndCreateClaim(from, to, FHE.asEuint64(amount), trustedEscrow), msg.sender
        );
    }

    /// @notice Withdraw the caller's entire balance at request time, including dust.
    /// @dev Uses the same pending/admission gates and spaces full exits by at least five minutes.
    ///      Deposits or transfers received later are not part of this request.
    function unshieldAll(address to) external nonReentrant returns (sharedEuint64) {
        bool trustedEscrow = _admitUnshield(msg.sender, to);
        _startCooldown(msg.sender);
        euint64 burned =
            _burnAndCreateClaim(msg.sender, to, confidentialBalanceOf(msg.sender), trustedEscrow);
        emit FullBalanceUnshieldRequested(msg.sender, to, latestUnshieldClaimId[to]);
        return FHE.shareEuint64(burned, msg.sender);
    }

    /// @dev Upstream unshield returns only a shared ciphertext. Retain the official claim ID
    ///      here so callers can obtain it in O(1), without enumerating every pending claim.
    ///      The inherited encrypted overload authenticates its share before this hook.
    function _unshield(address from, address to, euint64 amount)
        internal
        virtual
        override
        returns (euint64 unshieldAmount)
    {
        bool trustedEscrow = _admitUnshield(from, to);
        if (!trustedEscrow) {
            amount = FHE.select(
                FHE.gte(amount, FHE.asEuint64(_configuredMinimum())), amount, FHE.asEuint64(0)
            );
        }
        return _burnAndCreateClaim(from, to, amount, trustedEscrow);
    }

    function _admitUnshield(address from, address to) private returns (bool trustedEscrow) {
        if (to == address(0)) {
            revert FHERC20InvalidReceiver(to);
        }
        if (from != msg.sender && !isOperator(from, msg.sender)) {
            revert FHERC20UnauthorizedSpender(from, msg.sender);
        }
        trustedEscrow = _isTrustedSwapEscrow(from);
        if (!trustedEscrow) {
            if (pendingUnshieldClaimId[from] != bytes32(0)) {
                revert PendingUnshieldClaim(from, pendingUnshieldClaimId[from]);
            }
            if (block.timestamp < unshieldCooldownUntil[from]) {
                revert UnshieldCooldownActive(from, unshieldCooldownUntil[from]);
            }
            IAlphaEngineConfidentialAssetRegistry(wrapperRegistry).consumeUnshieldAdmission();
        }
    }

    function _burnAndCreateClaim(address from, address to, euint64 amount, bool trustedEscrow)
        private
        returns (euint64 unshieldAmount)
    {
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
        _clearPendingClaim(id, claim.decryptedAmount);
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
            _clearPendingClaim(ids[i], claims[i].decryptedAmount);
            emit ClaimedUnshielded(
                claims[i].to, ids[i], FHE.wrapEuint64(claims[i].ctHash), claims[i].decryptedAmount
            );
        }
    }

    function _clearPendingClaim(bytes32 id, uint64 actualAmount) private {
        address source = _claimSource[id];
        if (source != address(0)) {
            delete pendingUnshieldClaimId[source];
            delete _claimSource[id];
            if (actualAmount == 0) _startCooldown(source);
        }
    }

    function _startCooldown(address account) private {
        uint40 availableAt = uint40(block.timestamp + UNSHIELD_COOLDOWN);
        unshieldCooldownUntil[account] = availableAt;
        emit UnshieldCooldownStarted(account, availableAt);
    }

    function _configuredMinimum() private view returns (uint64 minimum) {
        minimum = minimumUnshieldAmount();
        if (minimum == 0) revert UnshieldMinimumNotConfigured();
    }

    function _isTrustedSwapEscrow(address from) private view returns (bool) {
        if (from != msg.sender || from.code.length == 0) return false;
        return IAlphaEngineConfidentialAssetRegistry(wrapperRegistry).trustedSwapEscrow() == from;
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
