// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./Hyperfund.sol"; // Import Hyperfund contract
import "./Hyperstaker.sol"; // Import Hyperstaker contract
import {IHypercertToken} from "./interfaces/IHypercertToken.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract HyperfundFactory is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    address hypercertMinter;

    // Mapping to associate (hypercert ID) with flag for Hyperfund and Hyperstaker created
    mapping(uint256 => bool) public hyperfunds;
    mapping(uint256 => bool) public hyperstakers;

    error InvalidAddress();
    error DeploymentFailed();
    error AlreadyDeployed();
    error NotOwnerOfHypercert();

    event HyperfundCreated(
        address indexed hyperfundAddress,
        uint256 indexed hypercertId,
        address admin,
        address manager,
        address pauser,
        address upgrader,
        address feeRecipient,
        uint256 feePercentage
    );

    event HyperstakerCreated(
        address indexed hyperstakerAddress,
        uint256 indexed hypercertId,
        address admin,
        address manager,
        address pauser,
        address upgrader,
        address feeRecipient,
        uint256 feePercentage
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(address _hypercertMinter) public initializer {
        require(_hypercertMinter != address(0), InvalidAddress());
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        hypercertMinter = _hypercertMinter;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Create a new Hyperfund
    /// @param hypercertTypeId id of the Hypercert type to create the Hyperfund for
    /// @param admin address of the admin of the Hyperfund
    /// @param manager address of the manager of the Hyperfund
    /// @param pauser address of the pauser of the Hyperfund
    /// @param upgrader address of the upgrader of the Hyperfund
    /// @return address of the new Hyperfund
    function createHyperfund(uint256 hypercertTypeId, address admin, address manager, address pauser, address upgrader, address feeRecipient, uint256 feePercentage)
        external
        returns (address)
    {
        require(manager != address(0), InvalidAddress());
        require(hyperfunds[hypercertTypeId] == false, AlreadyDeployed());
        require(msg.sender == IHypercertToken(hypercertMinter).ownerOf(hypercertTypeId + 1), NotOwnerOfHypercert());

        Hyperfund implementation = new Hyperfund();
        bytes memory initData = abi.encodeWithSelector(
            Hyperfund.initialize.selector, address(hypercertMinter), hypercertTypeId, admin, manager, pauser, upgrader, feeRecipient, feePercentage
        );

        address newHyperfund = _deployContract(address(implementation), initData);
        IHypercertToken(hypercertMinter).setApprovalForAll(newHyperfund, true);
        
        hyperfunds[hypercertTypeId] = true;
        emit HyperfundCreated(newHyperfund, hypercertTypeId, admin, manager, pauser, upgrader, feeRecipient, feePercentage);
        return newHyperfund;
    }

    /// @notice Create a new Hyperstaker
    /// @param hypercertTypeId id of the Hypercert type to create the Hyperstaker for
    /// @param admin address of the admin of the Hyperstaker
    /// @param manager address of the manager of the Hyperstaker
    /// @param pauser address of the pauser of the Hyperstaker
    /// @param upgrader address of the upgrader of the Hyperstaker
    /// @return address of the new Hyperstaker
    function createHyperstaker(
        uint256 hypercertTypeId,
        address admin,
        address manager,
        address pauser,
        address upgrader,
        address feeRecipient,
        uint256 feePercentage
    ) external returns (address) {
        require(manager != address(0), InvalidAddress());
        require(hyperstakers[hypercertTypeId] == false, AlreadyDeployed());
        require(msg.sender == IHypercertToken(hypercertMinter).ownerOf(hypercertTypeId + 1), NotOwnerOfHypercert());

        Hyperstaker implementation = new Hyperstaker();
        bytes memory initData = abi.encodeWithSelector(
            Hyperstaker.initialize.selector, address(hypercertMinter), hypercertTypeId, admin, manager, pauser, upgrader, feeRecipient, feePercentage
        );

        address newHyperstaker = _deployContract(address(implementation), initData);
        
        hyperstakers[hypercertTypeId] = true;
        emit HyperstakerCreated(newHyperstaker, hypercertTypeId, admin, manager, pauser, upgrader, feeRecipient, feePercentage);
        return newHyperstaker;
    }

    /// @notice Create a new Hyperfund and Hyperstaker
    /// @param hypercertTypeId id of the Hypercert type to create the Hyperfund and Hyperstaker for
    /// @param admin address of the admin of the Hyperfund and Hyperstaker
    /// @param manager address of the manager of the Hyperfund and Hyperstaker
    /// @param pauser address of the pauser of the Hyperfund and Hyperstaker
    /// @param upgrader address of the upgrader of the Hyperfund and Hyperstaker
    /// @return hyperfund address of the new Hyperfund
    /// @return hyperstaker address of the new Hyperstaker
    function createProject(uint256 hypercertTypeId, address admin, address manager, address pauser, address upgrader, address feeRecipient, uint256 feePercentage)
        external
        returns (address hyperfund, address hyperstaker)
    {
        require(manager != address(0), InvalidAddress());
        require(hyperfunds[hypercertTypeId] == false, AlreadyDeployed());
        require(msg.sender == IHypercertToken(hypercertMinter).ownerOf(hypercertTypeId + 1), NotOwnerOfHypercert());

        Hyperfund hyperfundImplementation = new Hyperfund();
        bytes memory initData = abi.encodeWithSelector(
            Hyperfund.initialize.selector, address(hypercertMinter), hypercertTypeId, admin, manager, pauser, upgrader, feeRecipient, feePercentage
        );

        hyperfund = _deployContract(address(hyperfundImplementation), initData);
        IHypercertToken(hypercertMinter).setApprovalForAll(hyperfund, true);
        hyperfunds[hypercertTypeId] = true;
        emit HyperfundCreated(hyperfund, hypercertTypeId, admin, manager, pauser, upgrader, feeRecipient, feePercentage);

        Hyperstaker hyperstakerImplementation = new Hyperstaker();
        hyperstaker = _deployContract(address(hyperstakerImplementation), initData);
        hyperstakers[hypercertTypeId] = true;
        emit HyperstakerCreated(hyperstaker, hypercertTypeId, admin, manager, pauser, upgrader, feeRecipient, feePercentage);
    }

    /// @notice Internal helper to create a new contract instance
    /// @param implementation The implementation contract address
    /// @param initData The initialization data for the contract
    /// @return The address of the newly created contract
    function _deployContract(address implementation, bytes memory initData) internal returns (address) {
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, initData);
        address newContract = address(proxy);
        require(newContract != address(0), DeploymentFailed());
        return newContract;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     * Keeping a total of 30 slots available.
     */
    uint256[26] private __gap;
}
