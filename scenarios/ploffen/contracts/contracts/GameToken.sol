pragma solidity 0.8.19;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract GameToken is ERC20 {
     constructor() ERC20("Game Token", "GTK") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
