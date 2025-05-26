// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHypercertToken} from "./interfaces/IHypercertToken.sol";

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
    // immutable values that are set on initialization
    IHypercertToken public hypercertMinter;
    uint256 public hypercertTypeId;
    uint256 public totalUnits;
     address public feeRecipient;
    /// @notice fee percentage, 10000 = 100%
    uint256 public feePercentage;

    mapping(uint256 hypercertId => Stake stake) public stakes;
    Round[] public rounds;

    uint256 internal constant TYPE_MASK = type(uint256).max << 128;

    // Roles
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

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

    modifier onlyStaker(uint256 _hypercertId) {
        require(stakes[_hypercertId].stakingStartTime != 0, NotStaked());
        address staker = stakes[_hypercertId].staker;
        require(staker == msg.sender, NotStakerOfHypercert(staker));
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract, to be called by proxy
    /// @notice NOTE: after deployment of proxy, the hypercert owner must approve the proxy contract to handle fractions
    /// by calling hypercertMinter.setApprovalForAll(address(proxy), true)
    /// @param _hypercertMinter The address of the hypercert minter contract
    /// @param _hypercertTypeId The id of the hypercert type
    /// @param _admin The address that will have the DEFAULT_ADMIN_ROLE
    /// @param _manager The address that will have the MANAGER_ROLE
    /// @param _pauser The address that will have the PAUSER_ROLE
    /// @param _upgrader The address that will have the UPGRADER_ROLE
    /// @param _feeRecipient The address that will receive the fees on rewards
    /// @param _feePercentage The percentage of the reward that will be sent to the fee recipient
    function initialize(
        address _hypercertMinter,
        uint256 _hypercertTypeId,
        address _admin,
        address _manager,
        address _pauser,
        address _upgrader,
        address _feeRecipient,
        uint256 _feePercentage
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
        totalUnits = hypercertMinter.unitsOf(_hypercertTypeId + 1);
        Round memory round;
        round.startTime = block.timestamp;
        rounds.push(round);
        feeRecipient = _feeRecipient;
        feePercentage = _feePercentage;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ADMIN FUNCTIONS

    /// @notice Set the reward for the current round, this ends the current round and starts a new one. Only callable
    /// by a manager
    /// @param _rewardToken address of the reward token
    /// @param _rewardAmount amount of the reward for the current round
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

    /// @notice Pause the contract, only callable by a pauser
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause the contract, only callable by a pauser
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // USER FUNCTIONS

    /// @notice Stake a Hypercert, this will transfer the Hypercert from the owner to the contract
    /// @param _hypercertId id of the Hypercert to stake
    function stake(uint256 _hypercertId) external whenNotPaused {
        require(hypercertMinter.unitsOf(_hypercertId) != 0, NoUnitsInHypercert());
        uint256 hypercertTypeId_ = _getHypercertTypeId(_hypercertId);
        require(hypercertTypeId_ == hypercertTypeId, WrongHypercertType(hypercertTypeId_, hypercertTypeId));

        stakes[_hypercertId].stakingStartTime = block.timestamp;
        stakes[_hypercertId].staker = msg.sender;
        emit Staked(_hypercertId);
        hypercertMinter.safeTransferFrom(msg.sender, address(this), _hypercertId, 1, "");
    }

    /// @notice Unstake a Hypercert, this will transfer the Hypercert from the contract to the user and delete all
    /// stake information
    /// @param _hypercertId id of the Hypercert to unstake
    function unstake(uint256 _hypercertId) public whenNotPaused onlyStaker(_hypercertId) {
        _unstake(_hypercertId);
    }

    /// @notice Claim a reward eligable by a staked Hypercert for a given round
    /// @param _hypercertId id of the Hypercert to claim the reward for
    /// @param _roundId id of the round to claim the reward for
    function claimReward(uint256 _hypercertId, uint256 _roundId) external whenNotPaused onlyStaker(_hypercertId) {
        require(!isRoundClaimed(_hypercertId, _roundId), AlreadyClaimed());
        uint256 reward = _calculateReward(_hypercertId, _roundId);
        require(reward != 0, NoRewardAvailable());

        _claimReward(_hypercertId, _roundId, reward);
    }

    /// @notice Claim all rewards available for a staked Hypercert and unstake it
    /// @param _hypercertId id of the Hypercert to claim all rewards and unstake
    function claimAndUnstake(uint256 _hypercertId) external whenNotPaused onlyStaker(_hypercertId) {
        for (uint256 i = 0; i < rounds.length - 1; i++) {
            uint256 reward = calculateReward(_hypercertId, i);
            if (reward != 0) {
                _claimReward(_hypercertId, i, reward);
            }
        }
        unstake(_hypercertId);
    }

    // VIEW FUNCTIONS

    /// @notice Calculate the reward for a staked Hypercert for a given round
    /// @param _hypercertId id of the Hypercert to calculate the reward for
    /// @param _roundId id of the round to calculate the reward for
    /// @return amount of the reward eligable for the staked Hypercert for the given round
    function calculateReward(uint256 _hypercertId, uint256 _roundId) public view returns (uint256) {
        require(stakes[_hypercertId].stakingStartTime != 0, NotStaked());
        if (isRoundClaimed(_hypercertId, _roundId)) {
            return 0;
        }
        return _calculateReward(_hypercertId, _roundId);
    }

    /// @notice Check if a staked Hypercert had already claimed a reward for a given round
    /// @param _hypercertId id of the Hypercert to check
    /// @param _roundId id of the round to check
    /// @return true if the staked Hypercert had claimed a reward for the given round, false otherwise
    function isRoundClaimed(uint256 _hypercertId, uint256 _roundId) public view returns (bool) {
        return (stakes[_hypercertId].claimed & (1 << _roundId)) != 0;
    }

    /// @notice Get the stake information for a staked Hypercert
    /// @param _hypercertId id of the Hypercert to get the stake information for
    /// @return stake information for the staked Hypercert (staking start time, staker address, claimed rounds bitmap)
    function getStakeInfo(uint256 _hypercertId) external view returns (Stake memory) {
        return stakes[_hypercertId];
    }

    /// @notice Get the round information for a given round
    /// @param _roundId id of the round to get the information for
    /// @return round information for the given round (start time, end time, duration, total rewards, reward token)
    function getRoundInfo(uint256 _roundId) external view returns (Round memory) {
        return rounds[_roundId];
    }

    // INTERNAL FUNCTIONS

    /// @notice Calculate the reward for a staked Hypercert for a given round
    /// @param _hypercertId id of the Hypercert to calculate the reward for
    /// @param _roundId id of the round to calculate the reward for
    /// @return amount of the reward eligable for the staked Hypercert for the given round
    function _calculateReward(uint256 _hypercertId, uint256 _roundId) internal view returns (uint256) {
        Round memory round = rounds[_roundId];
        require(round.endTime != 0, RoundNotSet());
        uint256 stakeStartTime = stakes[_hypercertId].stakingStartTime;
        stakeStartTime = stakeStartTime < round.startTime ? round.startTime : stakeStartTime;
        uint256 stakeDuration = stakeStartTime > round.endTime ? 0 : round.endTime - stakeStartTime;
        return
            round.totalRewards * hypercertMinter.unitsOf(_hypercertId) * stakeDuration / (totalUnits * round.duration);
    }

    /// @notice Unstake a Hypercert, this will transfer the Hypercert from the contract to the user and delete all
    /// stake information
    /// @param _hypercertId id of the Hypercert to unstake
    function _unstake(uint256 _hypercertId) internal {
        delete stakes[_hypercertId];
        emit Unstaked(_hypercertId);
        hypercertMinter.safeTransferFrom(address(this), msg.sender, _hypercertId, 1, "");
    }

    /// @notice Set a round as claimed for a staked Hypercert and transfer the reward to the user
    /// @param _hypercertId id of the Hypercert to claim the reward for
    /// @param _roundId id of the round to claim the reward for
    /// @param _reward amount of the reward to claim
    function _claimReward(uint256 _hypercertId, uint256 _roundId, uint256 _reward) internal {
        _setRoundClaimed(_hypercertId, _roundId);
        emit RewardClaimed(_hypercertId, _reward);

        address rewardToken = rounds[_roundId].rewardToken;
        if (rewardToken != address(0)) {
            require(IERC20(rewardToken).transfer(msg.sender, _reward), RewardTransferFailed());
        } else {
            (bool success,) = payable(msg.sender).call{value: _reward}("");
            require(success, NativeTokenTransferFailed());
        }
    }

    /// @notice Get the hypercert type id for a given hypercert id
    /// @param _hypercertId id of the Hypercert to get the type id for
    /// @return hypercert type id for the given hypercert id
    function _getHypercertTypeId(uint256 _hypercertId) internal pure returns (uint256) {
        return _hypercertId & TYPE_MASK;
    }

    /// @notice Set a round as claimed for a staked Hypercert
    /// @param _hypercertId id of the Hypercert to set the round as claimed for
    /// @param _roundId id of the round to set as claimed
    function _setRoundClaimed(uint256 _hypercertId, uint256 _roundId) internal {
        stakes[_hypercertId].claimed |= (1 << _roundId);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     * Keeping a total of 30 slots available.
     */
    uint256[24] private __gap;
}
