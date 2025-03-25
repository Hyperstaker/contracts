// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHypercertToken} from "./interfaces/IHypercertToken.sol";

/// @notice Storage contract for Hyperfund & Hyperstaker, used to store the immutable hypercert data
contract HyperfundStorage {
    address public immutable hypercertMinter;
    uint256 public immutable hypercertTypeId;
    uint256 public immutable hypercertUnits;

    constructor(address _hypercertMinter, uint256 _hypercertTypeId) {
        hypercertMinter = _hypercertMinter;
        hypercertTypeId = _hypercertTypeId;
        hypercertUnits = IHypercertToken(_hypercertMinter).unitsOf(_hypercertTypeId + 1);
    }
}
