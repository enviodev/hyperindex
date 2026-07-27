import { Provider, Wallet } from "fuels";
import dotenv from 'dotenv';
import {AllEventsFactory} from "./contract"

console.log("Starting deploying contracts");

dotenv.config();

const deploy = async () => {

    let mnemonic = process.env.MNEMONIC;
    if (!mnemonic) {
        throw new Error("Please provide a mnemonic in .env file");
    }
    let providerUrl = process.env.PROVIDER_URL;
    if (!providerUrl) {
        throw new Error("Please provide a provider url in .env file");
    }

    try {

        const provider = await Provider.create(providerUrl);
        const { consensusParameters } = provider.getChain();
        console.log("Consensus parameters: ", consensusParameters.chainId);

        // static fromMnemonic(mnemonic: string, path?: string, passphrase?: BytesLike, provider?: Provider): WalletUnlocked;
        const wallet = await Wallet.fromMnemonic(
          mnemonic,"m/44'/60'/0'/0/1",
          "",
          provider
        );

        console.log("Wallet address: ", wallet.address);
         
        const { balances } = await wallet.getBalances();
        
        // console.log('Balances', balances[0].amount.toString());
        console.log('Balances', balances);
        console.log(typeof balances);

    
        if (balances.length === 0) {
            throw new Error("No coins found in wallet");
        }

        let factory = new AllEventsFactory(wallet);        

        // Deploy the contract
        const { waitForResult, contractId, waitForTransactionId } = await factory.deploy();
        // Retrieve the transactionId
        const transactionId = await waitForTransactionId();

        console.log("Transaction Id: ", transactionId);

        // Await it's deployment
        const { contract, transactionResult } = await waitForResult();

        console.log("Contract deployed at: ", contractId);

        // Call the contract
        const { waitForResult: waitForCallResult } = await contract.functions.log().call();
        // Await the result of the call
        const { value } = await waitForCallResult();

        console.log("Call result: ", value);
        
    } catch (e) {
        console.log(e);
    }
}

deploy();