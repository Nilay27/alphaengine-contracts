// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICoFHEAddressBook} from "@fhenixprotocol/cofhe-contracts/ICofhe.sol";

/// @dev Fixed local fixture, never deployed to a public network.
contract MockCoFheAddressBook is ICoFHEAddressBook {
    error UnknownTaskManagerId(uint256 id);

    function getTm(uint256 id) external pure returns (address) {
        if (id != 1) revert UnknownTaskManagerId(id);
        return 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;
    }
}
