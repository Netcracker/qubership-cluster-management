provider "aws" {
  region     = var.region
  access_key = var.local_endpoint != null ? "test" : null
  secret_key = var.local_endpoint != null ? "test" : null

  skip_credentials_validation = var.local_endpoint != null
  skip_metadata_api_check     = var.local_endpoint != null
  skip_requesting_account_id  = var.local_endpoint != null

  endpoints {
    ec2   = var.local_endpoint
    elbv2 = var.local_endpoint
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path != null ? var.kubeconfig_path : "${path.module}/../../../../.local-runtime/kubeconfig-${var.environment}.yaml"
}
