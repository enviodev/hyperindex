const bsconfig = require("./bsconfig.json");

// This is necessary because some bs-dependencies use es6 imports outside of a module
const transpileModules = bsconfig["bs-dependencies"];
const withTM = require("next-transpile-modules")(transpileModules);

const config = {
  images: {
    domains: ["media-float-capital.fra1.cdn.digitaloceanspaces.com"],
  },
  swcMinify: true,
  pageExtensions: ["jsx", "js"],
  transpileModules: ["rescript"].concat(bsconfig["bs-dependencies"]),
  //Experimental feature to use swc for minification instead of terser we can try, defaulted to true in Nextjs@12.1
  // swcMinify: true,
  env: {
    ENV: process.env.NODE_ENV,
  },
};

module.exports = withTM(config);
