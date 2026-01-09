terraform {
  backend "local" {
    path = "../state/gcp_databases.tfstate"
  }
}
