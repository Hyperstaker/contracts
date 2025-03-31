// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "../src/Hyperstaker.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IHypercertToken} from "../src/interfaces/IHypercertToken.sol";
import {HyperfundStorage} from "../src/HyperfundStorage.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract HyperstakerTest is Test {
    Hyperstaker public hyperstaker;
    ERC1967Proxy public proxy;
    Hyperstaker public implementation;
    IHypercertToken public hypercertMinter;
    HyperfundStorage public hyperstakerStorage;
    MockERC20 public rewardToken;
    uint256 public hypercertTypeId;
    uint256 public fractionHypercertId;
    uint256 public stakerHypercertId;
    address public manager = vm.addr(1);
    address public staker = vm.addr(2);
    address public staker2 = vm.addr(3);
    uint256 public totalUnits = 100000000;
    uint256 public stakeAmount = 10000;
    uint256 public rewardAmount = 10 ether;
    bytes32 public MANAGER_ROLE = keccak256("MANAGER_ROLE");
    uint256 public roundStartTime;

    function setUp() public {
        vm.recordLogs();

        // hypercertminter address in Sepolia
        hypercertMinter = IHypercertToken(0xa16DFb32Eb140a6f3F2AC68f41dAd8c7e83C4941);
        assertEq(keccak256(abi.encodePacked(hypercertMinter.name())), keccak256("HypercertMinter"));

        hypercertMinter.mintClaim(address(this), totalUnits, "uri", IHypercertToken.TransferRestrictions.AllowAll);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        hypercertTypeId = uint256(entries[0].topics[1]);
        fractionHypercertId = hypercertTypeId + 1;
        roundStartTime = block.timestamp;
        rewardToken = new MockERC20("Reward", "RWD");

        hyperstakerStorage = new HyperfundStorage(address(hypercertMinter), hypercertTypeId);
        implementation = new Hyperstaker();
        bytes memory initData =
            abi.encodeWithSelector(Hyperstaker.initialize.selector, address(hyperstakerStorage), manager);

        proxy = new ERC1967Proxy(address(implementation), initData);
        hypercertMinter.setApprovalForAll(address(proxy), true);
        hyperstaker = Hyperstaker(address(proxy));

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = totalUnits - stakeAmount;
        allocations[1] = stakeAmount;
        hypercertMinter.splitFraction(staker, fractionHypercertId, allocations);
        stakerHypercertId = fractionHypercertId + 1;
    }

    function test_Constructor() public view {
        assertEq(hyperstaker.hypercertTypeId(), hypercertTypeId);
        assertEq(address(hyperstaker.hypercertMinter()), address(hypercertMinter));
        assertEq(hyperstaker.totalUnits(), totalUnits);
        assertEq(hyperstaker.roundStartTime(), roundStartTime);
    }

    function test_SetReward_ERC20() public {
        rewardToken.mint(manager, rewardAmount);

        vm.startPrank(manager);
        rewardToken.approve(address(hyperstaker), rewardAmount);

        vm.expectEmit(true, false, false, true);
        emit Hyperstaker.RewardSet(address(rewardToken), rewardAmount);
        hyperstaker.setReward(address(rewardToken), rewardAmount);
        vm.stopPrank();

        assertEq(hyperstaker.rewardToken(), address(rewardToken));
        assertEq(hyperstaker.totalRewards(), rewardAmount);
        assertEq(hyperstaker.roundEndTime(), block.timestamp);
        assertEq(hyperstaker.roundDuration(), hyperstaker.roundEndTime() - hyperstaker.roundStartTime());
        assertEq(rewardToken.balanceOf(address(hyperstaker)), rewardAmount);
    }

    function test_SetReward_Eth() public {
        vm.deal(manager, rewardAmount);

        vm.prank(manager);
        vm.expectEmit(true, false, false, true);
        emit Hyperstaker.RewardSet(address(0), rewardAmount);
        hyperstaker.setReward{value: rewardAmount}(address(0), rewardAmount);

        assertEq(hyperstaker.rewardToken(), address(0));
        assertEq(hyperstaker.totalRewards(), rewardAmount);
        assertEq(hyperstaker.roundEndTime(), block.timestamp);
        assertEq(hyperstaker.roundDuration(), hyperstaker.roundEndTime() - hyperstaker.roundStartTime());
        assertEq(address(hyperstaker).balance, rewardAmount);
    }

    function test_RevertWhen_SetReward_EthInvalidAmount() public {
        vm.deal(manager, rewardAmount / 2);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IncorrectRewardAmount.selector, rewardAmount / 2, rewardAmount));
        hyperstaker.setReward{value: rewardAmount / 2}(address(0), rewardAmount);
    }

    function test_Stake() public {
        vm.startPrank(staker);
        hypercertMinter.setApprovalForAll(address(hyperstaker), true);
        vm.expectEmit(true, false, false, false);
        emit Hyperstaker.Staked(stakerHypercertId);
        hyperstaker.stake(stakerHypercertId);
        vm.stopPrank();

        Hyperstaker.Stake memory stakeInfo = hyperstaker.getStake(stakerHypercertId);
        assertEq(stakeInfo.staker, staker);
        assertEq(stakeInfo.isClaimed, false);
        assertEq(stakeInfo.stakingStartTime, block.timestamp);
        assertEq(hypercertMinter.unitsOf(stakerHypercertId), stakeAmount);
        assertEq(hypercertMinter.ownerOf(stakerHypercertId), address(hyperstaker));
    }

    function test_RevertWhen_StakeWrongHypercertType() public {
        vm.recordLogs();
        hypercertMinter.mintClaim(address(this), totalUnits, "uri", IHypercertToken.TransferRestrictions.AllowAll);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 wrongTypeId = uint256(entries[0].topics[1]);

        vm.startPrank(staker);
        hypercertMinter.setApprovalForAll(address(hyperstaker), true);
        vm.expectRevert(abi.encodeWithSelector(WrongHypercertType.selector, wrongTypeId, hypercertTypeId));
        hyperstaker.stake(wrongTypeId + 1);
        vm.stopPrank();
    }

    function test_RevertWhen_StakeNoUnits() public {
        vm.startPrank(staker);
        hypercertMinter.burnFraction(staker, stakerHypercertId);
        hypercertMinter.setApprovalForAll(address(hyperstaker), true);
        vm.expectRevert(NoUnitsInHypercert.selector);
        hyperstaker.stake(stakerHypercertId);
        vm.stopPrank();
    }

    function _setupStake() internal {
        vm.warp(block.timestamp + 60 * 60 * 24);
        vm.startPrank(staker);
        hypercertMinter.setApprovalForAll(address(hyperstaker), true);
        hyperstaker.stake(stakerHypercertId);
        vm.stopPrank();
    }

    function test_Unstake() public {
        _setupStake();
        vm.startPrank(staker);
        vm.expectEmit(true, false, false, false);
        emit Hyperstaker.Unstaked(stakerHypercertId);
        hyperstaker.unstake(stakerHypercertId);
        vm.stopPrank();
        Hyperstaker.Stake memory stakeInfo = hyperstaker.getStake(stakerHypercertId);
        assertEq(stakeInfo.staker, address(0));
        assertEq(stakeInfo.stakingStartTime, 0);
    }

    function test_RevertWhen_UnstakeNotStaked() public {
        vm.prank(staker);
        vm.expectRevert(NotStaked.selector);
        hyperstaker.unstake(stakerHypercertId);
    }

    function test_RevertWhen_UnstakeNotStaker() public {
        _setupStake();
        vm.prank(staker2);
        vm.expectRevert(abi.encodeWithSelector(NotStakerOfHypercert.selector, staker));
        hyperstaker.unstake(stakerHypercertId);
    }

    function _setupRewardEth() internal {
        vm.warp(block.timestamp + 60 * 60 * 24 * 7);
        vm.deal(manager, rewardAmount);
        vm.prank(manager);
        hyperstaker.setReward{value: rewardAmount}(address(0), rewardAmount);
    }

    function _setupRewardERC20() internal {
        vm.warp(block.timestamp + 60 * 60 * 24 * 7);
        rewardToken.mint(manager, rewardAmount);
        vm.startPrank(manager);
        rewardToken.approve(address(hyperstaker), rewardAmount);
        hyperstaker.setReward(address(rewardToken), rewardAmount);
        vm.stopPrank();
    }

    function test_CalculateReward() public {
        _setupStake();
        _setupRewardEth();
        vm.warp(block.timestamp + 60 * 60 * 24);
        uint256 expectedReward = hyperstaker.calculateReward(stakerHypercertId);
        assertTrue(expectedReward > 0);
        Hyperstaker.Stake memory stakeInfo = hyperstaker.getStake(stakerHypercertId);
        uint256 stakeDuration = hyperstaker.roundEndTime() - stakeInfo.stakingStartTime;
        assertEq(expectedReward, rewardAmount * stakeAmount * stakeDuration / totalUnits / hyperstaker.roundDuration());
    }

    function test_CalculateReward_0WhenStakeAfterRoundEnd() public {
        _setupRewardEth();
        _setupStake();

        assertEq(hyperstaker.calculateReward(stakerHypercertId), 0);
    }

    function test_RevertWhen_CalculateRewardNoReward() public {
        _setupStake();
        vm.expectRevert(RoundNotSet.selector);
        hyperstaker.calculateReward(stakerHypercertId);
    }

    function test_RevertWhen_CalculateRewardNotStaked() public {
        _setupRewardEth();
        vm.expectRevert(NotStaked.selector);
        hyperstaker.calculateReward(stakerHypercertId);
    }

    function _checkClaimReward() internal returns (uint256 expectedReward) {
        expectedReward = hyperstaker.calculateReward(stakerHypercertId);
        vm.startPrank(staker);
        vm.expectEmit(true, false, false, true);
        emit Hyperstaker.RewardClaimed(stakerHypercertId, expectedReward);
        hyperstaker.claimReward(stakerHypercertId);
        vm.stopPrank();
        Hyperstaker.Stake memory stakeInfo = hyperstaker.getStake(stakerHypercertId);
        assertEq(stakeInfo.isClaimed, true);
        assertEq(hypercertMinter.ownerOf(stakerHypercertId), staker);
    }

    function test_ClaimReward_Eth() public {
        _setupStake();
        _setupRewardEth();

        uint256 initialBalance = staker.balance;
        uint256 expectedReward = _checkClaimReward();
        assertEq(staker.balance - initialBalance, expectedReward);
    }

    function test_ClaimReward_ERC20() public {
        _setupStake();
        _setupRewardERC20();

        uint256 initialBalance = rewardToken.balanceOf(staker);
        uint256 expectedReward = _checkClaimReward();
        assertEq(rewardToken.balanceOf(staker) - initialBalance, expectedReward);
    }

    function test_RevertWhen_ClaimRewardAlreadyClaimed() public {
        test_ClaimReward_Eth();
        vm.prank(staker);
        vm.expectRevert(AlreadyClaimed.selector);
        hyperstaker.claimReward(stakerHypercertId);
    }

    function test_RevertWhen_ClaimRewardRoundNotSet() public {
        _setupStake();
        vm.prank(staker);
        vm.expectRevert(RoundNotSet.selector);
        hyperstaker.claimReward(stakerHypercertId);
    }

    function test_RevertWhen_ClaimRewardNotStaker() public {
        _setupStake();
        _setupRewardEth();
        vm.prank(staker2);
        vm.expectRevert(abi.encodeWithSelector(NotStakerOfHypercert.selector, staker));
        hyperstaker.claimReward(stakerHypercertId);
    }

    function test_RevertWhen_ClaimRewardNoReward() public {
        _setupRewardEth();
        _setupStake();
        assertEq(0, hyperstaker.calculateReward(stakerHypercertId));
        vm.prank(staker);
        vm.expectRevert(NoRewardAvailable.selector);
        hyperstaker.claimReward(stakerHypercertId);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }
}
