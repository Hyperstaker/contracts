// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "lib/allo-v2.1/lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {BaseStrategy} from "strategies/BaseStrategy.sol";
import {IAllo} from "lib/allo-v2.1/contracts/core/interfaces/IAllo.sol";
import {IHypercertToken} from "./interfaces/IHypercertToken.sol";
import {IHyperfund} from "./interfaces/IHyperfund.sol";

contract HyperStrategy is AccessControl, BaseStrategy {
    // Roles
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // Interfaces
    IHyperfund public hyperfund;
    IHypercertToken public hypercertMinter;

    // Events
    event Donated(address donor, address token, uint256 amount, uint256 hypercertUnits);

    // Errors
    error NOOP();

    function initialize(uint256 _poolId, bytes memory _data) external virtual override {
        (address _manager, address _hyperfund) = abi.decode(_data, (address, address));

        hyperfund = IHyperfund(_hyperfund);
        hypercertMinter = IHypercertToken(hyperfund.hypercertMinter());

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, _manager);
        __BaseStrategy_init(_poolId);
        emit Initialized(_poolId, _data);
    }

    /// ===============================
    /// ========= Constructor =========
    /// ===============================
    constructor(address _allo, string memory _name) BaseStrategy(_allo, _name) {}

    /// @notice Allocate funds hyperfund and hyperstaker pools
    /// @param _data The data to decode
    /// @param _sender The sender
    function _allocate(bytes memory _data, address _sender) internal virtual override onlyRole(MANAGER_ROLE) {
        (address[] memory _recipients, uint256[] memory _amounts) = abi.decode(_data, (address[], uint256[]));

        // Assert recipient and amounts length are equal
        if (_recipients.length != _amounts.length) {
            revert ARRAY_MISMATCH();
        }

        IAllo.Pool memory pool = allo.getPool(poolId);
        for (uint256 i; i < _recipients.length; ++i) {
            uint256 _amount = _amounts[i];
            address _recipientAddress = _recipients[i];

            _transferAmount(pool.token, _recipientAddress, _amount);

            emit Allocated(_recipientAddress, _amount, pool.token, _sender);
        }
    }

    function _afterIncreasePoolAmount(uint256 _amount) internal virtual override {
        IAllo.Pool memory pool = allo.getPool(poolId);
        uint256 hypercertFraction = hyperfund.hypercertId();
        int256 multiplier = hyperfund.tokenMultipliers(pool.token);
        uint256 units;
        if (multiplier > 0) {
            units = _amount * uint256(multiplier);
        } else {
            units = _amount / uint256(-multiplier);
        }

        uint256 availableSupply = hypercertMinter.unitsOf(hypercertFraction);
        require(availableSupply >= units);
        _mintFraction(tx.origin, units, hypercertFraction);
        emit Donated(tx.origin, pool.token, _amount, units);
    }

    function _distribute(address[] memory _recipientIds, bytes memory _recipientAmounts, address _sender)
        internal
        virtual
        override
    {
        revert NOOP();
    }

    function _getRecipientStatus(address) internal view virtual override returns (Status) {
        revert NOOP();
    }

    function _isValidAllocator(address _allocator) internal view virtual override returns (bool) {}

    function _registerRecipient(bytes memory _data, address _sender) internal virtual override returns (address) {}

    function _getPayout(address _recipientId, bytes memory _data)
        internal
        view
        virtual
        override
        returns (PayoutSummary memory)
    {}

    function _mintFraction(address account, uint256 units, uint256 hypercertId) internal {
        uint256[] memory newallocations = new uint256[](2);
        newallocations[0] = hypercertMinter.unitsOf(hypercertId) - units;
        newallocations[1] = units;
        hypercertMinter.splitFraction(account, hypercertId, newallocations);
    }

    receive() external payable {}
}
