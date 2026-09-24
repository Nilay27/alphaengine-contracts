// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _customDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _customDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSelectiveFeeERC20 is MockERC20 {
    address private _feeFrom;
    address private _feeTo;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        MockERC20(name_, symbol_, decimals_)
    {}

    function setFeeRoute(address feeFrom, address feeTo) external {
        _feeFrom = feeFrom;
        _feeTo = feeTo;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == _feeFrom && to == _feeTo && value > 1) {
            uint256 fee = 1;
            super._update(from, to, value - fee);
            super._update(from, address(0), fee);
            return;
        }

        super._update(from, to, value);
    }
}

contract MockStickyAllowanceERC20 is MockERC20 {
    bool public ignoreZeroApproval;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        MockERC20(name_, symbol_, decimals_)
    {}

    function setIgnoreZeroApproval(bool enabled) external {
        ignoreZeroApproval = enabled;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (ignoreZeroApproval && value == 0) return true;
        return super.approve(spender, value);
    }
}
