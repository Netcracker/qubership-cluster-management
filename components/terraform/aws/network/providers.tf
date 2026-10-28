provider "aws" {
  region     = var.region
  access_key = var.local_endpoint != null ? "test" : null
  secret_key = var.local_endpoint != null ? "test" : null

  skip_credentials_validation = var.local_endpoint != null
  skip_metadata_api_check     = var.local_endpoint != null
  skip_requesting_account_id  = var.local_endpoint != null

  endpoints {
    ec2 = var.local_endpoint
  }
}