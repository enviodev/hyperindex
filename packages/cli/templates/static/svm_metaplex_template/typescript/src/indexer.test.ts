import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

// `start_block` from config.yaml. Simulated instructions are placed by slot and
// only run when the slot is inside the configured range.
const START_SLOT = 417_920_000;

const METADATA_PDA = "6EEwsUpHqvbXNvSVBGxBhCiTdvGDMg2XSMzsFRQu3S9j";
const MINT = "4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R";
const AUTHORITY = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM";
const NEW_AUTHORITY = "3n1mGVcxZeEjTFxrKkbVfCkZ5DVQZbY9m2Ao8QwEMPLd";
const SIGNATURE =
  "5j7s6NiJS3JAkvgkoc18WVAsiSaci2pxB2A6ueCJP4tprA2TFg9wSyTLeYouxPBJEMzJinENTkpA52YStRW5Dia7";
const NAME = "Test Token";
const SYMBOL = "TEST";
const URI = "https://example.com/metadata.json";

const createArgs = {
  data: {
    name: NAME,
    symbol: SYMBOL,
    uri: URI,
    sellerFeeBasisPoints: 0,
    creators: null,
    collection: null,
    uses: null,
  },
  isMutable: true,
  collectionDetails: null,
};

describe("Metaplex Token Metadata handlers", () => {
  it("records the account a CreateMetadataAccountV3 opens", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        7565164: {
          simulate: [
            {
              program: "TokenMetadata",
              instruction: "CreateMetadataAccountV3",
              slot: START_SLOT,
              accounts: {
                metadata: { address: METADATA_PDA },
                mint: { address: MINT },
                updateAuthority: { address: AUTHORITY },
              },
              args: createArgs,
              transaction: { signature: SIGNATURE },
            },
          ],
        },
      },
    });

    t.expect(await indexer.TokenMetadataAccount.getOrThrow(METADATA_PDA)).toEqual({
      id: METADATA_PDA,
      mint: MINT,
      updateAuthority: AUTHORITY,
      name: NAME,
      symbol: SYMBOL,
      uri: URI,
      lastUpdatedSlot: START_SLOT,
      updateCount: 0,
      createdAtSlot: START_SLOT,
      lastTxSignature: SIGNATURE,
    });
  });

  it("counts an UpdateMetadataAccountV2 against the existing account", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        7565164: {
          simulate: [
            {
              program: "TokenMetadata",
              instruction: "CreateMetadataAccountV3",
              slot: START_SLOT,
              accounts: {
                metadata: { address: METADATA_PDA },
                mint: { address: MINT },
                updateAuthority: { address: AUTHORITY },
              },
              args: createArgs,
              transaction: { signature: SIGNATURE },
            },
            {
              program: "TokenMetadata",
              instruction: "UpdateMetadataAccountV2",
              slot: START_SLOT + 1,
              accounts: {
                metadata: { address: METADATA_PDA },
                updateAuthority: { address: AUTHORITY },
              },
              args: {
                data: null,
                newUpdateAuthority: NEW_AUTHORITY,
                primarySaleHappened: null,
                isMutable: null,
              },
              transaction: { signature: SIGNATURE },
            },
          ],
        },
      },
    });

    t.expect({
      account: await indexer.TokenMetadataAccount.getOrThrow(METADATA_PDA),
      stats: await indexer.ProgramStats.getOrThrow("metaplex-token-metadata"),
    }).toEqual({
      account: {
        id: METADATA_PDA,
        mint: MINT,
        updateAuthority: NEW_AUTHORITY,
        name: NAME,
        symbol: SYMBOL,
        uri: URI,
        lastUpdatedSlot: START_SLOT + 1,
        updateCount: 1,
        createdAtSlot: START_SLOT,
        lastTxSignature: SIGNATURE,
      },
      stats: {
        id: "metaplex-token-metadata",
        totalInstructions: 2,
        createCount: 1,
        updateCount: 1,
      },
    });
  });
});
