"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const hardhat_network_helpers_1 = require("@nomicfoundation/hardhat-network-helpers");
const hardhat_1 = require("hardhat");
const Greeter_behavior_1 = require("./Greeter.behavior");
const Greeter_fixture_1 = require("./Greeter.fixture");
describe("Unit tests", function () {
    before(async function () {
        this.signers = {};
        const signers = await hardhat_1.ethers.getSigners();
        this.signers.admin = signers[0];
        this.loadFixture = hardhat_network_helpers_1.loadFixture;
    });
    describe("Greeter", function () {
        beforeEach(async function () {
            const { greeter } = await this.loadFixture(Greeter_fixture_1.deployGreeterFixture);
            this.greeter = greeter;
        });
        (0, Greeter_behavior_1.shouldBehaveLikeGreeter)();
    });
});
