// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PrivaseaAITestToken is ERC20, Ownable {
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000 * (10 ** 18); // Total supply of tokens, with 18 decimals
    uint256 public constant TOKENS_PER_CLAIM = 10 * (10 ** 18); // Number of tokens per claim, with 18 decimals
    mapping(address => bool) public hasClaimed; // Track if an address has claimed tokens

    constructor() ERC20("Privasea AI Test Token", "PRAIT") Ownable(msg.sender) {
        uint256 halfSupply = TOTAL_SUPPLY / 2;
        _mint(address(this), halfSupply); // Mint 500 million tokens to the contract address
        _mint(msg.sender, halfSupply);    // Mint 500 million tokens to the deployer's address
    }

    function claimTokens() external {
        require(!hasClaimed[msg.sender], "Address has already claimed tokens");
        require(balanceOf(address(this)) >= TOKENS_PER_CLAIM, "Not enough tokens in reserve for claiming");
        hasClaimed[msg.sender] = true;
        _transfer(address(this), msg.sender, TOKENS_PER_CLAIM);
    }

    // Function to check if an address has claimed tokens
    function hasAddressClaimed(address _address) external view returns (bool) {
        return hasClaimed[_address];
    }

    // Additional functions can be added here to manage the contract as needed
}