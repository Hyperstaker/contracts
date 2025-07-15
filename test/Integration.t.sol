    // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Hyperfund} from "../src/Hyperfund.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IHypercertToken} from "src/interfaces/IHypercertToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract IntegrationTest is Test {
    Hyperfund public hyperfund;
    ERC1967Proxy public proxy;
    Hyperfund public implementation;
    IHypercertToken public hypercertMinter;
    MockERC20 public fundingToken;
    uint256 public hypercertTypeId;
    uint256 public hypercertId;
    address public manager = makeAddr("manager");
    address public contributor = makeAddr("contributor");
    address public contributor2 = makeAddr("contributor2");
    address public contributor3 = makeAddr("contributor3");
    uint256 public totalUnits = 100000000;

    bytes32 public MANAGER_ROLE = keccak256("MANAGER_ROLE");

    function setUp() public {
        vm.recordLogs();

        // hypercertminter address in Sepolia
        hypercertMinter = IHypercertToken(0xa16DFb32Eb140a6f3F2AC68f41dAd8c7e83C4941);

        hypercertMinter.mintClaim(address(this), totalUnits, "uri", IHypercertToken.TransferRestrictions.AllowAll);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        hypercertTypeId = uint256(entries[0].topics[1]);
        hypercertId = hypercertTypeId + 1;
        fundingToken = new MockERC20("Funding", "FUND");
        implementation = new Hyperfund();
        bytes memory initData = abi.encodeWithSelector(
            Hyperfund.initialize.selector, address(hypercertMinter), hypercertTypeId, manager, manager, manager, manager
        );

        proxy = new ERC1967Proxy(address(implementation), initData);
        hypercertMinter.setApprovalForAll(address(proxy), true);
        hyperfund = Hyperfund(address(proxy));
    }

    /// @notice Tests a complete flow where:
    /// 1. Manager sets up USDC-like token with 200k USDCtotal value
    /// 2. Three contributors each get allocated 2500 USDC worth of units
    /// 3. Manager funds the contract with 7500 USDC
    /// 4. Contributors redeem their allocations
    /// 5. Process repeats 4 times, verifying accumulating balances
    function test_HyperfundRedeemFlow() public {
        uint256 usdcDecimals = 10 ** 6;
        int256 multiplier = int256(200000 * usdcDecimals / totalUnits) * -1; // hypercert represents 200000 usdc
        vm.prank(manager);
        hyperfund.allowlistToken(address(fundingToken), multiplier);

        fundingToken.mint(manager, 35000 * usdcDecimals); // manager has 35000 usdc

        address[] memory contributors = new address[](3);
        contributors[0] = contributor;
        contributors[1] = contributor2;
        contributors[2] = contributor3;
        uint256[] memory units = new uint256[](3);
        units[0] = 2500 * usdcDecimals / uint256(-multiplier);
        units[1] = 2500 * usdcDecimals / uint256(-multiplier);
        units[2] = 2500 * usdcDecimals / uint256(-multiplier);

        for (uint256 i = 0; i < 4; i++) {
            vm.startPrank(manager);
            hyperfund.nonFinancialContributions(contributors, units); // register 3 contributors with 2500 usdc each
            fundingToken.transfer(address(hyperfund), 7500 * usdcDecimals); // fund hyperfund with 7500 usdc
            vm.stopPrank();
            for (uint256 j = 0; j < 3; j++) {
                assertEq(hypercertMinter.ownerOf(hypercertId + i * 3 + j + 1), contributors[j]);
                assertEq(hypercertMinter.unitsOf(hypercertId + i * 3 + j + 1), units[j]);
                vm.startPrank(contributors[j]);
                hypercertMinter.setApprovalForAll(address(hyperfund), true);
                hyperfund.redeem(hypercertId + i * 3 + j + 1, address(fundingToken));
                vm.stopPrank();
                assertEq(hypercertMinter.ownerOf(hypercertId + i * 3 + j + 1), address(0));
                assertEq(hypercertMinter.unitsOf(hypercertId + i * 3 + j + 1), 0);
                assertEq(fundingToken.balanceOf(contributors[j]), 2500 * usdcDecimals * (i + 1));
            }
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }
}
