const { exec } = require("child_process");

module.exports.default = setupNodeAndContracts = () => {
  return new Promise((resolve, reject) => {
    exec(`echo "For now rather run the contracts directly, seems to give lots of errors using this approach (not terminating the node etc)"`, (error, stdout, stderr) => {
      // exec("cd ../contracts && pnpm hardhat-node", (error, stdout, stderr) => {
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
