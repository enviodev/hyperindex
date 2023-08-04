import { expect } from "chai";
import {
  packEventIndexFromRecord,
  unpackEventIndex,
} from "../generated/src/EventUtils.bs";

// require("mocha-reporter").hook(); //Outputs filename in error logs with mocha-reporter

type eventIdRecord = { blockNumber: number; logIndex: number };

describe("Test eventIndex packing 1", () => {
  it("Test eventIndex packing 1", () => {
    let mockEventIndex1: eventIdRecord = {
      //10000000000000000
      blockNumber: 1,
      //1
      logIndex: 1,
    };
    //packed binary 10000000000000001
    //packed decimal
    let packed = packEventIndexFromRecord(mockEventIndex1);

    let unpacked = unpackEventIndex(packed);
    expect(packed).to.be.eq(65537n);
    expect(unpacked.blockNumber).to.be.eq(mockEventIndex1.blockNumber);
    expect(unpacked.logIndex).to.be.eq(mockEventIndex1.logIndex);
  });

  it("Test eventIndex packing 2", () => {
    let mockEventIndex2: eventIdRecord = {
      //1011011110001111011111001001 binary
      blockNumber: 192477129, //12614181191679  when shifted 16
      //10
      logIndex: 2,
    };
    //packed binary 10110111100011110111110010010000000000000010
    //packend int 12614181126146
    let packed = packEventIndexFromRecord(mockEventIndex2);
    let unpacked = unpackEventIndex(packed);
    expect(packed).to.be.eq(12614181126146n);
    expect(unpacked.blockNumber).to.be.eq(mockEventIndex2.blockNumber);
    expect(unpacked.logIndex).to.be.eq(mockEventIndex2.logIndex);
  });

  //packed binary 10110111100011110111110010010000001001000110
  //packed int 12614181126726

  it("Test eventIndex packing 3", () => {
    let mockEventIndex3: eventIdRecord = {
      //1011011110001111011111001001
      blockNumber: 192477129,
      //1000110
      logIndex: 70,
    };
    //packed binary 10110111100011110111110010010000000001000110
    //packend int 12614181126214
    let packed = packEventIndexFromRecord(mockEventIndex3);
    let unpacked = unpackEventIndex(packed);
    expect(packed).to.be.eq(12614181126214n);
    expect(unpacked.blockNumber).to.be.eq(mockEventIndex3.blockNumber);
    expect(unpacked.logIndex).to.be.eq(mockEventIndex3.logIndex);
  });
});

describe("Test packed eventIds are orderable by logIndex", () => {
  let mockEventIndex1: eventIdRecord = {
    blockNumber: 1,
    logIndex: 1,
  };
  Array(10)
    .fill(mockEventIndex1)
    .reduce((currentEventIndex: eventIdRecord) => {
      let nextEventIndex: eventIdRecord = {
        ...currentEventIndex,
        logIndex: currentEventIndex.logIndex + 1,
      };
      it(`Test eventIndex ordering, blockNumber 1, logIndex: ${currentEventIndex.logIndex} -> ${nextEventIndex.logIndex}`, () => {
        let packedEventIndex1 = packEventIndexFromRecord(currentEventIndex);

        let packedEventIndex2 = packEventIndexFromRecord(nextEventIndex);

        expect(packedEventIndex1 < packedEventIndex2).to.be.true;
      });

      return nextEventIndex;
    }, mockEventIndex1);
});

describe("Test packed eventIds are orderable by blockNumber", () => {
  let mockEventIndex1: eventIdRecord = {
    blockNumber: 19541,
    logIndex: 0,
  };

  Array(10)
    .fill(mockEventIndex1)
    .reduce((currentEventIndex: eventIdRecord) => {
      let nextEventIndex = {
        blockNumber: currentEventIndex.blockNumber + 1,
        logIndex: Math.floor(Math.random() * 70),
      };
      it(`Test eventIndex ordering, blockNumber ${currentEventIndex.blockNumber} -> ${nextEventIndex.blockNumber},
      logIndex ${currentEventIndex.logIndex} -> ${nextEventIndex.logIndex}`, () => {
        let packedEventIndex1 = packEventIndexFromRecord(currentEventIndex);

        let packedEventIndex2 = packEventIndexFromRecord(nextEventIndex);

        expect(packedEventIndex1 < packedEventIndex2).to.be.true;
      });

      return nextEventIndex;
    }, mockEventIndex1);
});
