# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0



project = "nft-factory-indexer"

app "nft-factory-indexer" {
  config {
    env = {
      PG_HOST     = "postgres-demo-cluster"
      PG_PORT     = 5432
      PG_USER     = "demouser"
      PG_DATABASE = "demo"
    
     PG_PASSWORD = dynamic("kubernetes", {
      name   = "postgres.postgres-demo-cluster.credentials.postgresql.acid.zalan.do" # Secret name
      key    = "password"
      secret = true
    })
    }
  }

  labels = {
    "service" = "nft-factory-indexer"
  }

  build {
    use "docker" {}
    registry {
      use "aws-ecr" {
        region     = "us-east-2"
        repository = "envio-repository"
        tag        = "nft-indexer-fuji-22"
      }
    }
  }

  deploy {
    use "kubernetes" {
      namespace = "postgres"
    }
  }

   release {
    use "kubernetes" {
       namespace = "postgres"
    }
  }
}
