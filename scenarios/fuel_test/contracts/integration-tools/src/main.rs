extern crate dotenv;

use dotenv::dotenv;
use fuels::prelude::*;
use fuels::types::ContractId;
use std::env;
use std::str::FromStr;

abigen!(Contract(
    name = "AllEvents",
    abi = "../all-events/out/debug/all-events-abi.json"
),);

const ALL_EVENTS_CONTRACT: &str = "0x9a719b1ff9db28f1493375b06ad0195370786e217473eacc4be973ecd6281420";

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

    let all_events_contract_id = ContractId::from_str(ALL_EVENTS_CONTRACT)
        .expect("failed to create ContractId from string");

    let all_events = AllEvents::new(all_events_contract_id, wallet.clone());

    all_events.methods().log().call().await?;

    println!("Log called");

    Ok(())
}
