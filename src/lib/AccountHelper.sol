// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.23;

import {FilAddress} from "../../node_modules/fevmate/contracts/utils/FilAddress.sol";

/// @title Helper library for checking account type
/// @author LimeChain team
library AccountHelper {
    function isSystemActor(address _address) external pure returns (bool) {
        return _address == FilAddress.SYSTEM_ACTOR;
    }
}
