## Testing

### Run full tests

- install packages, run codegen and bring up docker:
    - `pnpm i`

    - `pnpm codegen`

    - `pnpm docker-up`

- Make sure to gen ts types in contracts dir `(cd contracts && npx hardhat compile)`

- Then run the tests and confirm all pass: 
    - `pnpm test`


### Clean up

run `pnpm docker-down`