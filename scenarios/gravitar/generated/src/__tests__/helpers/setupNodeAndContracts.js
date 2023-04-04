const { exec } = require("child_process");

module.exports.default = setupNodeAndContracts = () => {
  return new Promise((resolve, reject) => {
    exec("cd ../contracts && pnpm hardhat-node", (error, stdout, stderr) => {
      if (!!error) {
        console.warn(
          "issue running the hardhat node - this might cause issues in the tests",
          error
        );
      }
      resolve();
    });
  });
};
