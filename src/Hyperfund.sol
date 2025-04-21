// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHypercertToken} from "./interfaces/IHypercertToken.sol";
import {HyperfundStorage} from "./HyperfundStorage.sol";

contract Hyperfund is AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    // immutable values that are read from the HyperfundStorage
    IHypercertToken public hypercertMinter;
    uint256 public hypercertId;
    uint256 public hypercertTypeId;
    uint256 public hypercertUnits;

    // erc20 token allowlist, 0 means the token is not allowed
    // negative multiplier means the total amount of hypercert units is smaller than the amount of tokens it represents and rounding is applied
    mapping(address token => int256 multiplier) public tokenMultipliers;

    // allowlist for non-financial contributions, 0 means the contributor is not allowed
    mapping(address contributor => uint256 units) public nonfinancialContributions;

    // keeps track of how many fractions have been split off the original hypercert
    // WARNING: if fractions are split outside of the hyperfund it would result in the hyperfund failing

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
    /// @notice NOTE: after deployment of proxy, the hypercert owner must approve the proxy contract to split and burn fractions
    /// by calling hypercertMinter.setApprovalForAll(address(proxy), true)
    /// @param _storage The immutable storage contract for this hyperfund
    /// @param _manager The address that will have the MANAGER_ROLE in the new Hyperfund, pausers and upgraders can be added later
    function initialize(address _storage, address _manager) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, _manager);

        HyperfundStorage storage_ = HyperfundStorage(_storage);
        hypercertMinter = IHypercertToken(storage_.hypercertMinter());
        hypercertTypeId = storage_.hypercertTypeId();
        hypercertId = hypercertTypeId + 1;
        hypercertUnits = storage_.hypercertUnits();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /// @notice set the multiplier for an allowlisted token, 0 means the token is not allowed
    /// @param _token address of the token
    /// @param _multiplier multiplier for the token, negative means the total amount of hypercert units is smaller
    /// than the amount of tokens it represents and rounding is applied
    function allowlistToken(address _token, int256 _multiplier) external onlyRole(MANAGER_ROLE) {
        tokenMultipliers[_token] = _multiplier;
        emit TokenAllowlisted(_token, _multiplier);
    }

    function withdrawFunds(address _token, uint256 _amount, address _to) external onlyRole(MANAGER_ROLE) {
        if (_token == address(0)) {
            payable(_to).transfer(_amount);
        } else {
            require(IERC20(_token).transfer(_to, _amount), TransferFailed());
        }
        emit FundsWithdrawn(_token, _amount, _to);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice send funds to the hyperfund and receive a hypercert fraction
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

    function nonfinancialContribution(address _contributor, uint256 _units)
        external
        whenNotPaused
        onlyRole(MANAGER_ROLE)
    {
        uint256 availableSupply = hypercertMinter.unitsOf(hypercertId);
        require(availableSupply >= _units, AmountExceedsAvailableSupply(availableSupply));
        _nonfinancialContribution(_contributor, _units);
    }

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

    /// @notice redeem a hypercert fraction for the corresponding amount of tokens
    /// NOTE: sender must first approve the hyperfund to burn the hypercert fraction, by calling hypercertMinter.setApprovalForAll(address(this), true)
    /// @param _fractionId id of the hypercert fraction
    /// @param _token address of the token to redeem, must be allowlisted. address(0) for native token
    function redeem(uint256 _fractionId, address _token) external whenNotPaused {
        require(nonfinancialContributions[msg.sender] != 0, NotAllowlisted());
        require(hypercertMinter.ownerOf(_fractionId) == msg.sender, Unauthorized());
        require(_isFraction(_fractionId), NotFractionOfThisHypercert(hypercertTypeId));
        uint256 units = hypercertMinter.unitsOf(_fractionId);
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

    function _nonfinancialContribution(address _contributor, uint256 _units) internal {
        require(_contributor != address(0), InvalidAddress());
        require(_units != 0, InvalidAmount());
        nonfinancialContributions[_contributor] += _units;
        _mintFraction(_contributor, _units);
        emit NonfinancialContribution(_contributor, _units);
    }

    function _mintFraction(address account, uint256 units) internal {
        uint256[] memory newallocations = new uint256[](2);
        newallocations[0] = hypercertMinter.unitsOf(hypercertId) - units;
        newallocations[1] = units;
        hypercertMinter.splitFraction(account, hypercertId, newallocations);
    }

    function _tokenAmountToUnits(address _token, uint256 _amount) internal view returns (uint256 units) {
        int256 multiplier = tokenMultipliers[_token];
        if (multiplier > 0) {
            units = _amount * uint256(multiplier);
        } else {
            units = _amount / uint256(-multiplier);
        }
    }

    function _unitsToTokenAmount(address _token, uint256 _units) internal view returns (uint256 amount) {
        int256 multiplier = tokenMultipliers[_token];
        if (multiplier > 0) {
            amount = _units / uint256(multiplier);
        } else {
            amount = _units * uint256(-multiplier);
        }
    }

    function _isFraction(uint256 _fractionId) internal view returns (bool) {
        return _fractionId & TYPE_MASK == hypercertTypeId;
    }
}
