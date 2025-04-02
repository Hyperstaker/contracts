// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHypercertToken} from "./interfaces/IHypercertToken.sol";
import {HyperfundStorage} from "./HyperfundStorage.sol";

error NoUnitsInHypercert();
error WrongHypercertType(uint256 hypercertTypeId, uint256 expectedHypercertTypeId);
error NoRewardAvailable();
error NotStaked();
error RewardTransferFailed();
error NativeTokenTransferFailed();
error IncorrectRewardAmount(uint256 actualRewardAmount, uint256 expectedRewardAmount);
error NotStakerOfHypercert(address staker);
error RoundNotSet();
error AlreadyClaimed();

contract Hyperstaker is AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    uint256 internal constant TYPE_MASK = type(uint256).max << 128;

    IHypercertToken public hypercertMinter;
    uint256 public hypercertTypeId;
    uint256 public totalUnits;
    Round[] public rounds;

    // Roles
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Mapping of hypercert id to stake info
    mapping(uint256 => Stake) public stakes;

    struct Stake {
        uint256 stakingStartTime;
        address staker;
        uint256 claimed; // bitmap of claimed rounds, limits Hyperstaker to 256 rounds
    }

    struct Round {
        uint256 startTime;
        uint256 endTime;
        uint256 duration;
        uint256 totalRewards;
        address rewardToken;
    }

    event Staked(uint256 indexed hypercertId);
    event Unstaked(uint256 indexed hypercertId);
    event RewardClaimed(uint256 indexed hypercertId, uint256 reward);
    event RewardSet(address indexed token, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract, to be called by proxy
    /// @notice NOTE: after deployment of proxy, the hypercert owner must approve the proxy contract to handle fractions
    /// by calling hypercertMinter.setApprovalForAll(address(proxy), true)
    /// @param _storage The immutable storage contract for this hyperstaker
    /// @param _manager The address that will have the MANAGER_ROLE
    function initialize(address _storage, address _manager) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, _manager);

        HyperfundStorage storage_ = HyperfundStorage(_storage);
        hypercertMinter = IHypercertToken(storage_.hypercertMinter());
        hypercertTypeId = storage_.hypercertTypeId();
        totalUnits = storage_.hypercertUnits();
        Round memory round;
        round.startTime = block.timestamp;
        rounds.push(round);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function setReward(address _rewardToken, uint256 _rewardAmount) external payable onlyRole(MANAGER_ROLE) {
        Round storage currentRound = rounds[rounds.length - 1];
        currentRound.totalRewards = _rewardAmount;
        currentRound.rewardToken = _rewardToken;
        currentRound.endTime = block.timestamp;
        currentRound.duration = currentRound.endTime - currentRound.startTime;
        if (_rewardToken != address(0)) {
            bool success = IERC20(_rewardToken).transferFrom(msg.sender, address(this), _rewardAmount);
            require(success, RewardTransferFailed());
        } else {
            require(msg.value == _rewardAmount, IncorrectRewardAmount(msg.value, _rewardAmount));
        }
        Round memory nextRound;
        nextRound.startTime = block.timestamp;
        rounds.push(nextRound);
        emit RewardSet(_rewardToken, _rewardAmount);
    }

    function stake(uint256 _hypercertId) external whenNotPaused {
        require(hypercertMinter.unitsOf(_hypercertId) != 0, NoUnitsInHypercert());
        uint256 hypercertTypeId_ = _getHypercertTypeId(_hypercertId);
        require(hypercertTypeId_ == hypercertTypeId, WrongHypercertType(hypercertTypeId_, hypercertTypeId));

        stakes[_hypercertId].stakingStartTime = block.timestamp;
        stakes[_hypercertId].staker = msg.sender;
        emit Staked(_hypercertId);
        hypercertMinter.safeTransferFrom(msg.sender, address(this), _hypercertId, 1, "");
    }

    function unstake(uint256 _hypercertId) external whenNotPaused {
        require(stakes[_hypercertId].stakingStartTime != 0, NotStaked());
        address staker = stakes[_hypercertId].staker;
        require(staker == msg.sender, NotStakerOfHypercert(staker));
        delete stakes[_hypercertId];
        emit Unstaked(_hypercertId);
        hypercertMinter.safeTransferFrom(address(this), msg.sender, _hypercertId, 1, "");
    }

    function claimReward(uint256 _hypercertId, uint256 _roundId) external whenNotPaused {
        require(stakes[_hypercertId].stakingStartTime != 0, NotStaked());
        address staker = stakes[_hypercertId].staker;
        require(staker == msg.sender, NotStakerOfHypercert(staker));
        require(!isRoundClaimed(_hypercertId, _roundId), AlreadyClaimed());
        uint256 reward = calculateReward(_hypercertId, _roundId);
        require(reward != 0, NoRewardAvailable());

        _setRoundClaimed(_hypercertId, _roundId);
        emit RewardClaimed(_hypercertId, reward);

        address rewardToken = rounds[_roundId].rewardToken;
        if (rewardToken != address(0)) {
            require(IERC20(rewardToken).transfer(msg.sender, reward), RewardTransferFailed());
        } else {
            (bool success,) = payable(msg.sender).call{value: reward}("");
            require(success, NativeTokenTransferFailed());
        }
    }

    function calculateReward(uint256 _hypercertId, uint256 _roundId) public view returns (uint256) {
        Round memory round = rounds[_roundId];
        require(round.endTime != 0, RoundNotSet());
        uint256 stakeStartTime = stakes[_hypercertId].stakingStartTime;
        require(stakeStartTime != 0, NotStaked());
        stakeStartTime = stakeStartTime < round.startTime ? round.startTime : stakeStartTime;
        uint256 stakeDuration = stakeStartTime > round.endTime ? 0 : round.endTime - stakeStartTime;
        return
            round.totalRewards * hypercertMinter.unitsOf(_hypercertId) * stakeDuration / (totalUnits * round.duration);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function getStakeInfo(uint256 _hypercertId) external view returns (Stake memory) {
        return stakes[_hypercertId];
    }

    function getRoundInfo(uint256 _roundId) external view returns (Round memory) {
        return rounds[_roundId];
    }

    function _getHypercertTypeId(uint256 _hypercertId) internal pure returns (uint256) {
        return _hypercertId & TYPE_MASK;
    }

    function isRoundClaimed(uint256 _hypercertId, uint256 _roundId) public view returns (bool) {
        return (stakes[_hypercertId].claimed & (1 << _roundId)) != 0;
    }

    function _setRoundClaimed(uint256 _hypercertId, uint256 _roundId) internal {
        stakes[_hypercertId].claimed |= (1 << _roundId);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
}
