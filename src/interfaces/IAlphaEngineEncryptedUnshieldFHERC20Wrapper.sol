// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

interface IAlphaEngineEncryptedUnshieldFHERC20Wrapper {
    struct UnshieldClaim {
        address to;
        bytes32 ctHash;
        uint64 requestedAmount;
        uint64 decryptedAmount;
        bool claimed;
    }

    function unshield(address from, address to, euint64 amount)
        external
        returns (euint64 unshieldAmount);

    function getClaim(bytes32 ctHash) external view returns (UnshieldClaim memory claim);
}
