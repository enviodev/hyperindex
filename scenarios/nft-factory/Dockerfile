# FROM rust:1.69.0-slim-buster as builder
# WORKDIR /app

# COPY ./. .

# RUN cargo run --manifest-path ../../codegenerator/Cargo.toml -- codegen -c config.fuji.yaml

FROM --platform=linux/amd64 node:18.14.0-bullseye-slim
WORKDIR /app/nft-factory

# COPY --from=builder /app /app
COPY ./package.json ./package.json
COPY ./pnpm-workspace.yaml ./pnpm-workspace.yaml
COPY ./pnpm-lock.yaml ./pnpm-lock.yaml
# COPY ./tsconfig.json ./tsconfig.json
COPY ./.npmrc ./.npmrc
COPY ./generated ./generated

RUN rm -rf ./generated/node_modules

ENV PNPM_HOME /usr/local/binp
RUN npm install --global pnpm
# RUN npm install typescript -g

RUN pnpm fetch
RUN pnpm install -r --offline --filter .

COPY ./src ./src
ENV PATH "$PNPM_HOME:$PATH"

RUN cd generated && pnpm install -r --offline --filter .
RUN cd generated && pnpm build

COPY ./build ./build

CMD node -e 'require(`./generated/src/Migrations.bs.js`).setupDb()' && node build/generated/src/Index.bs.js

# && node -e build/generated/src/Index.bs.js
#node -e 'require(`./generated/src/Migrations.bs.js`).setupDb()' &&
# FROM rust:1.69.0-slim-buster as builder
# WORKDIR /usr/src/envios

# COPY ./codegenerator .

# RUN cargo install --path . 


# FROM node:18.14-alpine3.17 as final
# WORKDIR /app

# COPY --from=builder /usr/local/cargo/bin/envio /usr/local/bin/envio

# ENV PNPM_HOME /usr/local/binp
# RUN npm install --global pnpm

# ENV PATH "$PNPM_HOME:$PATH"

# COPY ./package.json ./package.json

# COPY ./pnpm-lock.yaml /app/
# COPY ./pnpm-workspace.yaml /app/pnpm-workspace.yaml
# COPY ./package.json /app/package.json
# RUN pnpm fetch

# RUN pnpm install -r --offline --filter .

# COPY ./. .

# RUN ln -s /tmp_build/* .

# RUN envio codegen

# RUN pnpm build

# CMD pnpm start
