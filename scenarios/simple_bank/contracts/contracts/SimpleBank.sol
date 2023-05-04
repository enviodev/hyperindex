// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interface for Treasury contract
interface Treasury {
    function calculateInterest() external returns (uint256);
    event InterestCalculated(uint256 interest);
}

// SimpleBank contract
contract SimpleBank {
    mapping(address => uint256) private balances;
    uint256 private totalBalance;
    address private treasuryAddress;
    uint256 private lastInterestCalculationTime;

    event DepositMade(address indexed account, uint256 amount);
    event WithdrawalMade(address indexed account, uint256 amount);
    event TotalBalanceChanged(uint256 totalBalance);

    constructor(address _treasuryAddress) {
        treasuryAddress = _treasuryAddress;
    }

    // Deposit funds into the account
    function deposit() external payable {
        uint256 depositAmount = msg.value;
        require(depositAmount > 0, "Deposit amount should be greater than 0");

        // Calculate interest since last interest calculation time
        uint256 interest = _calculateInterest();

        // Update balance and total balance
        balances[msg.sender] += depositAmount + interest;
        totalBalance += depositAmount + interest;

        // Emit event
        emit DepositMade(msg.sender, depositAmount);

        // Update last interest calculation time
        lastInterestCalculationTime = block.timestamp;

        // Update total balance event
        emit TotalBalanceChanged(totalBalance);
    }

    // Withdraw funds from the account
    function withdraw(uint256 _amount) external {
        require(_amount > 0, "Withdrawal amount should be greater than 0");
        require(_amount <= balances[msg.sender], "Insufficient balance");

        // Calculate interest since last interest calculation time
        uint256 interest = _calculateInterest();

        // Update balance and total balance
        balances[msg.sender] -= _amount;
        totalBalance -= _amount;

        // Emit event
        emit WithdrawalMade(msg.sender, _amount);

        // Update last interest calculation time
        lastInterestCalculationTime = block.timestamp;

        // Update total balance event
        emit TotalBalanceChanged(totalBalance);

        // Transfer funds to the user's account
        (bool success, ) = msg.sender.call{value: _amount + interest}("");
        require(success, "Transfer failed");
    }

    // Calculate interest earned by the user since the last calculation time
    function _calculateInterest() private returns (uint256) {
        Treasury treasuryContract = Treasury(treasuryAddress);
        uint256 interest = treasuryContract.calculateInterest();

        // Calculate interest earned by the user and update their balance
        uint256 userInterest = (interest * balances[msg.sender]) / totalBalance;
        balances[msg.sender] += userInterest;

        // Emit event for interest calculation
        // emit Treasury.InterestCalculated(interest);

        return userInterest;
    }

    // Get the balance of the user
    function getBalance() external view returns (uint256) {
        return balances[msg.sender];
    }

    // Get the total balance of the bank
    function getTotalBalance() external view returns (uint256) {
        return totalBalance;
    }
}
