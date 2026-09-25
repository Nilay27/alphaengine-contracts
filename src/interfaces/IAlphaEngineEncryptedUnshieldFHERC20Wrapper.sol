// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    IFHERC20ERC20Wrapper
} from "fhenix-confidential-contracts/interfaces/IFHERC20ERC20Wrapper.sol";
import {
    ERC20ConfidentialLib
} from "fhenix-confidential-contracts/ERC20Confidential/ERC20ConfidentialLib.sol";
import {sharedEuint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @notice Official encrypted-unshield surface plus constant-time claim ID discovery.
interface IAlphaEngineEncryptedUnshieldFHERC20Wrapper is IFHERC20ERC20Wrapper {
    function wrapperRegistry() external view returns (address);
    function unshieldAll(address recipient) external returns (sharedEuint64);
    function latestUnshieldClaimId(address recipient) external view returns (bytes32 claimId);

    function getClaim(bytes32 claimId)
        external
        view
        returns (ERC20ConfidentialLib.Claim memory claim);
}
