extern crate dotenv;

use dotenv::dotenv;
use fuels::prelude::*;
use fuels::types::{Bits256, ContractId};
use std::env;
use std::str::FromStr;

abigen!(Contract(
    name = "AllEvents",
    abi = "../all-events/out/debug/all-events-abi.json"
),);

const ALL_EVENTS_CONTRACT: &str =
    "0x54a4b027fca0f718d3cb0cbdddb1beec670100b70c6856824befac0440dc0b84";

#[tokio::main]
async fn main() -> Result<()> {
    // Load .env file
    dotenv().ok();

    let phrase = env::var("MNEMONIC").expect("MNEMONIC must be set in .env");

    let provider = Provider::connect("testnet.fuel.network").await.unwrap();

    let wallet = WalletUnlocked::new_from_mnemonic_phrase_with_path(
        &phrase,
        Some(provider.clone()),
        "m/44'/1179993420'/0'/0/0",
    )
    .unwrap();

    let base_asset_id =
        AssetId::from_str("0xf8f8b6283d7fa5b672b530cbb84fcccb4ff8dc40f8176ef4544ddb1f1952ad07")
            .unwrap();

    let balance = provider
        .get_asset_balance(wallet.address(), base_asset_id)
        .await?;
    // let chain_id = provider.chain_id();

    if balance < 500000 {
        println!("Wallet address {}, with balance {}, can use the faucet here: https://faucet-testnet.fuel.network/?address={}", wallet.address(), balance, wallet.address());
        return Ok(());
    }

    let all_events_contract_id =
        ContractId::from_str(ALL_EVENTS_CONTRACT).expect("failed to create ContractId from string");

    let all_events = AllEvents::new(all_events_contract_id, wallet.clone());

    let r = all_events.methods().log().call().await?;
    println!("log in tx: {:?}", r.tx_id);

    // Documentation https://docs.fuel.network/docs/fuels-ts/contracts/minted-token-asset-id/#minted-token-asset-id
    let sub_id =
        Bits256::from_hex_str("0xc7fd1d987ada439fc085cfa3c49416cf2b504ac50151e3c2335d60595cb90745")
            .unwrap();
    let r = all_events.methods().mint_coins(sub_id, 1000).call().await?;
    println!("mint_coins in tx: {:?}", r.tx_id);
    let r = all_events.methods().burn_coins(sub_id, 500).call().await?;
    println!("burn_coins in tx: {:?}", r.tx_id);

    println!(
        "Finished populating receipts on the contract: {}",
        ALL_EVENTS_CONTRACT
    );

    Ok(())
}
