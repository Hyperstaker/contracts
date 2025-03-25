// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {HyperfundFactory} from "../../src/HyperfundFactory.sol";

contract MockHyperfundFactoryV2 is HyperfundFactory {
    // Add new functionality to test upgrades
    function version() public pure returns (uint256) {
        return 2;
    }
}
