open Vitest

describe("Test PackageJson module", () => {
  it("Should get correct package.json with version", t => {
    t.expect(Utils.EnvioPackage.value->Utils.magic, ~message=`Should get package.json`).toBeTruthy()
    t.expect(Utils.EnvioPackage.value.version, ~message=`Should get dev version`).toBe("0.0.1-dev")
  })
})
