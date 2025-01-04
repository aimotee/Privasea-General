// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract StakingContract is   ReentrancyGuard, Pausable,Initializable, UUPSUpgradeable,OwnableUpgradeable {
    IERC20Upgradeable public stakingToken;

    struct Space {
        address owner;
        uint256 rate;
        uint256 totalStaked;
        mapping(address => bool) isStaker;
        address[] stakerList;
        uint256 status;
    }

    struct Stake {
        uint256 amount;
        uint256 timestamp;
        uint8 isUnstaking;
    }

    enum StakeStatus {
        Pending,
        Locked,
        Unlock,
        Withdraw
    }
    struct Rate {
        uint256 rate;
        uint256 Period;
    }
    mapping (address=> uint256) public userTotalWithdraw;
    mapping(uint256 => Space) public spaces;
    mapping(address => uint256[]) public ownerToSpaceIds;
    mapping(uint256 => mapping(address => Stake)) public userStakes;
    mapping(address => bool) public spaceCreated;
    mapping(uint256 => mapping(address => mapping(StakeStatus => uint256)))
        public userStakeAmounts;

    uint256 public currentPeriod;
    uint256 public nextSpaceId;

    bool public isSwitching;
    uint256 public switchingStartSpaceId;

    mapping(address => bool) public whitelist;
    mapping(uint256 => Rate) public pendingRateUpdates;
    mapping(uint256 => mapping(uint256 => mapping(address => uint256)))
        public userLockedAmounts;

    event SpaceCreated(uint256 indexed spaceId, address owner, uint256 rate);
    event Staked(address indexed user, uint256 indexed spaceId, uint256 amount);
    event Unstaked(
        address indexed user,
        uint256 indexed spaceId,
        uint256 amount
    );
    event Withdraw(address indexed user, uint256 amount);
    event PeriodSwitchStarted(uint256 newPeriod);
    event PeriodSwitchContinued(uint256 processedUpToSpaceId);
    event PeriodSwitchCompleted(uint256 completedPeriod);
    event WhitelistUpdated(address user, bool status);
    event StakerStatusProcessed(
        uint256 indexed spaceId,
        address indexed staker,
        uint256 pendingAmount,
        uint256 lockedAmount
    );
    event SpaceDestroyed(uint256 indexed spaceId, address indexed owner);
    event SpaceRateUpdated(uint256 indexed spaceId, uint256 newRate);
    event SpaceRateApplied(uint256 indexed spaceId, uint256 newRate);
     function initialize(IERC20Upgradeable _stakingToken,address owner) public initializer{
         __Ownable_init(owner);
        __UUPSUpgradeable_init();
        stakingToken = _stakingToken;
        currentPeriod = 1;
    }

    function _msgSender() internal view virtual override(ContextUpgradeable, Context) returns (address)  {
        return msg.sender;
    }

    function _msgData() internal view virtual override(ContextUpgradeable, Context) returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual override(ContextUpgradeable, Context) returns (uint256) {
        return 0;
    }
    function createSpace(uint256 _rate) external whenNotPaused {
        require(!spaceCreated[msg.sender], "You have already created a space.");
        require(
            _rate > 0 && _rate <= 99,
            "_rate must bigger than 0 and less than 99"
        );
        Space storage newSpace = spaces[nextSpaceId];
        newSpace.owner = msg.sender;
        newSpace.rate = _rate;
        newSpace.totalStaked = 0;
        newSpace.status = 0;
        ownerToSpaceIds[msg.sender].push(nextSpaceId);
        pendingRateUpdates[nextSpaceId].rate = _rate;
        emit SpaceCreated(nextSpaceId, msg.sender, _rate);
        spaceCreated[msg.sender] = true;
        nextSpaceId++;
    }

    function toDestroy(uint256 _spaceId) public {
        require(
            spaces[_spaceId].owner == msg.sender,
            "Only the space owner can destroy the space"
        ); // 确保调用者是空间的所有者
        require(spaces[_spaceId].owner != address(0), "Space does not exist");
        Space storage space = spaces[_spaceId];
        space.status = 1;
    }

    function destroySpace(uint256 _spaceId) private nonReentrant whenNotPaused {
        require(
            spaces[_spaceId].owner == msg.sender,
            "Only the space owner can destroy the space"
        ); // 确保调用者是空间的所有者
        require(spaces[_spaceId].owner != address(0), "Space does not exist"); // 确保空间存在

        Space storage space = spaces[_spaceId];
        require(
            space.totalStaked == 0,
            "Space cannot be destroyed while there are stakers"
        ); // 确保空间内没有质押

        // 将下个周期的质押金额转移到可领取金额中
        for (uint256 i = 0; i < space.stakerList.length; i++) {
            address staker = space.stakerList[i];
            uint256 lockedAmount = userStakeAmounts[_spaceId][staker][
                StakeStatus.Locked
            ];
            require(
                lockedAmount == 0,
                "There are still locked stakes in the space"
            ); // 确保没有锁定的质押金额

            uint256 pendingAmount = userStakeAmounts[_spaceId][staker][
                StakeStatus.Pending
            ];
            if (pendingAmount > 0) {
                // 将待处理的质押金额转移到可领取金额中
                userStakeAmounts[_spaceId][staker][
                    StakeStatus.Withdraw
                ] += pendingAmount;
                userStakeAmounts[_spaceId][staker][StakeStatus.Pending] = 0;
            }
        }

        delete spaces[_spaceId]; // 删除空间信息
        emit SpaceDestroyed(_spaceId, space.owner);
    }

    function updateSpaceRate(uint256 _spaceId, uint256 _newRate) external {
        require(spaces[_spaceId].owner != address(0), "Space does not exist");
        require(
            spaces[_spaceId].owner == msg.sender,
            "Only the space owner can destroy the space"
        );
        require(_newRate > 0, "New rate must be greater than 0");

        // 存储新的rate，将在下一个周期开始时生效
        pendingRateUpdates[_spaceId].rate = _newRate;
        pendingRateUpdates[_spaceId].Period = currentPeriod;
        emit SpaceRateUpdated(_spaceId, _newRate);
    }

    function stake(
        uint256 _spaceId,
        uint256 _amount
    ) external whenNotPaused nonReentrant {
        Space storage space = spaces[_spaceId];
        require(space.owner != address(0), "Space does not exist");
        require(_amount > 0, "Stake amount must be greater than 0");

        stakingToken.transferFrom(msg.sender, address(this), _amount);

        Stake storage userStake = userStakes[_spaceId][msg.sender];
        if (userStake.amount == 0) {
            space.totalStaked++;
            space.isStaker[msg.sender] = true;
            space.stakerList.push(msg.sender);
            userStake.isUnstaking = 0;
        }
        userStake.amount += _amount;
        userStake.timestamp = block.timestamp;
        userStakeAmounts[_spaceId][msg.sender][StakeStatus.Pending] += _amount;

        emit Staked(msg.sender, _spaceId, _amount);
    }

    function unstake(
        uint256 _spaceId,
        uint256 _amount
    ) external nonReentrant whenNotPaused {
        Stake storage userStake = userStakes[_spaceId][msg.sender];
        require(userStake.amount > 0, "No stake found");
        require(_amount > 0, "Unstake amount must be greater than 0");

        uint256 pendingAmount = userStakeAmounts[_spaceId][msg.sender][
            StakeStatus.Pending
        ];
        uint256 lockedAmount = userStakeAmounts[_spaceId][msg.sender][
            StakeStatus.Locked
        ];
        uint256 unLockAmount =userStakeAmounts[_spaceId][msg.sender][
                    StakeStatus.Unlock];
        require(
            pendingAmount + lockedAmount >= _amount,
            "Insufficient staked amount"
        );

        if (_amount <= pendingAmount) {
            // 如果传入金额小于待处理金额，则减少待处理金额
            userStakeAmounts[_spaceId][msg.sender][
                StakeStatus.Pending
            ] -= _amount;
            stakingToken.transfer(msg.sender, _amount);
            
        } else {
            // 如果传入金额大于或等于待处理金额
            if (_amount > pendingAmount) {
                // 先处理待处理金额
                userStakeAmounts[_spaceId][msg.sender][StakeStatus.Pending] = 0;
                 _amount -= pendingAmount;
                stakingToken.transfer(msg.sender, pendingAmount);
               
                if( 
                    unLockAmount+_amount>lockedAmount
                ){
                    userStakeAmounts[_spaceId][msg.sender][
                    StakeStatus.Unlock]=userStakeAmounts[_spaceId][msg.sender][
                    StakeStatus.Locked
                    ];
                    }else{
                    userStakeAmounts[_spaceId][msg.sender][
                    StakeStatus.Unlock
                ] += _amount;
                }
                
            }
            // 然后处理锁定金额
        }

        userStake.isUnstaking = 1;
        emit Unstaked(msg.sender, _spaceId, _amount);
    }

    function withdraw() external whenNotPaused nonReentrant {
        uint256 withdrawAmount = userTotalWithdraw[msg.sender];
        
        require(withdrawAmount > 0, "No tokens available for withdrawal");
        
        userTotalWithdraw[msg.sender] = 0;
   
        for (uint256 spaceId = 0; spaceId < nextSpaceId; spaceId++) {
          userStakeAmounts[spaceId][msg.sender][
            StakeStatus.Withdraw
        ]=0;
        }
   

        stakingToken.transfer(msg.sender, withdrawAmount);

        emit Withdraw(msg.sender, withdrawAmount);
    }

    function addToWhitelist(address _user) external onlyOwner {
        whitelist[_user] = true;
        emit WhitelistUpdated(_user, true);
    }

    function removeFromWhitelist(address _user) external onlyOwner {
        whitelist[_user] = false;
        emit WhitelistUpdated(_user, false);
    }

    function startSwitchPeriod() external {
        require(whitelist[msg.sender], "Not in whitelist");
        require(!isSwitching, "Period switching has already started");

        _pause();
        isSwitching = true;
        switchingStartSpaceId = 0;
        currentPeriod++;

        for (uint256 i = 0; i < nextSpaceId; i++) {
            if (pendingRateUpdates[i].rate > 0) {
                spaces[i].rate = pendingRateUpdates[i].rate;
                pendingRateUpdates[i].rate = 0;
                emit SpaceRateApplied(i, spaces[i].rate);
            }
        }
        emit PeriodSwitchStarted(currentPeriod);
    }

    function continueSwitchPeriod() external whenPaused {
        require(whitelist[msg.sender], "Not in whitelist");
        require(isSwitching, "Period switching has not started");
        uint256 currentSpaceId;
        for (uint256 spaceId = 0; spaceId < nextSpaceId; spaceId++) {
            Space storage space = spaces[spaceId];
            if (space.totalStaked > 0) {
                for (uint256 j = 0; j < space.stakerList.length; j++) {
                    address staker = space.stakerList[j];
                    if (space.isStaker[staker]) {
                        processStakerStatus(spaceId, staker);
                    }
                }
            }
            currentSpaceId = spaceId;           
        }

        if (currentSpaceId + 1 >= nextSpaceId) {
            finishSwitchPeriod();
            switchingStartSpaceId = 0;
        }


        emit PeriodSwitchContinued(switchingStartSpaceId);
    }

    function continueSingleSwitchPeriod(uint256 _spaceId) external whenPaused {
        require(whitelist[msg.sender], "Not in whitelist");
        require(isSwitching, "Period switching has not started");

        Space storage space = spaces[_spaceId];
        if (space.totalStaked > 0) {
            for (uint256 j = 0; j < space.stakerList.length; j++) {
                address staker = space.stakerList[j];
                if (space.isStaker[staker]) {
                    processStakerStatus(_spaceId, staker);
                }
            }
        }
        finishSwitchPeriod();
        switchingStartSpaceId = 0;

        emit PeriodSwitchContinued(switchingStartSpaceId);
    }

    function finishSwitchPeriod() internal {
        isSwitching = false;
        _unpause();
        emit PeriodSwitchCompleted(currentPeriod);
    }

    function processStakerStatus(uint256 _spaceId, address _staker) internal {
        Stake storage userStake = userStakes[_spaceId][_staker];

        uint256 pendingAmount = userStakeAmounts[_spaceId][_staker][
            StakeStatus.Pending
        ];
        if (pendingAmount > 0) {
            userStakeAmounts[_spaceId][_staker][
                StakeStatus.Locked
            ] += pendingAmount;
            userStakeAmounts[_spaceId][_staker][StakeStatus.Pending] = 0;
        }

        uint256 unLockedAmount = userStakeAmounts[_spaceId][_staker][
            StakeStatus.Unlock
        ];

        if (unLockedAmount > 0 && userStake.isUnstaking == 1) {
            userStakeAmounts[_spaceId][_staker][
                StakeStatus.Withdraw
            ] += unLockedAmount;
            userTotalWithdraw[_staker]+=unLockedAmount;
            userStakeAmounts[_spaceId][_staker][StakeStatus.Locked]-=unLockedAmount;
            userStakeAmounts[_spaceId][_staker][StakeStatus.Unlock] = 0;
        }
        if (currentPeriod - pendingRateUpdates[_spaceId].Period == 2) {
            spaces[_spaceId].rate = pendingRateUpdates[_spaceId].rate;
        }
        if (spaces[_spaceId].status == 1) {
            destroySpace(_spaceId);
        }

        emit StakerStatusProcessed(
            _spaceId,
            _staker,
            pendingAmount,
            unLockedAmount
        );
    }

    function getCurrentPeriod() public view returns (uint256) {
        return currentPeriod;
    }

    function findSpaceByOwner(
        address _owner
    ) public view returns (uint256[] memory) {
        return ownerToSpaceIds[_owner];
    }

    function getStakers(
        uint256 _spaceId
    ) public view returns (address[] memory) {
        return spaces[_spaceId].stakerList;
    }
 
    function getUserWithdraw(
        address _staker
    )public view returns(uint256) {
        return userTotalWithdraw[_staker];
    }

    function getUserStakeInfo(
        uint256 _spaceId,
        address _staker
    )
        public
        view
        returns (
            uint256 userPending,
            uint256 userLocked,
            uint256 userUnlock,
            uint256 userWithdraw
        )
    {
        userPending = userStakeAmounts[_spaceId][_staker][StakeStatus.Pending];
        userLocked = userStakeAmounts[_spaceId][_staker][StakeStatus.Locked];
        userUnlock = userStakeAmounts[_spaceId][_staker][StakeStatus.Unlock];
        userWithdraw = userStakeAmounts[_spaceId][_staker][
            StakeStatus.Withdraw
        ];
    }

    function getTotalStakeInfo(
        uint256 _spaceId
    ) public view returns (uint256[4] memory) {
        Space storage space = spaces[_spaceId];
        uint256 stakerCount = space.stakerList.length;
        uint256[4] memory totals;
        for (uint256 i = 0; i < stakerCount; i++) {
            address staker = spaces[_spaceId].stakerList[i];
            Stake storage userStake = userStakes[_spaceId][staker];
            if (userStake.amount > 0) {
                totals[0] += userStakeAmounts[_spaceId][staker][
                    StakeStatus.Pending
                ];
                totals[1] += userStakeAmounts[_spaceId][staker][
                    StakeStatus.Locked
                ];
                totals[2] += userStakeAmounts[_spaceId][staker][
                    StakeStatus.Unlock
                ];
                totals[3] += userStakeAmounts[_spaceId][staker][
                    StakeStatus.Withdraw
                ];
            }
        }
        return totals;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
