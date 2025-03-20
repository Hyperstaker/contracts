// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

interface IHyperfund {
    function hypercertId() external view returns (uint256);
    function tokenMultipliers(address token) external view returns (int256);
    function hypercertMinter() external view returns (address);
}
