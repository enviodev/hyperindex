pragma solidity 0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Ploffen is a fun game.

contract Ploffen {
    IERC20 public gameToken;
    address public currentPloffenWinner;
    uint256 public ploffenTimer;

    // Constants.
    uint256 public constant BASE_TIME = 3600; // 1 hours in seconds.
    // uint256 public constant MAX_TIME = 90000; // 25 hours in seconds.
    uint256 public constant MIN_AMOUNT = 1e18; // 1 token min contribution. 
    // uint256 public constant MAX_AMOUNT = 25e18; // 25 tokens max contribution. 

    event CreatePloffen(address indexed tokenGameAddress);
    event StartPloffen(uint256 seedAmount);
    event PlayPloffen(address indexed player, uint256 amount, uint256 newTimer);
    event WinPloffen(address indexed winner, uint256 winnings);

    constructor(address _gameToken) {
        gameToken = IERC20(_gameToken);
        emit CreatePloffen(_gameToken);
    }

    function startPloffen(uint256 amount) public{
        require(amount >= MIN_AMOUNT, "More ploffen needed to start");
        gameToken.transferFrom(msg.sender, address(this), amount);
        emit StartPloffen(amount);
    }

    function playPloffen(uint256 amount) public {
        require(amount >= MIN_AMOUNT, "Amount must be greater or equal to minimum");
        ploffenTimer = block.timestamp + 3600; // simply hardcode to add one hour
        gameToken.transferFrom(msg.sender, address(this), amount);
        currentPloffenWinner = msg.sender;

        emit PlayPloffen(msg.sender, amount, ploffenTimer);
    }

    function winPloffen() public {
        require(msg.sender == currentPloffenWinner && block.timestamp > ploffenTimer, "Invalid winner or timer not expired");
        uint256 winnings = gameToken.balanceOf(address(this));
        gameToken.transfer(currentPloffenWinner, winnings);

        emit WinPloffen(currentPloffenWinner, winnings);
    }

}