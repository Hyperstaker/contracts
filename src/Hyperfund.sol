// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHypercertToken} from "./interfaces/IHypercertToken.sol";

contract Hyperfund is AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    // immutable values that are set on initialization
    IHypercertToken public hypercertMinter;
    uint256 public hypercertId;
    uint256 public hypercertTypeId;
    uint256 public hypercertUnits;

    // erc20 token allowlist, 0 means the token is not allowed
    // negative multiplier means the total amount of Hypercert units is smaller than the amount of tokens it represents and rounding is applied
    mapping(address token => int256 multiplier) public tokenMultipliers;

    // allowlist for non-financial contributions, 0 means the contributor is not allowed
    mapping(address contributor => uint256 units) public nonfinancialContributions;

    uint256 internal constant TYPE_MASK = type(uint256).max << 128;

    // Roles
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Events
    event TokenAllowlisted(address token, int256 multiplier);
    event FundsWithdrawn(address token, uint256 amount, address to);
    event Funded(address token, uint256 amount);
    event NonfinancialContribution(address contributor, uint256 units);
    event FractionRedeemed(uint256 hypercertId, address token, uint256 amount);

    // Errors
    error TokenNotAllowlisted();
    error InvalidAmount();
    error InvalidAddress();
    error AmountExceedsAvailableSupply(uint256 availableSupply);
    error TransferFailed();
    error NotFractionOfThisHypercert(uint256 rightHypercertId);
    error Unauthorized();
    error ArrayLengthsMismatch();
    error NotAllowlisted();

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract, to be called by proxy
    /// @notice NOTE: after deployment of proxy, the Hypercert owner must approve the proxy contract to split and burn fractions
    /// by calling hypercertMinter.setApprovalForAll(address(proxy), true)
    /// @param _hypercertMinter The address of the Hypercert minter contract
    /// @param _hypercertTypeId The id of the Hypercert type
    /// @param _admin The address that will have the DEFAULT_ADMIN_ROLE
    /// @param _manager The address that will have the MANAGER_ROLE
    /// @param _pauser The address that will have the PAUSER_ROLE
    /// @param _upgrader The address that will have the UPGRADER_ROLE
    function initialize(
        address _hypercertMinter,
        uint256 _hypercertTypeId,
        address _admin,
        address _manager,
        address _pauser,
        address _upgrader
    ) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _manager);
        _grantRole(PAUSER_ROLE, _pauser);
        _grantRole(UPGRADER_ROLE, _upgrader);

        hypercertMinter = IHypercertToken(_hypercertMinter);
        hypercertTypeId = _hypercertTypeId;
        hypercertId = hypercertTypeId + 1;
        hypercertUnits = hypercertMinter.unitsOf(hypercertId);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ADMIN FUNCTIONS

    /// @notice Set the multiplier for an allowlisted token, 0 means the token is not allowed, only callable by a manager
    /// @param _token address of the token
    /// @param _multiplier multiplier for the token, negative multiplier means the total amount of Hypercert units is
    /// smaller than the amount of tokens it represents and rounding is applied
    function allowlistToken(address _token, int256 _multiplier) external onlyRole(MANAGER_ROLE) {
        tokenMultipliers[_token] = _multiplier;
        emit TokenAllowlisted(_token, _multiplier);
    }

    /// @notice Withdraw funds from the hyperfund, only callable by a manager
    /// @param _token address of the token to withdraw, address(0) for native token
    /// @param _amount amount of the token to withdraw
    /// @param _to address to send the funds to
    function withdrawFunds(address _token, uint256 _amount, address _to) external onlyRole(MANAGER_ROLE) {
        if (_token == address(0)) {
            payable(_to).transfer(_amount);
        } else {
            require(IERC20(_token).transfer(_to, _amount), TransferFailed());
        }
        emit FundsWithdrawn(_token, _amount, _to);
    }

    /// @notice Issue a Hypercert fraction for a non-financial contribution, only callable by a manager
    /// @param _contributor address of the contributor to receive the Hypercert fraction
    /// @param _units amount of units to register as a non-financial contribution
    function nonfinancialContribution(address _contributor, uint256 _units)
        external
        whenNotPaused
        onlyRole(MANAGER_ROLE)
    {
        uint256 availableSupply = hypercertMinter.unitsOf(hypercertId);
        require(availableSupply >= _units, AmountExceedsAvailableSupply(availableSupply));
        _nonfinancialContribution(_contributor, _units);
    }

    /// @notice Issue Hypercert fractions for non-financial contributions, only callable by a manager
    /// @param _contributors array of addresses of the contributors
    /// @param _units array of amounts of units to register as non-financial contributions
    function nonFinancialContributions(address[] calldata _contributors, uint256[] calldata _units)
        external
        onlyRole(MANAGER_ROLE)
    {
        require(_contributors.length == _units.length, ArrayLengthsMismatch());
        uint256 totalUnits = 0;
        for (uint256 i = 0; i < _units.length; i++) {
            totalUnits += _units[i];
        }
        uint256 availableSupply = hypercertMinter.unitsOf(hypercertId);
        require(availableSupply >= totalUnits, AmountExceedsAvailableSupply(availableSupply));

        for (uint256 i = 0; i < _contributors.length; i++) {
            _nonfinancialContribution(_contributors[i], _units[i]);
        }
    }

    /// @notice pause the hyperfund, only callable by a pauser
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice unpause the hyperfund, only callable by a pauser
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // USER FUNCTIONS

    /// @notice Send funds to the hyperfund and receive a Hypercert fraction
    /// @param _token address of the token to send, must be allowlisted. address(0) for native token
    /// @param _amount amount of the token to send
    function fund(address _token, uint256 _amount) external payable whenNotPaused {
        require(tokenMultipliers[_token] != 0, TokenNotAllowlisted());
        require(_amount != 0, InvalidAmount());
        uint256 units = _tokenAmountToUnits(_token, _amount);
        uint256 availableSupply = hypercertMinter.unitsOf(hypercertId);
        require(availableSupply >= units, AmountExceedsAvailableSupply(availableSupply));
        if (_token == address(0)) {
            require(msg.value == _amount, InvalidAmount());
        } else {
            require(IERC20(_token).transferFrom(msg.sender, address(this), _amount), TransferFailed());
        }
        _mintFraction(msg.sender, units);
        emit Funded(_token, _amount);
    }

    /// @notice Redeem a Hypercert fraction for the corresponding amount of tokens. User must have previously contributed
    /// enough non-financial units
    /// NOTE: sender must first approve the hyperfund to burn the Hypercert fraction, by calling hypercertMinter.setApprovalForAll(address(this), true)
    /// @param _fractionId id of the Hypercert fraction
    /// @param _token address of the token to redeem, must be allowlisted. address(0) for native token
    function redeem(uint256 _fractionId, address _token) external whenNotPaused {
        require(nonfinancialContributions[msg.sender] != 0, NotAllowlisted());
        require(hypercertMinter.ownerOf(_fractionId) == msg.sender, Unauthorized());
        require(_isFraction(_fractionId), NotFractionOfThisHypercert(hypercertTypeId));
        uint256 units = hypercertMinter.unitsOf(_fractionId);
        require(units != 0, InvalidAmount());
        uint256 tokenAmount = _unitsToTokenAmount(_token, units);
        if (_token == address(0)) {
            (bool success,) = payable(msg.sender).call{value: tokenAmount}("");
            require(success, TransferFailed());
        } else {
            require(IERC20(_token).transfer(msg.sender, tokenAmount), TransferFailed());
        }
        hypercertMinter.burnFraction(msg.sender, _fractionId); // sets the units of the fraction to 0
        nonfinancialContributions[msg.sender] -= units;
        emit FractionRedeemed(_fractionId, _token, tokenAmount);
    }

    // INTERNAL FUNCTIONS

    /// @notice Mint a Hypercert fraction for a non-financial contributor and register the amount of non-financial units contributed
    /// @param _contributor address of the contributor to receive the Hypercert fraction
    /// @param _units amount of units to register as a non-financial contribution
    function _nonfinancialContribution(address _contributor, uint256 _units) internal {
        require(_contributor != address(0), InvalidAddress());
        require(_units != 0, InvalidAmount());
        nonfinancialContributions[_contributor] += _units;
        _mintFraction(_contributor, _units);
        emit NonfinancialContribution(_contributor, _units);
    }

    /// @notice Split a fraction of the Hypercert for a contributor
    /// @param _contributor address of the contributor to receive the Hypercert fraction
    /// @param _units amount of units to mint
    function _mintFraction(address _contributor, uint256 _units) internal {
        uint256[] memory newallocations = new uint256[](2);
        newallocations[0] = hypercertMinter.unitsOf(hypercertId) - _units;
        newallocations[1] = _units;
        hypercertMinter.splitFraction(_contributor, hypercertId, newallocations);
    }

    /// @notice Convert token amount to Hypercert units using the token's multiplier
    /// @param _token address of the token
    /// @param _amount amount of the token
    /// @return units amount of Hypercert units
    function _tokenAmountToUnits(address _token, uint256 _amount) internal view returns (uint256 units) {
        int256 multiplier = tokenMultipliers[_token];
        if (multiplier > 0) {
            units = _amount * uint256(multiplier);
        } else {
            units = _amount / uint256(-multiplier);
        }
    }

    /// @notice Convert Hypercert units to token amount using the token's multiplier
    /// @param _token address of the token
    /// @param _units amount of Hypercert units
    /// @return amount amount of the token
    function _unitsToTokenAmount(address _token, uint256 _units) internal view returns (uint256 amount) {
        int256 multiplier = tokenMultipliers[_token];
        if (multiplier > 0) {
            amount = _units / uint256(multiplier);
        } else {
            amount = _units * uint256(-multiplier);
        }
    }

    /// @notice Check if a Hypercert belongs to the correct Hypercert type
    /// @param _fractionId id of the Hypercert fraction
    function _isFraction(uint256 _fractionId) internal view returns (bool) {
        return _fractionId & TYPE_MASK == hypercertTypeId;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     * Keeping a total of 30 slots available.
     */
    uint256[23] private __gap;
}
