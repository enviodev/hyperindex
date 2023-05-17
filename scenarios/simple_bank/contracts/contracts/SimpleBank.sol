// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// SimpleBank contract
contract SimpleBank {
    mapping(address => uint256) private balances;
    uint256 private totalBalance;
    uint256 private interestRate;
    uint256 private lastInterestCalculationTime;

    event AccountCreated(address indexed userAddress);
    event DepositMade(address indexed userAddress, uint256 amount);
    event WithdrawalMade(address indexed userAddress, uint256 amount);

    constructor(uint256 _interestRate) {
        interestRate = _interestRate;
    }

    // Create a new account
    function createAccount(address userAddress) external {
        require(balances[userAddress] == 0, "Account already exists");

        // Update balance and total balance
        balances[userAddress] = 0;

        // Emit event
        emit AccountCreated(userAddress);
        
    }

    // Deposit funds into the account
    function deposit(
        uint256 depositAmount
    ) external {
        require(depositAmount > 0, "Deposit amount should be greater than 0");

        // Calculate interest since last interest calculation time
        _calculateAndApplyInterest(msg.sender);

        // Update balance and total balance
        balances[msg.sender] += depositAmount;
        totalBalance += depositAmount;

        // Emit event
        emit DepositMade(msg.sender, depositAmount);
    }

    // Withdraw funds from the account
    function withdraw(uint256 withdrawalAmount) external {
        require(withdrawalAmount > 0, "Withdrawal amount should be greater than 0");
        require(withdrawalAmount <= balances[msg.sender], "Insufficient balance");

        // Calculate interest since last interest calculation time
        // _calculateAndApplyInterest(msg.sender);

        // Update balance and total balance
        balances[msg.sender] -= withdrawalAmount;
        totalBalance -= withdrawalAmount;

        // Emit event
        emit WithdrawalMade(msg.sender, withdrawalAmount);

    }

    // Calculate interest earned by the user since the last calculation time
    function _calculateAndApplyInterest(address userAddress) private returns (uint256 accountInterest) {

        if (balances[userAddress] > 0) {
            // Calculate interest earned since the last calculation time
            uint256 timeElapsed = block.timestamp - lastInterestCalculationTime;
            uint256 interest = (totalBalance * interestRate * timeElapsed) /
                (100 * 365 * 24 * 60 * 60);

            // Update last interest calculation time and total balance
            lastInterestCalculationTime = block.timestamp;
            totalBalance += interest;

            // Calculate interest earned by the user and update their balance
            accountInterest = (interest * balances[userAddress]) /
                totalBalance;
            balances[userAddress] += accountInterest;
            
        } else {
            accountInterest = 0;
        }

        return accountInterest;
    }

    // Get the balance of the user
    function getBalance(address userAddress) external view returns (uint256) {
        return balances[userAddress];
    }

    // Get the total balance of the bank
    function getTotalBalance() external view returns (uint256) {
        return totalBalance;
    }
}

