open RescriptMocha

describe("Test PackageJson module", () => {
  it("Should get correct package.json with version", () => {
    Assert.ok(Utils.EnvioPackage.json->Utils.magic, ~message=`Should get package.json`)
    Assert.equal(
      Utils.EnvioPackage.json.version,
      Some("0.0.1-dev"),
      ~message=`Should get dev version`,
    )
  })
})
