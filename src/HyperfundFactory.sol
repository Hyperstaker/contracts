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

    // Mapping to associate (hypercert ID) with Hyperfund and Hyperstaker addresses
    mapping(uint256 => bool) public hyperfunds;
    mapping(uint256 => bool) public hyperstakers;

    error InvalidAddress();
    error DeploymentFailed();
    error AlreadyDeployed();
    error NotOwnerOfHypercert();

    // Event to emit when a new Hyperfund is created
    event HyperfundCreated(address indexed hyperfundAddress, address indexed manager, uint256 hypercertId);

    // Event to emit when a new Hyperstaker is created
    event HyperstakerCreated(address indexed hyperstakerAddress, address indexed manager, uint256 hypercertId);

    /// @custom:oz-upgrades-unsafe-allow constructor
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

    // Function to create a new Hyperfund
    function createHyperfund(uint256 hypercertTypeId, address manager) external returns (address) {
        require(manager != address(0), InvalidAddress());
        require(hyperfunds[hypercertTypeId] == false, AlreadyDeployed());
        require(msg.sender == IHypercertToken(hypercertMinter).ownerOf(hypercertTypeId + 1), NotOwnerOfHypercert());

        HyperfundStorage hyperfundStorage = new HyperfundStorage(address(hypercertMinter), hypercertTypeId + 1);
        Hyperfund implementation = new Hyperfund();
        bytes memory initData =
            abi.encodeWithSelector(Hyperfund.initialize.selector, address(hyperfundStorage), manager, 1);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        IHypercertToken(hypercertMinter).setApprovalForAll(address(proxy), true);
        address newHyperfund = address(proxy);
        require(newHyperfund != address(0), DeploymentFailed());

        hyperfunds[hypercertTypeId] = true;
        emit HyperfundCreated(newHyperfund, manager, hypercertTypeId);
        return newHyperfund;
    }

    // Function to create a new Hyperstaker
    function createHyperstaker(uint256 hypercertTypeId, address manager) external returns (address) {
        require(manager != address(0), InvalidAddress());
        require(hyperstakers[hypercertTypeId] == false, AlreadyDeployed());
        require(msg.sender == IHypercertToken(hypercertMinter).ownerOf(hypercertTypeId + 1), NotOwnerOfHypercert());

        HyperfundStorage hyperfundStorage = new HyperfundStorage(address(hypercertMinter), hypercertTypeId);
        Hyperstaker implementation = new Hyperstaker();
        bytes memory initData =
            abi.encodeWithSelector(Hyperstaker.initialize.selector, address(hyperfundStorage), manager);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        address newHyperstaker = address(proxy);
        require(newHyperstaker != address(0), DeploymentFailed());

        hyperstakers[hypercertTypeId] = true;
        emit HyperstakerCreated(newHyperstaker, manager, hypercertTypeId);
        return newHyperstaker;
    }
}
