
#rescript base

FROM --platform=linux/amd64 node:18.14.0-bullseye-slim
WORKDIR /app/base-template

ENV PNPM_HOME /usr/local/binp
RUN npm install --global pnpm

ARG ENVIO_VERSION
RUN npm install --global envio@${ENVIO_VERSION}

ARG COMMIT_HASH_ARG
ENV COMMIT_HASH=${COMMIT_HASH_ARG}

RUN envio init -t erc20 -l rescript

