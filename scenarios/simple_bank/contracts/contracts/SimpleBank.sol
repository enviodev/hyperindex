// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// SimpleBank contract
contract SimpleBank {
    mapping(address => uint256) private balances;
    uint256 private totalBalance;
    address private treasuryAddress;
    uint256 private lastInterestCalculationTime;

    event AccountCreated(address indexed userAddress);
    event DepositMade(address indexed userAddress, uint256 amount);
    event WithdrawalMade(address indexed userAddress, uint256 amount);
    event TotalBalanceChanged(uint256 totalBalance);

    constructor(address _treasuryAddress) {
        treasuryAddress = _treasuryAddress;
    }

    // Create a new account
    function createAccount(address userAddress) external {
        require(balances[userAddress] == 0, "Account already exists");

        // Update balance and total balance
        balances[userAddress] = 0;
        totalBalance += 0;

        // Emit event
        emit AccountCreated(userAddress);

        // Update total balance event
        emit TotalBalanceChanged(totalBalance);
    }

    // Deposit funds into the account
    function deposit(address userAddress, uint256 depositAmount) external payable {
        require(depositAmount > 0, "Deposit amount should be greater than 0");

        // Calculate interest since last interest calculation time
        uint256 interest = _calculateInterest(userAddress);

        // Update balance and total balance
        balances[userAddress] += depositAmount + interest;
        totalBalance += depositAmount + interest;

        // Emit event
        emit DepositMade(userAddress, depositAmount);

        // Update last interest calculation time
        lastInterestCalculationTime = block.timestamp;

        // Update total balance event
        emit TotalBalanceChanged(totalBalance);
    }

    // Withdraw funds from the account
    function withdraw(address userAddress, uint256 _amount) external {
        require(_amount > 0, "Withdrawal amount should be greater than 0");
        require(_amount <= balances[userAddress], "Insufficient balance");

        // Calculate interest since last interest calculation time
        uint256 interest = _calculateInterest(userAddress);

        // Update balance and total balance
        balances[userAddress] -= _amount;
        totalBalance -= _amount;

        // Emit event
        emit WithdrawalMade(userAddress, _amount);

        // Update last interest calculation time
        lastInterestCalculationTime = block.timestamp;

        // Update total balance event
        emit TotalBalanceChanged(totalBalance);

        // Transfer funds to the user's account
        (bool success, ) = userAddress.call{value: _amount + interest}("");
        require(success, "Transfer failed");
    }

    // Calculate interest earned by the user since the last calculation time
    function _calculateInterest(address userAddress) private returns (uint256) {
        Treasury treasuryContract = Treasury(treasuryAddress);
        uint256 interest = treasuryContract.calculateInterest();

        // Calculate interest earned by the user and update their balance
        uint256 accountInterest = (interest * balances[userAddress]) / totalBalance;
        balances[msg.sender] += accountInterest;

        // Emit event for interest calculation
        // emit Treasury.InterestCalculated(interest);

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

contract Treasury {
    uint256 private totalBalance;
    uint256 private lastInterestCalculationTime;
    uint256 private interestRate;

    event InterestCalculated(uint256 interest);

    constructor(uint256 _interestRate) {
        interestRate = _interestRate;
    }

    // Calculate interest earned since the last calculation time
    function calculateInterest() external returns (uint256) {
        uint256 timeElapsed = block.timestamp - lastInterestCalculationTime;
        uint256 interest = (totalBalance * interestRate * timeElapsed) / (365 * 24 * 60 * 60);

        // Update last interest calculation time and total balance
        lastInterestCalculationTime = block.timestamp;
        totalBalance += interest;

        // Emit event for interest calculation
        emit InterestCalculated(interest);

        return interest;
    }

    // Get the current interest rate
    function getInterestRate() external view returns (uint256) {
        return interestRate;
    }

    // Set the interest rate
    function setInterestRate(uint256 _interestRate) external {
        interestRate = _interestRate;
    }

    // Get the total balance in the treasury
    function getTotalBalance() external view returns (uint256) {
        return totalBalance;
    }
}

