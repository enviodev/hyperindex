require("@nomiclabs/hardhat-ethers");

module.exports = {
  solidity: "0.8.19",
  paths: {
    sources: "./test/helpers/contracts",
  },
  networks: {
    localhost: {
      url: "http://127.0.0.1:8545",
      accounts: {
        mnemonic: "test test test test test test test test test test test junk",
      },
    },
  },
};
