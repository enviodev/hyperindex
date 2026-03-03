// When CI artifacts are present, rewrite envio's optionalDependencies
// so pnpm installs the platform binary from the local artifact
// instead of the npm registry. In normal dev this is a no-op.
const fs = require("fs");

const hooks = {};

if (fs.existsSync(".envio-artifacts/envio-linux-x64")) {
  hooks.readPackage = (pkg) => {
    if (pkg.name === "envio" && pkg.optionalDependencies) {
      pkg.optionalDependencies = {
        "envio-linux-x64": "file:.envio-artifacts/envio-linux-x64",
      };
    }
    return pkg;
  };
}

module.exports = { hooks };
