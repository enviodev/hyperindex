# Simple NFT contracts

Simple ERC721 smart contract factory used to create NFT collections.

# Events

NftFactory: - `event SimpleNftCreated(
        string name,
        string symbol,
        uint256 maxSupply,
        address contractAddress);`

SimpleNft: - `event Transfer(address indexed to, address indexed from, uint256 tokenid)`

# Deploying the contracts to Ganache

```
pnpm i
docker-compose -f ../../docker-compose.yaml up -d # NOTE: if you have some stale data, run docker down with `-v` first.
sleep 5 # ie wait for docker to finish setting things up
cd contracts; rm -rf deployments/ganache; pnpm deploy-factory
```

### To make example events:

```
# Create new nft collection
pnpm task:create-nft --name "<nft-name>" --symbol "<nft-symbol>" --supply <max_supply_int>
# Mint nft from a collection
pnpm task:mint-nft --address 0x756418B817E934f73Aa434DFaD4a686f836AA71d --quantity 2 --user-index 1
```
