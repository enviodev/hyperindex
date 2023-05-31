# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0



project = "nft-factory-indexer"

app "nft-factory-indexer" {
  labels = {
    "service" = "nft-factory-indexer"
    "env"     = "dev"
  }

  config {
    env = {
      PG_HOST     = "postgres-demo-cluster"
      PG_PORT     = 5432
      PG_USER     = "demouser"
      PG_DATABASE = "demo"
      SSL_MODE    = "require"
    
     PG_PASSWORD = dynamic("kubernetes", {
      name   = "demouser.postgres-demo-cluster.credentials.postgresql.acid.zalan.do" # Secret name
      key    = "password"
      secret = true
      namespace = "postgres"
    })
    }
  }

  build {
    use "docker" {}
    registry {
      use "aws-ecr" {
        region     = "us-east-2"
        repository = "envio-repository"
        tag        = "nft-indexer-fuji-59"
      }
    }
  }

  deploy {
    use "kubernetes" {
      namespace = "postgres"
      probe_path = "/_healthz"
    }
  }

   release {
    use "kubernetes" {
      namespace = "postgres"
      load_balancer = true
      port          = 80
    }
  }
}
