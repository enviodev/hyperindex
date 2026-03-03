// In CI the prepare-envio-artifacts action downloads the platform
// package into .envio-artifacts/. When that directory exists, rewrite
// the optional dependency so pnpm resolves it from the local tarball
// instead of the npm registry. In normal dev no hooks are registered.
const fs = require("fs");

const hooks = {};

if (fs.existsSync(".envio-artifacts/envio-linux-x64")) {
  hooks.readPackage = (pkg) => {
    if (pkg.optionalDependencies?.["envio-linux-x64"]) {
      pkg.optionalDependencies["envio-linux-x64"] =
        "file:.envio-artifacts/envio-linux-x64";
    }
    return pkg;
  };
}

module.exports = { hooks };
