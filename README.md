# Qubership Cluster Manager

Infrastructure and Kubernetes application management with **Atmos, Terraform, and Helmfile**.
The repository separates reusable implementations from customer configuration, so new customers,
clouds, environments, and components can be added without copying an entire deployment.

Current deployments are local laboratories backed by Floci. Deployment to real cloud accounts has not been verified.

## Architecture

Deployments are organized as **customer → cloud → environment**.

See the [five-page architecture diagrams](docs/diagrams/README.md) for AWS request routing, deployment and deletion,
file dependencies, ports/RBAC, and the Azure local environment. An [editable draw.io document](docs/diagrams/atmos-local-demo.drawio)
and PNG previews are included.

```text
Customer defaults                 tenant: customer1
  └─ Cloud defaults               cloud: aws or azure, region, tool environment
       └─ Environment manifest    stage: staging, resource names, component overrides
            + Imported catalogs  shared component configuration
                    │
                    ▼
             Resolved Atmos stack
                    │
             Customer workflow
               ├─ Terraform → cloud infrastructure
               ├─ Local preparation → Kubernetes access
               └─ Helmfile → applications inside Kubernetes
```

| Part | Responsibility | Location |
|---|---|---|
| Atmos configuration | File discovery, component paths, and stack names | [atmos.yaml](atmos.yaml) |
| Component implementation | Creates infrastructure or installs a chart | [components/](components/) |
| Catalog | Shared configuration and selection of a component implementation | [stacks/catalog/](stacks/catalog/) |
| Customer stack | Imports defaults/catalogs and overrides deployment parameters | [stacks/customers/](stacks/customers/) |
| Workflow | Apply/destroy order, preparation, parallel branches, and readiness | [workflows/customers/](workflows/customers/) |
| Local tooling | Starts emulators and prepares Kubernetes access | [local/](local/) |

A **stack** describes what configuration to use. A **workflow** describes what commands to run and in what order.
Importing a catalog merges configuration; it does not provision resources.

For example, the Azure staging manifest imports customer/cloud defaults and the Azure network catalog.
Atmos resolves its name as `customer1-azure-staging`. The catalog maps the logical component `network`
to `components/terraform/azure/network/`; the workflow runs Terraform with that stack's parameters.
Kubernetes consumes the resource group and subnet outputs from network state.

### Shared components and deployment-specific values

Terraform components are separate root modules with their own inputs, outputs, and state.
Cloud-specific implementations share logical names such as `network`, `kubernetes`, and `load-balancer`.
Their capabilities and required inputs can differ between clouds.

Helmfile components are shared across clouds: **Istio, Argo CD, Kiali, MinIO, and Headlamp**.
Each component contains its Helmfile and adjacent values templates. Atmos supplies the selected stack's values.

The shared chart settings live under `stacks/catalog/helmfile/`, rather than directly in those values templates.
Some catalog files currently use JSON syntax inside `.yaml` files; Atmos reads them as YAML mappings.
This is a serialization choice, not another configuration layer or an Atmos requirement.
For Kiali, the Custom Resource settings are in `components.helmfile.kiali.vars.values.cr`
in [the Kiali catalog](stacks/catalog/helmfile/kiali.yaml). The operator chart renders the actual `kind: Kiali` manifest.
See [where Helm settings live and how Kiali is created](docs/architecture.md#where-helm-settings-live) for the complete file chain.

```text
Catalog defaults + customer/environment overrides
    → Atmos component vars
    → Helmfile state values
    → values*.yaml.gotmpl
    → Helm chart
```

Changing a shared implementation affects every stack using it. Customer-specific settings belong in stack manifests.
Terraform state/workspaces, resource names, and kubeconfig files must remain separate for each deployment.

## Repository layout

```text
atmos.yaml
components/
  terraform/
    aws/                     network, kubernetes, load-balancer, nexus
    azure/                   network, kubernetes, load-balancer
    gcp/                     network, kubernetes, load-balancer
  helmfile/                  argocd, istio, kiali, minio, headlamp
stacks/
  catalog/                   aws, azure, gcp, helmfile configuration
  customers/
    customer1/
      _defaults.yaml
      aws/                   defaults + active staging manifest
      azure/                 defaults + active staging manifest + real-cloud template
      gcp/                   defaults + inactive staging template
    customer2/
      _defaults.yaml
      aws/                   defaults + active staging manifest
workflows/
  customers/customer1/       aws.yaml, azure.yaml
  customers/customer2/       aws.yaml
  azure.yaml                 infrastructure-only workflow
  gcp.yaml                   infrastructure-only workflow
  helmfile.yaml              shared application workflow
local/
  compose.yml                AWS emulator and UI
  compose.azure.yml          Azure emulator
  settings.example.json      AWS local settings template
  scripts/                   start/stop, cluster access, readiness, validation
.local-runtime/              generated kubeconfigs and local runtime files
docs/                        detailed reference guides
```

Files ending in `.yaml.example` are inactive templates. Directory nesting alone does not create inheritance;
stack manifests explicitly import defaults and catalogs. Runtime files, local settings, emulator data,
and Terraform state are excluded from Git.

## Available environments

| Stack | Current scope | Workflow file |
|---|---|---|
| `customer1-aws-staging` | Local Floci: network, Kubernetes, Nexus, five application components, ALB | [customer1/aws.yaml](workflows/customers/customer1/aws.yaml) |
| `customer2-aws-staging` | Separate local AWS stack: network, Kubernetes, five application components | [customer2/aws.yaml](workflows/customers/customer2/aws.yaml) |
| `customer1-azure-staging` | Local Floci Azure: network, Kubernetes, five application components, TCP load balancer configuration | [customer1/azure.yaml](workflows/customers/customer1/azure.yaml) |
| GCP | Terraform implementations and inactive stack template; deployment not verified | [gcp.yaml](workflows/gcp.yaml) |

Customer1 AWS creates network and Kubernetes, prepares access, then runs Nexus/readiness and applications/ALB
in parallel. `deploy-staging` checks Nexus through a hook; `deploy-staging-no-hook` uses an explicit readiness step.
Both operate on the same resources.

Azure runs network → Kubernetes → access preparation → applications → load balancer sequentially.
Its Helm releases and application HTTP responses have been checked locally.

### Azure emulator limitations

- Floci Azure stores Load Balancer configuration but does not forward traffic through it. The current TCP rule targets Kiali's NodePort; application access uses Kubernetes port forwarding. See the [Floci Network limitations](https://github.com/floci-io/floci-az/blob/1edf29aded8535febe9de1067604a0a706c8ebd6/docs/services/network.md#scope-and-limitations).
- The installed emulator omits some AKS properties when reading resources back. A subsequent Kubernetes plan has proposed cluster replacement. **Review the plan before repeating infrastructure apply.**
- The local Azure stack disables the subnet role assignment because the emulator did not supply the required RBAC APIs. The Terraform module keeps role assignment enabled by default.
- The load balancer backend is the local k3s Docker IP recorded in the stack. Recheck it after cluster recreation.
- Azure Compose pins a nightly image by digest. Start-AzureLocal installs the emulator CA into the current Windows user's trusted root store.

These local settings do not establish production readiness for Azure or the other clouds.

## Running the local environments

Run commands from the repository root in **PowerShell 7**, with Docker Desktop's Linux engine running.
Required tools are Atmos, Terraform, kubectl, Helm, Helmfile, and helm-diff; AWS also requires AWS CLI.
Azure startup uses Windows `curl.exe` and the current user's certificate store.
Internet access is needed for providers, charts, and container images.
Review the configured proxy `127.0.0.1:12334` for your machine and bypass proxies for local endpoints.
See [local development](docs/local-development.md) for AWS settings and script details.

### AWS: customer1

```powershell
pwsh -NoProfile -File ./local/scripts/Start-Local.ps1
atmos workflow deploy-staging-no-hook -f customers/customer1/aws
```

Use `deploy-staging` instead for hook-based Nexus readiness. Choose one deployment variant per run.
Start only starts the emulator services; deployment creates customer resources.

### Azure: start and inspect

```powershell
pwsh -NoProfile -File ./local/scripts/Start-AzureLocal.ps1
atmos workflow deploy-staging -f customers/customer1/azure --dry-run
atmos terraform plan kubernetes -s customer1-azure-staging -input=false
```

The complete deployment workflow is `deploy-staging` in `customers/customer1/azure`.
The Kubernetes plan requires existing network state. For a fresh environment, network must be applied first.
Because of the AKS replacement limitation above, inspect the infrastructure plan before a full deployment again.
For an existing cluster, refresh access and apply applications/load balancer without applying network or Kubernetes:

```powershell
atmos workflow deploy-staging -f customers/customer1/azure --from-step access
```

To open the Azure applications, run each command in a separate terminal and leave it running:

```powershell
kubectl --kubeconfig ./.local-runtime/kubeconfig-customer1-azure-staging.yaml -n argocd port-forward svc/argocd-server 18080:80
kubectl --kubeconfig ./.local-runtime/kubeconfig-customer1-azure-staging.yaml -n istio-system port-forward svc/kiali 18081:20001
```

Open Argo CD at http://localhost:18080 and Kiali at http://localhost:18081.
These endpoints have returned HTTP 200 through port forwarding.

### Delete resources before stopping emulators

Customer1 AWS supports sequential `destroy-staging` and parallel `destroy-staging-parallel`.
Azure has sequential `destroy-staging`. Customer1 Terraform apply/destroy steps use `-auto-approve`.

AWS:

```powershell
atmos workflow destroy-staging-parallel -f customers/customer1/aws
if ($LASTEXITCODE -ne 0) { throw 'Deletion failed. Floci has been left running.' }
pwsh -NoProfile -File ./local/scripts/Stop-Local.ps1
```

Azure:

```powershell
atmos workflow destroy-staging -f customers/customer1/azure
if ($LASTEXITCODE -ne 0) { throw 'Deletion failed. Floci Azure has been left running.' }
docker compose -f ./local/compose.azure.yml stop
```

Azure destroy and AWS parallel destroy have been checked with dry-run; real end-to-end deletion has not been verified.
Destroy removes the load balancer and applications before Kubernetes, and network last.
The Kiali custom resource is removed before its operator so finalizers can complete.
Stop retains local data and Terraform state. Do not run concurrent workflows against the same stack.

## Extending the project

| Addition | Files to add or change |
|---|---|
| Customer | Customer defaults, cloud/environment manifests, and customer workflows |
| Environment | A final manifest with distinct stage, resource identity, workspace, and kubeconfig |
| Terraform component | Implementation under the cloud directory, catalog, stack import/inputs, workflow steps |
| Application | Shared Helmfile/values component, Helmfile catalog, stack import/overrides, workflow steps |

Keep execution dependencies explicit: create inputs before their consumers, and delete consumers before their inputs.

## Further documentation

- [Architecture reference](docs/architecture.md): Atmos discovery, imports, component contracts, state, Helmfile values, and AWS workflow internals. The Azure overview above reflects the newer local integration.
- [Local development reference](docs/local-development.md): detailed AWS script responsibilities, prerequisites, readiness, access, and troubleshooting.
- [Cloud preparation](docs/deployment.md): real-cloud preparation for Azure/GCP and load balancer inputs. Its inactive-Azure statements predate the local integration; use this README for current local Azure status.
