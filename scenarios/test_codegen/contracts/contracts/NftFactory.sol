pragma solidity ^0.8.0;
import "./SimpleNft.sol";

contract NftFactory {
    event SimpleNftCreated(
        string name,
        string symbol,
        uint256 maxSupply,
        address contractAddress
    );

    constructor() {}

    function createNft(
        string memory name,
        string memory symbol,
        uint256 maxSupply
    ) external {
        SimpleNft simpleNft = new SimpleNft(name, symbol, maxSupply);
        emit SimpleNftCreated(name, symbol, maxSupply, address(simpleNft));
    }
}
