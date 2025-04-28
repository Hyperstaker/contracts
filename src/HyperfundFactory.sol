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

    // Event to emit when a new Hyperfund is created
    event HyperfundCreated(
        address indexed hyperfundAddress,
        uint256 indexed hypercertId,
        address admin,
        address manager,
        address pauser,
        address upgrader
    );

    // Event to emit when a new Hyperstaker is created
    event HyperstakerCreated(
        address indexed hyperstakerAddress,
        uint256 indexed hypercertId,
        address admin,
        address manager,
        address pauser,
        address upgrader
    );

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
    function createHyperfund(uint256 hypercertTypeId, address admin, address manager, address pauser, address upgrader)
        external
        returns (address)
    {
        require(manager != address(0), InvalidAddress());
        require(hyperfunds[hypercertTypeId] == false, AlreadyDeployed());
        require(msg.sender == IHypercertToken(hypercertMinter).ownerOf(hypercertTypeId + 1), NotOwnerOfHypercert());

        Hyperfund implementation = new Hyperfund();
        bytes memory initData = abi.encodeWithSelector(
            Hyperfund.initialize.selector, address(hypercertMinter), hypercertTypeId, admin, manager, pauser, upgrader
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        IHypercertToken(hypercertMinter).setApprovalForAll(address(proxy), true);
        address newHyperfund = address(proxy);
        require(newHyperfund != address(0), DeploymentFailed());

        hyperfunds[hypercertTypeId] = true;
        emit HyperfundCreated(newHyperfund, hypercertTypeId, admin, manager, pauser, upgrader);
        return newHyperfund;
    }

    // Function to create a new Hyperstaker
    function createHyperstaker(
        uint256 hypercertTypeId,
        address admin,
        address manager,
        address pauser,
        address upgrader
    ) external returns (address) {
        require(manager != address(0), InvalidAddress());
        require(hyperstakers[hypercertTypeId] == false, AlreadyDeployed());
        require(msg.sender == IHypercertToken(hypercertMinter).ownerOf(hypercertTypeId + 1), NotOwnerOfHypercert());

        Hyperstaker implementation = new Hyperstaker();
        bytes memory initData = abi.encodeWithSelector(
            Hyperstaker.initialize.selector, address(hypercertMinter), hypercertTypeId, admin, manager, pauser, upgrader
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        address newHyperstaker = address(proxy);
        require(newHyperstaker != address(0), DeploymentFailed());

        hyperstakers[hypercertTypeId] = true;
        emit HyperstakerCreated(newHyperstaker, hypercertTypeId, admin, manager, pauser, upgrader);
        return newHyperstaker;
    }

    function createProject(uint256 hypercertTypeId, address admin, address manager, address pauser, address upgrader)
        external
        returns (address hyperfund, address hyperstaker)
    {
        require(manager != address(0), InvalidAddress());
        require(hyperfunds[hypercertTypeId] == false, AlreadyDeployed());
        require(msg.sender == IHypercertToken(hypercertMinter).ownerOf(hypercertTypeId + 1), NotOwnerOfHypercert());

        bytes memory initData = abi.encodeWithSelector(
            Hyperfund.initialize.selector, address(hypercertMinter), hypercertTypeId, admin, manager, pauser, upgrader
        );

        Hyperfund hyperfundImplementation = new Hyperfund();
        ERC1967Proxy hyperfundProxy = new ERC1967Proxy(address(hyperfundImplementation), initData);
        hyperfund = address(hyperfundProxy);
        require(hyperfund != address(0), DeploymentFailed());
        hyperfunds[hypercertTypeId] = true;
        emit HyperfundCreated(hyperfund, hypercertTypeId, admin, manager, pauser, upgrader);

        Hyperstaker hyperstakerImplementation = new Hyperstaker();
        ERC1967Proxy proxy = new ERC1967Proxy(address(hyperstakerImplementation), initData);
        hyperstaker = address(proxy);
        require(hyperstaker != address(0), DeploymentFailed());
        hyperstakers[hypercertTypeId] = true;
        emit HyperstakerCreated(hyperstaker, hypercertTypeId, admin, manager, pauser, upgrader);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     * Keeping a total of 30 slots available.
     */
    uint256[26] private __gap;
}
