
FROM --platform=linux/amd64 node:18.14.0-bullseye-slim
WORKDIR /app/nft-factory

COPY ./package.json ./package.json
COPY ./pnpm-workspace.yaml ./pnpm-workspace.yaml
COPY ./pnpm-lock.yaml ./pnpm-lock.yaml
COPY ./tsconfig.json ./tsconfig.json
COPY ./hardhat.config.ts ./hardhat.config.ts

COPY ./.npmrc ./.npmrc
COPY ./generated ./generated

RUN rm -rf ./generated/node_modules

ENV PNPM_HOME /usr/local/binp
RUN npm install --global pnpm

RUN pnpm fetch
RUN pnpm install -r --filter .

COPY ./src ./src
ENV PATH "$PNPM_HOME:$PATH"

RUN cd generated && pnpm fetch
RUN cd generated && pnpm install --no-frozen-lockfile -r --offline --filter .
RUN cd generated && pnpm clean
RUN cd generated && pnpm build

RUN pnpm build

CMD node -e 'require(`./generated/src/Migrations.bs.js`).setupDb()' && node build/generated/src/Index.bs.js
