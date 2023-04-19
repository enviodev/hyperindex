# Run this full scenario

Run from the `./scenarios/gravatar` directory:

```
pnpm i
pnpm build
docker-compose -f ../../docker-compose.yaml up -d # NOTE: if you have some stale data, run docker down with `-v` first.
sleep 5 # ie wait for docker to finish setting things up
cd contracts; pnpm deploy-gravatar; cd ../
PG_PORT=5433 pnpm start
```

## Build

```

pnpm run build

```

# Watch

```

pnpm run watch

```

```

```
