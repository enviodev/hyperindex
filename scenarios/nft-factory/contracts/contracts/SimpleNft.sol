pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract SimpleNft is ERC721 {
    using Counters for Counters.Counter;

    Counters.Counter private _supply;
    uint256 public maxSupply;

    constructor(
        string memory name,
        string memory symbol,
        uint256 _maxSupply
    ) ERC721(name, symbol) {
        _supply.increment();
        maxSupply = _maxSupply;
    }

    function mint(uint256 _quantity) public {
        require(
            (_quantity + _supply.current()) <= maxSupply,
            "Max supply exceeded"
        );
        _mintLoop(msg.sender, _quantity);
    }

    function _mintLoop(address _to, uint256 _quantity) internal {
        for (uint256 i = 0; i < _quantity; ++i) {
            _safeMint(_to, _supply.current());
            _supply.increment();
        }
    }

    function totalSupply() public view returns (uint256) {
        return _supply.current() - 1;
    }
}
