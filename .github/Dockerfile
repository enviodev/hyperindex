
#rescript base


FROM --platform=linux/amd64 node:18.14.0-bullseye-slim
WORKDIR /app/base-template


ENV PNPM_HOME /usr/local/binp
RUN npm install --global pnpm

RUN npm install --global envio

RUN envio init -t erc20 -l rescript

ARG COMMIT_HASH_ARG
ENV COMMIT_HASH=${COMMIT_HASH_ARG}

RUN envio codegen -d ./

