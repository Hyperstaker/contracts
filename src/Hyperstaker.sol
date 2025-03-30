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
error AlreadyClaimed();
error NotStaked();
error RewardTransferFailed();
error NativeTokenTransferFailed();
error IncorrectRewardAmount(uint256 actualRewardAmount, uint256 expectedRewardAmount);

contract Hyperstaker is AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    uint256 internal constant TYPE_MASK = type(uint256).max << 128;

    IHypercertToken public hypercertMinter;
    uint256 public hypercertTypeId;
    uint256 public totalUnits;
    address public rewardToken;
    uint256 public totalRewards;
    uint256 public roundStartTime;
    uint256 public roundEndTime;
    uint256 public roundDuration;

    // Roles
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Mapping of hypercert id to stake info
    mapping(uint256 => Stake) public stakes;

    struct Stake {
        bool isClaimed;
        uint256 stakingStartTime;
    }

    event Staked(uint256 indexed hypercertId);
    event Unstaked(uint256 indexed hypercertId);
    event RewardClaimed(address indexed user, uint256 reward);
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
        roundStartTime = block.timestamp;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function setReward(address _rewardToken, uint256 _rewardAmount) external payable onlyRole(MANAGER_ROLE) {
        totalRewards = _rewardAmount;
        rewardToken = _rewardToken;
        roundEndTime = block.timestamp;
        roundDuration = roundEndTime - roundStartTime;
        if (_rewardToken != address(0)) {
            bool success = IERC20(_rewardToken).transferFrom(msg.sender, address(this), _rewardAmount);
            require(success, RewardTransferFailed());
        } else {
            require(msg.value == _rewardAmount, IncorrectRewardAmount(msg.value, _rewardAmount));
        }
        emit RewardSet(_rewardToken, _rewardAmount);
    }

    function stake(uint256 _hypercertId) external whenNotPaused {
        uint256 units = hypercertMinter.unitsOf(_hypercertId);
        require(units > 0, NoUnitsInHypercert());
        require(_getHypercertTypeId(_hypercertId) == hypercertTypeId, WrongHypercertType(_hypercertId, hypercertTypeId));

        stakes[_hypercertId].stakingStartTime = block.timestamp;
        emit Staked(_hypercertId);
        hypercertMinter.safeTransferFrom(msg.sender, address(this), _hypercertId, units, "");
    }

    function unstake(uint256 _hypercertId) external whenNotPaused {
        uint256 units = hypercertMinter.unitsOf(_hypercertId);
        delete stakes[_hypercertId].stakingStartTime;
        emit Unstaked(_hypercertId);
        hypercertMinter.safeTransferFrom(address(this), msg.sender, _hypercertId, units, "");
    }

    function claimReward(uint256 _hypercertId) external whenNotPaused {
        uint256 reward = calculateReward(_hypercertId);
        require(reward != 0, NoRewardAvailable());
        require(!stakes[_hypercertId].isClaimed, AlreadyClaimed());
        require(stakes[_hypercertId].stakingStartTime != 0, NotStaked());

        stakes[_hypercertId].isClaimed = true;
        emit RewardClaimed(msg.sender, reward);

        hypercertMinter.safeTransferFrom(
            address(this), msg.sender, _hypercertId, hypercertMinter.unitsOf(_hypercertId), ""
        );

        if (rewardToken != address(0)) {
            require(IERC20(rewardToken).transfer(msg.sender, reward), RewardTransferFailed());
        } else {
            (bool success,) = payable(msg.sender).call{value: reward}("");
            require(success, NativeTokenTransferFailed());
        }
    }

    function calculateReward(uint256 _hypercertId) public view returns (uint256) {
        uint256 stakeDuration = roundEndTime - stakes[_hypercertId].stakingStartTime;
        return totalRewards * (hypercertMinter.unitsOf(_hypercertId) / totalUnits) * (stakeDuration / roundDuration);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function getStake(uint256 _hypercertId) external view returns (Stake memory) {
        return stakes[_hypercertId];
    }

    function _getHypercertTypeId(uint256 _hypercertId) internal pure returns (uint256) {
        return _hypercertId & TYPE_MASK;
    }
}
