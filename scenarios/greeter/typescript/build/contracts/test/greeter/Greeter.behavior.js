"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.shouldBehaveLikeGreeter = void 0;
const chai_1 = require("chai");
function shouldBehaveLikeGreeter() {
    it("should return the new greeting once it's changed", async function () {
        (0, chai_1.expect)(await this.greeter.connect(this.signers.admin).greet()).to.equal("Hello, world!");
        await this.greeter.setGreeting("Bonjour, le monde!");
        (0, chai_1.expect)(await this.greeter.connect(this.signers.admin).greet()).to.equal("Bonjour, le monde!");
    });
}
exports.shouldBehaveLikeGreeter = shouldBehaveLikeGreeter;
