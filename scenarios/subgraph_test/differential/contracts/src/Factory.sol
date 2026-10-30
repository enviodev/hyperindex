// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// The contracts behind abis/Factory.json and abis/Pair.json, reduced to the
// events and the call the subgraph reads.
contract Pair {
    event Swap(address indexed sender, uint256 amount);

    function swap(uint256 amount) external {
        emit Swap(msg.sender, amount);
    }
}

contract Factory {
    event PairCreated(address token0, address token1, address pair);

    string public name = "Uniswap";

    function createPair(address token0, address token1) external returns (address pair) {
        pair = address(new Pair());
        emit PairCreated(token0, token1, pair);
    }
}
