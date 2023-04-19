# Run this full scenario

Run from the `./scenarios/gravatar` directory:

```
pnpm i
pnpm build
docker-compose -f ../../docker-compose.yaml up -d # NOTE: if you have some stale data, run docker down with `-v` first.
sleep 5 # ie wait for docker to finish setting things up
cd contracts; rm -rf deployments/ganache; pnpm deploy-gravatar; cd ../
PG_PORT=5433 pnpm start
```

To view the data in the database, run `./generated/register_tables_with_hasura.sh` and open http://localhost:8080/console.

Alternatively you can open the file `index.html` for a cleaner experience (no hasura stuff). Unfortunately, hasura currently isn't configured to make the data public.

### To make example events:

```
# Create gravatar
pnpm task:new-gravatar --name "Jason Smythe" --image "https://jason.smythe.com/man-with-amazing-mustache.jpg" --user-index 8
# Update gravatar image
pnpm task:update-gravatar-image --image "https://jono.prest.com/what-a-shiny-trumpet.jpg" --user-index 8
# Update gravatar name
pnpm task:update-gravatar-name --name "Jono Prest" --user-index 8
```

## Build

```

pnpm run build

```

# Watch

```

pnpm run watch

```
