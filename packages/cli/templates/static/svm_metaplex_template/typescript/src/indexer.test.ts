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
                update_authority: { address: AUTHORITY },
              },
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
                update_authority: { address: AUTHORITY },
              },
              transaction: { signature: SIGNATURE },
            },
            {
              program: "TokenMetadata",
              instruction: "UpdateMetadataAccountV2",
              slot: START_SLOT + 1,
              accounts: {
                metadata: { address: METADATA_PDA },
                update_authority: { address: NEW_AUTHORITY },
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
