# Azure and Google Cloud

Terraform implementations exist, but real cloud deployment has not been performed.
Atmos does not load staging.yaml.example files. Complete the templates before enabling them as staging.yaml.
Providers use their standard authentication chains; catalog files do not contain credentials.

## Readiness of this guide

There are currently no active Azure/GCP stacks or configured local emulators in this project.
Copy-and-run apply and kubeconfig commands are therefore not provided: they require a subscription/project,
credentials, and verified endpoints. The steps below describe preparation, not a verified deployment sequence.
Add launch commands after connecting and testing the selected cloud or emulator.

## Azure

1. Install Azure CLI, run `az login`, and select the intended subscription.
2. Set ARM_SUBSCRIPTION_ID in stacks/customers/customer1/azure/staging.yaml.example.
3. Review region, network ranges, AKS service CIDR, VM size, quotas, and role-assignment permissions.
4. Copy the completed template to staging.yaml.

Create .local-runtime before retrieving kubeconfig if the directory does not exist.
AKS uses a separate managed identity with Network Contributor on its subnet.
workflows/azure.yaml contains an infrastructure workflow; its real deployment has not been verified.
Review individual component plans before a combined apply. Kubernetes requires an existing network.

## Google Cloud

1. Install gcloud and gke-gcloud-auth-plugin; run `gcloud auth application-default login`.
2. Set project_id, location, region, and real operator admin_cidrs in the GCP template, replacing the documentation-range CIDR.
3. Review billing, quotas, IAM, API-enablement permissions, and role-assignment permissions.
4. Copy the completed template to staging.yaml.

GKE uses a separate node pool and service account. node_count is per zone; the template uses a zonal location.
deletion_protection=true is enabled by default. Network provisioning enables Compute, Container, and IAM APIs
and does not disable them during resource deletion.
workflows/gcp.yaml contains an infrastructure workflow; its real deployment has not been verified.

## Load balancers

Import load-balancer catalogs explicitly once backends are known.
Azure requires resource_group_name/vpc_id from network, backend_addresses (name to private IP), and frontend/backend ports.
GCP requires backend_instances (VM self-links), port_range, and HTTP health-check settings.
Configure client/health-check firewall access for GCP and NSG/backend-port access for Azure.
These components do not automatically configure AKS/GKE ingress: Kubernetes manages Service LoadBalancer resources separately.

Helmfile templates retain laboratory settings, including anonymous Kiali access and Argo CD server.insecure.
Agree on TLS, authentication, storage classes, and persistence before exposing them externally.
