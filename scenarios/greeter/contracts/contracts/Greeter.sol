// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.4;

import { console } from "hardhat/console.sol";

error GreeterError();

contract Greeter {
    string public greeting;

    event NewGreeting(string greeting);
    event UpdateGreeting(string greeting);

    constructor(string memory _greeting) {
        console.log("Deploying a Greeter with greeting:", _greeting);
        greeting = _greeting;
        emit NewGreeting(_greeting);
    }

    function greet() public view returns (string memory) {
        return greeting;
    }

    function setGreeting(string memory _greeting) public {
        console.log("Changing greeting from '%s' to '%s'", greeting, _greeting);
        greeting = _greeting;
        emit UpdateGreeting(greeting);
    }

    function throwError() external pure {
        revert GreeterError();
    }
}
