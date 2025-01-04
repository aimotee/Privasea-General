// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/utils/cryptography/MerkleProofUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Rewards is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    struct MerkleRoot {
        bytes32 root;
        uint256 timestamp;
    }

    uint256 public currentPeriod; 

    mapping(uint256 => MerkleRoot) public merkleRoots;
    mapping(address => bool) public whitelist;
    mapping(address => mapping(uint256 => bool)) public hasClaimed;

    event RewardClaimed(address indexed user, uint256 amount, uint256 period);
    event MerkleRootUpdated(uint256 indexed period, bytes32 root);
    event WhitelistUpdated(address indexed user, bool isWhitelisted);
    event RewardTokensReceived(address indexed from, uint256 amount);
    event CurrentPeriodUpdated(uint256 indexed period);

    IERC20Upgradeable public rewardToken;

    /// @dev Initialize function instead of constructor for upgradeability
    function initialize(address _rewardToken,address owner) public onlyOwner{
        __Ownable_init(owner);
        __UUPSUpgradeable_init();
        rewardToken = IERC20Upgradeable(_rewardToken);
    }

    function setCurrentPeriod(uint256 _period) external onlyOwner {
        currentPeriod = _period;
        emit CurrentPeriodUpdated(_period);
    }

    function setWhitelist(address user, bool isWhitelisted) external onlyOwner {
        whitelist[user] = isWhitelisted;
        emit WhitelistUpdated(user, isWhitelisted);
    }

    function updateMerkleRoot(uint256 period, bytes32 newRoot) external {
        require(whitelist[msg.sender], "Only whitelisted users can update the merkle root");
        merkleRoots[period] = MerkleRoot(newRoot, block.timestamp);
        emit MerkleRootUpdated(period, newRoot);
    }

    function isClaim(uint256 period,address addr) view external returns (bool){
        return hasClaimed[addr][period];
    }

    function isProof(uint256 period,address addr,uint256 amount,bytes32[] calldata merkleProof) view  external returns (bool){
        bytes32 leaf = keccak256(abi.encodePacked(addr, amount));
        require(MerkleProofUpgradeable.verify(merkleProof, merkleRoots[period].root, leaf), "Invalid merkle proof");
        return MerkleProofUpgradeable.verify(merkleProof, merkleRoots[period].root, leaf);
    }

    function claimReward(uint256 period, uint256 amount, bytes32[] calldata merkleProof) external {
        require(period == currentPeriod, "Not the current claiming period");
        require(!hasClaimed[msg.sender][period], "Reward for this period has already been claimed");
        require(merkleRoots[period].root != bytes32(0), "Merkle root for this period does not exist");

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        require(MerkleProofUpgradeable.verify(merkleProof, merkleRoots[period].root, leaf), "Invalid merkle proof");
        require(rewardToken.transfer(msg.sender, amount), "Token transfer failed");
        hasClaimed[msg.sender][period] = true;
        emit RewardClaimed(msg.sender, amount, period);
    }

    function withdrawUndistributedRewards() external onlyOwner {
        uint256 balance = rewardToken.balanceOf(address(this));
        require(rewardToken.transfer(owner(), balance), "Token transfer failed");
    }

    function receiveRewardTokens(uint256 amount) external {
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        emit RewardTokensReceived(msg.sender, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}