open Vitest

describe("Test PackageJson module", () => {
  it("Should get correct package.json with version", () => {
    Assert.ok(Utils.EnvioPackage.value->Utils.magic, ~message=`Should get package.json`)
    Assert.equal(Utils.EnvioPackage.value.version, "0.0.1-dev", ~message=`Should get dev version`)
  })
})
