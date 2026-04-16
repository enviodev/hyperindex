// When CI artifacts are present, redirect envio dependencies from the
// dev workspace member (packages/envio) to the pre-built artifact in
// .envio-artifacts/envio. Also redirect the platform binary package
// (envio-linux-x64) to its local artifact. In normal dev this is a no-op.
const fs = require("fs");
const path = require("path");

// Resolve relative to this file (workspace root) instead of process.cwd()
// so that pnpm installs invoked from a workspace member (e.g.
// `envio codegen` running pnpm install in scenarios/e2e_test) still see
// the artifact and apply the same redirect. Otherwise the second install
// reinstalls envio from packages/envio without rescript build artifacts,
// dropping new files like src/Migrations.res.mjs.
const ARTIFACT_DIR = path.join(__dirname, ".envio-artifacts", "envio");
const PLATFORM_ARTIFACT_DIR = path.join(__dirname, ".envio-artifacts", "envio-linux-x64");

const hooks = {};

if (fs.existsSync(ARTIFACT_DIR)) {
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
    // to the local platform NAPI addon artifact. The path is relative to
    // the envio package directory (.envio-artifacts/envio/).
    if (pkg.name === "envio" && pkg.optionalDependencies?.["envio-linux-x64"]) {
      pkg.optionalDependencies["envio-linux-x64"] = "file:../envio-linux-x64";
    }

    return pkg;
  };
}

module.exports = { hooks };
