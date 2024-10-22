
Deployed contract address:

0x1eb55edd0dff3ccdb916075e29ba516eea39b9d99b7935070f9fa1c018cb2391

## To generate the contract ts bindings run

`pnpm i -g fuels`

`pnpm fuels typegen -i <input-path>/all-events-abi.json -o <output-path> -c `

* Use <output-path> as src/contract dir
* This cmd only worked for me using the absolute path to the abi file, not the relative path.