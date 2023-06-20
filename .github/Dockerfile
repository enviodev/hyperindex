
#rescript base

FROM --platform=linux/amd64 node:18.14.0-bullseye-slim
WORKDIR /app/base-template


ENV PNPM_HOME /usr/local/binp
RUN npm install --global pnpm

RUN npm install --global envio@v.0.0.1-base.1

RUN envio init -t erc20 -l rescript

ENV COMMIT_HASH=${COMMIT_HASH}

RUN envio codegen -d ./

