// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
