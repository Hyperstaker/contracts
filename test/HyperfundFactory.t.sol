// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "../src/HyperfundFactory.sol";
import "../src/Hyperfund.sol";
import "../src/Hyperstaker.sol";
import {IHypercertToken} from "../src/interfaces/IHypercertToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockHyperfundFactoryV2} from "./mocks/MockHyperfundFactoryV2.sol";
import {MockHyperminter} from "./mocks/MockHyperminter.sol";
import {console} from "forge-std/console.sol";

contract HyperfundFactoryTest is Test {
    HyperfundFactory implementation;
    HyperfundFactory hyperfundFactory;
    Hyperfund hyperfund;
    Hyperstaker hyperstaker;

    address public hypercertMinter;
    uint256 hypercertId;
    address manager;
    uint256 public totalUnits = 100000000;

    event Upgraded(address indexed implementation);

    function setUp() public {
        // Deploy implementation
        implementation = new HyperfundFactory();

        // hypercertminter address in Sepolia
        hypercertMinter = 0xa16DFb32Eb140a6f3F2AC68f41dAd8c7e83C4941;

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(HyperfundFactory.initialize.selector, hypercertMinter);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Get factory instance
        hyperfundFactory = HyperfundFactory(address(proxy));

        manager = address(this);
        // hypercertId = HT(hypercertMinter).mintClaim(
        //     address(this), totalUnits, "uri", HT.TransferRestrictions.AllowAll
        // );
        vm.recordLogs();
        IHypercertToken(hypercertMinter).mintClaim(
            address(this), totalUnits, "uri", IHypercertToken.TransferRestrictions.AllowAll
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();

        hypercertId = uint256(entries[0].topics[1]);
        console.log(hypercertId);
    }

    function test_InitialOwnership() public view {
        assertEq(hyperfundFactory.owner(), address(this));
    }

    function test_CannotInitializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        hyperfundFactory.initialize(hypercertMinter);
    }

    function test_RevertWhen_initializeWithInvalidHypercertMinter() public {
        // Deploy implementation
        implementation = new HyperfundFactory();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(HyperfundFactory.initialize.selector, address(0));

        vm.expectRevert(HyperfundFactory.InvalidAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_CannotUpgradeFromNonOwner() public {
        MockHyperfundFactoryV2 newImplementation = new MockHyperfundFactoryV2();

        address user = makeAddr("user");
        vm.prank(user);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        hyperfundFactory.upgradeToAndCall(address(newImplementation), "");
    }

    function test_SuccessfulUpgrade() public {
        MockHyperfundFactoryV2 newImplementation = new MockHyperfundFactoryV2();

        vm.expectEmit(true, false, false, false);
        emit Upgraded(address(newImplementation));

        hyperfundFactory.upgradeToAndCall(address(newImplementation), "");

        // Cast to V2 to test new functionality
        MockHyperfundFactoryV2 upgradedFactory = MockHyperfundFactoryV2(address(hyperfundFactory));
        assertEq(upgradedFactory.version(), 2);
    }

    function test_CreateHyperfund() public {
        // Expect the event with specific parameters
        vm.expectEmit(false, true, false, true);
        // We can't know the hyperfund address beforehand, but we can emit a dummy event
        // with the other parameters we expect
        emit HyperfundFactory.HyperfundCreated(address(0), manager, hypercertId);

        address hyperfundAddress = hyperfundFactory.createHyperfund(hypercertId, manager);

        bool createdHyperfund = hyperfundFactory.hyperfunds(hypercertId);
        assertTrue(createdHyperfund != false, "Hyperfund should be created and mapped correctly");
        assertEq(Hyperfund(hyperfundAddress).hypercertTypeId(), hypercertId);
    }

    function test_CreateHyperstaker() public {
        // Expect the event with specific parameters
        vm.expectEmit(false, true, false, true);
        // We can't know the hyperfund address beforehand, but we can emit a dummy event
        // with the other parameters we expect
        emit HyperfundFactory.HyperstakerCreated(address(0), manager, hypercertId);

        address hyperstakerAddress = hyperfundFactory.createHyperstaker(hypercertId, manager);

        bool createdHyperstaker = hyperfundFactory.hyperstakers(hypercertId);
        assertTrue(createdHyperstaker != false, "Hyperstaker should be created and mapped correctly");
        assertEq(Hyperstaker(hyperstakerAddress).hypercertTypeId(), hypercertId);
    }

    function test_RevertWhen_RedeployingHyperfundWithSameHypercertId() public {
        hyperfundFactory.createHyperfund(hypercertId, manager);

        vm.expectRevert(HyperfundFactory.AlreadyDeployed.selector);
        hyperfundFactory.createHyperfund(hypercertId, manager);
    }

    function test_RevertWhen_RedeployingHyperStakerWithSameHypercertId() public {
        hyperfundFactory.createHyperstaker(hypercertId, manager);

        vm.expectRevert(HyperfundFactory.AlreadyDeployed.selector);
        hyperfundFactory.createHyperstaker(hypercertId, manager);
    }

    function test_RevertWhen_CreateHyperfundZeroManager() public {
        vm.expectRevert(HyperfundFactory.InvalidAddress.selector);
        hyperfundFactory.createHyperfund(hypercertId, address(0));
    }

    function test_RevertWhen_CreateHyperstakerZeroManager() public {
        vm.expectRevert(HyperfundFactory.InvalidAddress.selector);
        hyperfundFactory.createHyperstaker(hypercertId, address(0));
    }

    function test_RevertWhen_FailedHyperfundDeployment() public {
        // Deploy implementation
        implementation = new HyperfundFactory();

        // replace hypercertMinter with random address
        hypercertMinter = address(new MockHyperminter());

        // Mock the ownerOf call to return our test address
        vm.mockCall(
            address(hypercertMinter),
            abi.encodeWithSelector(IHypercertToken.ownerOf.selector, hypercertId + 1),
            abi.encode(address(this))
        );

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(HyperfundFactory.initialize.selector, hypercertMinter);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Get factory instance
        HyperfundFactory factory = HyperfundFactory(address(proxy));

        vm.expectRevert();
        factory.createHyperfund(hypercertId, manager);
    }

    function test_RevertWhen_FailedHyperstakerDeployment() public {
        // Deploy implementation
        implementation = new HyperfundFactory();

        // replace hypercertMinter with random address
        hypercertMinter = address(new MockHyperminter());

        // Mock the ownerOf call to return our test address
        vm.mockCall(
            address(hypercertMinter),
            abi.encodeWithSelector(IHypercertToken.ownerOf.selector, hypercertId + 1),
            abi.encode(address(this))
        );

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(HyperfundFactory.initialize.selector, hypercertMinter);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Get factory instance
        HyperfundFactory factory = HyperfundFactory(address(proxy));

        vm.expectRevert();
        factory.createHyperstaker(hypercertId, manager);
    }

    function test_RevertWhen_HyperfundCreatorNotOwnerOfHypercert() public {
        vm.prank(makeAddr("user2"));
        vm.expectRevert(HyperfundFactory.NotOwnerOfHypercert.selector);
        hyperfundFactory.createHyperfund(hypercertId, manager);
    }

    function test_RevertWhen_HyperstakerCreatorNotOwnerOfHypercert() public {
        vm.prank(makeAddr("user2"));
        vm.expectRevert(HyperfundFactory.NotOwnerOfHypercert.selector);
        hyperfundFactory.createHyperstaker(hypercertId, manager);
    }

    function test_CreateProject() public {
        (address hyperfundAddress, address hyperstakerAddress) = hyperfundFactory.createProject(hypercertId, manager);
        assertTrue(hyperfundFactory.hyperfunds(hypercertId));
        assertTrue(hyperfundFactory.hyperstakers(hypercertId));
        assertEq(Hyperfund(hyperfundAddress).hypercertTypeId(), hypercertId);
        assertEq(Hyperstaker(hyperstakerAddress).hypercertTypeId(), hypercertId);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }
}
