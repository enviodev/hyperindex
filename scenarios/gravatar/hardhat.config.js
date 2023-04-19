require("@nomiclabs/hardhat-ethers");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.18",
  paths: {
    sources: "./src/__tests__/helpers/contracts"
  },
  networks: {
    hardhat: {
      accounts: {
        mnemonic: "test test test test test test test test test test test test",
      }
    }
  },
};
