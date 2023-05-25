FROM rust:1.69.0 as builder
WORKDIR /base/nft-factory

COPY ./codegenerator /base/codegenerator
COPY ./scenarios/nft-factory .

RUN cargo install --path ../codegenerator

RUN envio codegen 

FROM --platform=linux/amd64 node:18.14.0-bullseye-slim as final
WORKDIR /app

COPY --from=builder /base/nft-factory /app

ENV PNPM_HOME /usr/local/binp
RUN npm install --global pnpm

ENV PATH "$PNPM_HOME:$PATH"

RUN pnpm build

RUN  node -e 'require(`./generatd/src/Migrations.bs.js`).setupDb()'

ENTRYPOINT ["pnpm start"]


# FROM rust:1.69.0-slim-buster as builder
# WORKDIR /base

# COPY ./codegenerator .

# RUN cargo build --release

# FROM --platform=linux/amd64 node:18.14.0-bullseye-slim as final
# WORKDIR /app

# COPY --from=builder /base/target/release/envio /app/envio

# ENV PNPM_HOME /usr/local/binp
# RUN npm install --global pnpm

# ENV PATH "$PNPM_HOME:$PATH"

# COPY ./scenarios/nft-factory/. .
# COPY ./start.sh .


# # RUN pnpm build

# RUN chmod +x start.sh

# ENTRYPOINT ["./start.sh"]
