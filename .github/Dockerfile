
#rescript base

# FROM  --platform=linux/amd64  node:18.16.1-bookworm-slim
FROM --platform=linux/amd64 node:20.4.0-bookworm-slim # Testing differen versions for 
WORKDIR /app/base-template

RUN apt-get update
RUN apt-get install -y wget

RUN wget http://nz2.archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2.19_amd64.deb
RUN dpkg -i libssl1.1_1.1.1f-1ubuntu2.19_amd64.deb

ENV PNPM_HOME /usr/local/binp
RUN npm install --global pnpm

ARG ENVIO_VERSION
RUN npm install --global envio@${ENVIO_VERSION}

ARG COMMIT_HASH_ARG
ENV COMMIT_HASH=${COMMIT_HASH_ARG}

RUN envio init --name erc20indexer -t erc20 -l rescript

