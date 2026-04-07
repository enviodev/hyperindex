// When CI artifacts are present, redirect envio dependencies from the
// dev workspace member (packages/envio) to the pre-built artifact in
// .envio-artifacts/envio. Also redirect the platform binary package
// (envio-linux-x64) to its local artifact. In normal dev this is a no-op.
const fs = require("fs");

const hooks = {};

if (fs.existsSync(".envio-artifacts/envio")) {
  hooks.readPackage = (pkg) => {
    // Redirect file: references to packages/envio → .envio-artifacts/envio
    for (const field of ["dependencies", "devDependencies", "optionalDependencies"]) {
      if (pkg[field]?.envio?.includes("packages/envio")) {
        pkg[field].envio = pkg[field].envio.replace(
          "packages/envio",
          ".envio-artifacts/envio"
        );
      }
    }

    // Redirect envio-linux-x64 in the artifact's optionalDependencies
    // to the local platform binary artifact
    if (pkg.name === "envio" && pkg.optionalDependencies?.["envio-linux-x64"]) {
      pkg.optionalDependencies["envio-linux-x64"] = "file:../envio-linux-x64";
    }

    return pkg;
  };
}

module.exports = { hooks };
