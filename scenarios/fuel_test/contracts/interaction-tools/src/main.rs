extern crate dotenv;

use dotenv::dotenv;
use fuels::prelude::*;
use fuels::types::{AssetId, Bits256};
use rand::Rng;
use std::env;
use std::str::FromStr;

abigen!(Contract(
    name = "AllEvents",
    abi = "../all-events/out/debug/all-events-abi.json"
),);

#[tokio::main]
async fn main() -> Result<()> {
    // Load .env file
    dotenv().ok();
    let phrase = env::var("MNEMONIC").expect("MNEMONIC must be set in .env");
    let provider = Provider::connect("testnet.fuel.network").await.unwrap();
    let wallet = WalletUnlocked::new_from_mnemonic_phrase(&phrase, Some(provider.clone())).unwrap();
    let base_asset_id =
        AssetId::from_str("0xf8f8b6283d7fa5b672b530cbb84fcccb4ff8dc40f8176ef4544ddb1f1952ad07")
            .unwrap();
    let balance = provider
        .get_asset_balance(wallet.address(), base_asset_id)
        .await?;
    if balance < 500000 {
        println!("Wallet address {}, with balance {}, can use the faucet here: https://faucet-testnet.fuel.network/?address={}", wallet.address(), balance, wallet.address());
        return Ok(());
    }

    // Random Salt to deploy a new contract on every run
    let mut salt = [0u8; 32];
    rand::thread_rng().fill(&mut salt);

    let greeter_contract_id =
        ContractId::from_str("0xb9bc445e5696c966dcf7e5d1237bd03c04e3ba6929bdaedfeebc7aae784c3a0b")?;

    let contract_id = Contract::load_from(
        "../all-events/out/debug/all-events.bin",
        LoadConfiguration::default().with_salt(salt),
    )?
    .deploy(&wallet, TxPolicies::default())
    .await?;
    println!("Deployed AllEvents contract: 0x{}", contract_id.hash);

    let contract_methods = AllEvents::new(contract_id.clone(), wallet.clone()).methods();

    // Testing LogData receipts
    let r = contract_methods.log().call().await?;
    println!("Logs in tx: 0x{}", r.tx_id.unwrap());

    // LiquidityPool - deposit and withdraw for testing Mint/Burn/Call/TransferOut receipts
    let deposit_amount = 100;
    let call_params = CallParameters::default()
        .with_amount(deposit_amount)
        .with_asset_id(base_asset_id);
    let r = contract_methods
        .deposit(wallet.address().into())
        .call_params(call_params)?
        .with_variable_output_policy(VariableOutputPolicy::Exactly(1))
        .call()
        .await?;
    println!("Deposited 100 coins to LP in tx: 0x{}", r.tx_id.unwrap());
    let lp_asset_id = contract_id.asset_id(&Bits256::zeroed());
    let lp_token_balance = wallet.get_asset_balance(&lp_asset_id).await?;
    let call_params = CallParameters::default()
        .with_amount(lp_token_balance)
        .with_asset_id(lp_asset_id);
    let r = contract_methods
        .withdraw(wallet.address().into())
        .call_params(call_params)?
        .with_variable_output_policy(VariableOutputPolicy::Exactly(1))
        .with_contract_ids(&[greeter_contract_id.into()])
        .call()
        .await?;
    println!(
        "Withdrawn {} tokens from LP in tx: 0x{}",
        lp_token_balance,
        r.tx_id.unwrap()
    );

    println!("Successfully finished mock interactions with the contract: 0x{contract_id}",);

    Ok(())
}
