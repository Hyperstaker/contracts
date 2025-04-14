// Creating a seperate factory for compatibility issues
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./HyperStrategy.sol"; // Import Hyperstrategy contract

contract HyperStrategyFactory {
    address hypercertMinter;

    // Event to emit when a new HyperStrategy is created
    event HyperstrategyCreated(address indexed hyperstrategyAddress, address allo);

    constructor(address _hypercertMinter) {
        require(_hypercertMinter != address(0));
        hypercertMinter = _hypercertMinter;
    }

    // Function to create a new Hyperstrategy
    function createHyperstrategy(address _allo, string memory _name) external returns (address) {
        require(_allo != address(0));

        address newHyperStrategy = address(new HyperStrategy(_allo, _name));
        require(newHyperStrategy != address(0));

        IHypercertToken(hypercertMinter).setApprovalForAll(newHyperStrategy, true);
        emit HyperstrategyCreated(newHyperStrategy, _allo);
        return newHyperStrategy;
    }
}
