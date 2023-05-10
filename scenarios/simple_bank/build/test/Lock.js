"use strict";
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
const { time, loadFixture, } = require("@nomicfoundation/hardhat-network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
describe("Lock", function () {
    // We define a fixture to reuse the same setup in every test.
    // We use loadFixture to run this setup once, snapshot that state,
    // and reset Hardhat Network to that snapshot in every test.
    function deployOneYearLockFixture() {
        return __awaiter(this, void 0, void 0, function* () {
            const ONE_YEAR_IN_SECS = 365 * 24 * 60 * 60;
            const ONE_GWEI = 1000000000;
            const lockedAmount = ONE_GWEI;
            const unlockTime = (yield time.latest()) + ONE_YEAR_IN_SECS;
            // Contracts are deployed using the first signer/account by default
            const [owner, otherAccount] = yield ethers.getSigners();
            const Lock = yield ethers.getContractFactory("Lock");
            const lock = yield Lock.deploy(unlockTime, { value: lockedAmount });
            return { lock, unlockTime, lockedAmount, owner, otherAccount };
        });
    }
    describe("Deployment", function () {
        it("Should set the right unlockTime", function () {
            return __awaiter(this, void 0, void 0, function* () {
                const { lock, unlockTime } = yield loadFixture(deployOneYearLockFixture);
                expect(yield lock.unlockTime()).to.equal(unlockTime);
            });
        });
        it("Should set the right owner", function () {
            return __awaiter(this, void 0, void 0, function* () {
                const { lock, owner } = yield loadFixture(deployOneYearLockFixture);
                expect(yield lock.owner()).to.equal(owner.address);
            });
        });
        it("Should receive and store the funds to lock", function () {
            return __awaiter(this, void 0, void 0, function* () {
                const { lock, lockedAmount } = yield loadFixture(deployOneYearLockFixture);
                expect(yield ethers.provider.getBalance(lock.address)).to.equal(lockedAmount);
            });
        });
        it("Should fail if the unlockTime is not in the future", function () {
            return __awaiter(this, void 0, void 0, function* () {
                // We don't use the fixture here because we want a different deployment
                const latestTime = yield time.latest();
                const Lock = yield ethers.getContractFactory("Lock");
                yield expect(Lock.deploy(latestTime, { value: 1 })).to.be.revertedWith("Unlock time should be in the future");
            });
        });
    });
    describe("Withdrawals", function () {
        describe("Validations", function () {
            it("Should revert with the right error if called too soon", function () {
                return __awaiter(this, void 0, void 0, function* () {
                    const { lock } = yield loadFixture(deployOneYearLockFixture);
                    yield expect(lock.withdraw()).to.be.revertedWith("You can't withdraw yet");
                });
            });
            it("Should revert with the right error if called from another account", function () {
                return __awaiter(this, void 0, void 0, function* () {
                    const { lock, unlockTime, otherAccount } = yield loadFixture(deployOneYearLockFixture);
                    // We can increase the time in Hardhat Network
                    yield time.increaseTo(unlockTime);
                    // We use lock.connect() to send a transaction from another account
                    yield expect(lock.connect(otherAccount).withdraw()).to.be.revertedWith("You aren't the owner");
                });
            });
            it("Shouldn't fail if the unlockTime has arrived and the owner calls it", function () {
                return __awaiter(this, void 0, void 0, function* () {
                    const { lock, unlockTime } = yield loadFixture(deployOneYearLockFixture);
                    // Transactions are sent using the first signer by default
                    yield time.increaseTo(unlockTime);
                    yield expect(lock.withdraw()).not.to.be.reverted;
                });
            });
        });
        describe("Events", function () {
            it("Should emit an event on withdrawals", function () {
                return __awaiter(this, void 0, void 0, function* () {
                    const { lock, unlockTime, lockedAmount } = yield loadFixture(deployOneYearLockFixture);
                    yield time.increaseTo(unlockTime);
                    yield expect(lock.withdraw())
                        .to.emit(lock, "Withdrawal")
                        .withArgs(lockedAmount, anyValue); // We accept any value as `when` arg
                });
            });
        });
        describe("Transfers", function () {
            it("Should transfer the funds to the owner", function () {
                return __awaiter(this, void 0, void 0, function* () {
                    const { lock, unlockTime, lockedAmount, owner } = yield loadFixture(deployOneYearLockFixture);
                    yield time.increaseTo(unlockTime);
                    yield expect(lock.withdraw()).to.changeEtherBalances([owner, lock], [lockedAmount, -lockedAmount]);
                });
            });
        });
    });
});
