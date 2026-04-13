// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

interface IAlphaEngineEncryptedUnshieldFHERC20Wrapper {
    function unshield(address from, address to, euint64 amount)
        external
        returns (euint64 unshieldAmount);
}
