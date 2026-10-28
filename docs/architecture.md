# Project architecture

## Purpose and scope

Atmos combines customer and environment parameters with reusable components and executes deployment workflows.
Terraform manages infrastructure; Helmfile manages Helm releases inside Kubernetes.
This repository currently contains the Terraform/Helmfile project, without Kubemarine integration.

AWS is used locally through Floci. Azure/GCP implementations and stack templates exist, but cloud end-to-end deployment has not been verified.
The AWS Kubernetes module creates EKS/IAM resources; Floci provides the local k3s node.
A real AWS deployment requires a separate worker-node and access design.

## Core concepts

| Concept | Meaning in this project | Example |
|---|---|---|
| Component | A reusable unit of infrastructure or application installation | network, kubernetes, nexus, argocd |
| Component implementation | Files describing resources or release installation | `components/terraform/aws/network/`, `components/helmfile/argocd/` |
| Configuration catalog | Shared component configuration imported into stacks | `stacks/catalog/aws/network.yaml` |
| Stack | Resolved component configuration for a customer, cloud, and environment | `customer1-aws-staging` |
| Stack manifest | A file importing defaults/catalogs and defining deployment-specific overrides | `stacks/customers/customer1/aws/staging.yaml` |
| Workflow | A named sequence of commands, parallel branches, and checks | `deploy-staging-no-hook` in `workflows/customers/customer1/aws.yaml` |
| Hook | An action triggered by a component lifecycle event | nexus-ready after Terraform applies Nexus |

The same component can serve multiple stacks with different parameters. Resource instances must have separate
workspaces/backends and names. Multiple workflows can operate on one stack: deployment with a hook,
deployment with an explicit readiness check, and deletion. A stack describes configuration; a workflow describes execution.

## File responsibilities

Terraform reads all `.tf` files in a component directory as one root module. File naming does not determine resource creation order.

| File | Responsibility |
|---|---|
| `main.tf` and other `.tf` files, such as `argocd.tf` | Resources, data sources, and dependency expressions |
| `variables.tf` | Accepted inputs, types, defaults, and validation |
| `outputs.tf`, where present | Values exposed to consumers after provisioning |
| `providers.tf` | Connections to cloud APIs or Kubernetes |
| `versions.tf` | Terraform and provider requirements |
| `.terraform.lock.hcl` | Selected provider versions and checksums |
| Nexus `user-data.sh.tftpl` | An installation script rendered by Terraform and executed inside the VM after startup |
| `helmfile.yaml.gotmpl` | Chart repositories, releases, namespaces, versions, values references, and release needs |
| `values*.yaml.gotmpl` | Translation of resolved Atmos parameters into chart values |
| `charts/minio-bucket/` | A local chart containing the bucket-creation job that runs after MinIO |

`stacks/catalog` contains configuration; `components` contains component implementations.
Changing catalog defaults affects importing stacks unless they override the changed value.
Changing an implementation affects every stack using that implementation.

## Repository layout

```text
atmos.yaml
components/
  terraform/
    aws/{network,kubernetes,load-balancer,nexus}/
    azure/{network,kubernetes,load-balancer}/
    gcp/{network,kubernetes,load-balancer}/
  helmfile/
    argocd/{helmfile.yaml.gotmpl,values.yaml.gotmpl}
    istio/{helmfile.yaml.gotmpl,values-base.yaml.gotmpl,values-istiod.yaml.gotmpl}
    kiali/{helmfile.yaml.gotmpl,values.yaml.gotmpl}
    minio/{helmfile.yaml.gotmpl,values.yaml.gotmpl,values-bucket.yaml.gotmpl,charts/minio-bucket/}
    headlamp/{helmfile.yaml.gotmpl,values.yaml.gotmpl}
stacks/
  catalog/{aws,azure,gcp,helmfile}/
  customers/
    customer1/
      _defaults.yaml
      aws/{_defaults.yaml,staging.yaml}
      azure/{_defaults.yaml,staging.yaml.example}
      gcp/{_defaults.yaml,staging.yaml.example}
    customer2/
      _defaults.yaml
      aws/{_defaults.yaml,staging.yaml}
workflows/
  customers/customer1/aws.yaml
  customers/customer2/aws.yaml
  {azure,gcp,helmfile}.yaml
local/{compose.yml,settings.example.json,settings.json,scripts/,floci-data/}
.local-runtime/
docs/{architecture.md,local-development.md,deployment.md}
```

Local settings, `.local-runtime`, Floci data, and Terraform state are excluded from Git.
Provider lock files remain in the repository.

## File discovery and stack names

[atmos.yaml](../atmos.yaml) defines component, stack, and workflow paths.
Atmos discovers final stack manifests through `customers/**/*.yaml`, excluding `_defaults.yaml`.
`.yaml.example` templates are inactive. Defaults and catalogs are loaded through explicit `import` entries;
directory nesting does not create inheritance automatically.

The stack name combines `tenant`, `cloud`, and `stage`, for example `customer1-aws-staging`.
The migrated AWS `environment` remains `customer1-staging`: this identifies resources, rather than the Atmos stack.
All ten Terraform modules declare `cloud` as a string context input.
The implementation is selected by `metadata.component`, not by `cloud` alone.

## Imports and overrides

Customer1 AWS imports the following configuration:

```text
customers/customer1/aws/staging.yaml
├─ customers/customer1/aws/_defaults.yaml
│  └─ customers/customer1/_defaults.yaml
├─ catalog/aws/{network,kubernetes,load-balancer,nexus}.yaml
└─ catalog/helmfile/{istio,argocd,kiali,minio,headlamp}.yaml
```

| File | Configuration supplied |
|---|---|
| Customer `_defaults.yaml` | tenant |
| Cloud `_defaults.yaml` | cloud, region, local endpoint, local_lab, and tool environment |
| `stacks/catalog/...` | Shared component parameters, physical Terraform paths, output references, and the Nexus hook |
| Final `staging.yaml` | stage, environment, CIDRs, workspaces, kubeconfig, and application overrides |

Maps merge by key; lists are replaced as a whole. The final stack overrides imported values.
Customer2 imports network, kubernetes, and five Helmfile components, without Nexus or ALB.
It has separate CIDRs, workspaces, and kubeconfig. Its existing deployment is sequential and requests Terraform confirmation;
no customer2 destroy workflow is currently defined.

### Inheritance versus execution dependencies

- `import` loads and merges YAML configuration. It does not execute Terraform or Helmfile.
- `metadata.inherits` is Atmos component configuration inheritance. Current stacks use catalog imports for shared settings.
- `metadata.component: aws/network` maps a logical component to its implementation directory.
- `!terraform.state network subnet_ids` reads an input dependency from network state. It does not create the network automatically.
- Workflow `steps` define execution order. Calling another workflow executes its steps rather than inheriting its YAML.
  The stack is passed to child Atmos commands; each internal workflow defines its own steps.
- `needs` in a parallel group refers to sibling steps. Helmfile `needs` refers to Helm releases.

Matching directory names do not make defaults, stacks, and workflows inherit from one another.
Configuration merging and resource execution order are separate mechanisms.

### From a command to a resource

For `atmos terraform apply network -s customer1-aws-staging`:

1. Atmos reads atmos.yaml and resolves the stack name from tenant/cloud/stage.
2. It loads the customer1 AWS staging manifest and its imports.
3. It merges global vars with `components.terraform.network.vars`.
4. `metadata.component: aws/network` selects `components/terraform/aws/network/`.
5. Atmos passes the resolved vars through a generated varfile, selects the workspace, and runs apply.
6. Terraform reads the root module, calls its providers, and writes state and outputs.

`atmos helmfile apply argocd -s customer1-aws-staging` uses the same stack but selects
`components.helmfile.argocd` and `components/helmfile/argocd/`. Its parameters become Helmfile state values.

### Where to change a setting

| Change | Location |
|---|---|
| Argo CD replicas for customer1 staging only | `components.helmfile.argocd.vars.values` in the final staging manifest |
| Shared Argo CD chart version | `stacks/catalog/helmfile/argocd.yaml`, subject to stack overrides |
| Resources created by AWS network | `.tf` files in `components/terraform/aws/network/` |
| One deployment's network CIDR | `components.terraform.network.vars` in its final stack |
| Installation or deletion order | The customer's workflow |
| Local Floci/UI lifecycle | `local/compose.yml` and the corresponding Start/Stop scripts |
| Node and kubeconfig preparation | Prepare-Cluster.ps1 and functions in Local-Lab.psm1 |

## Terraform components and dependencies

Each physical component directory is a separate root module with its own inputs, providers, state, and plan.
Dependencies are passed as input identifiers rather than by including another component's source code.

| Component | Resources and dependencies |
|---|---|
| AWS network | VPC, subnets, gateway, routes; exports vpc_id and subnet_ids |
| AWS kubernetes | EKS/IAM; consumes network subnet_ids |
| AWS nexus | VM and access rules; consumes the VPC and one subnet |
| AWS load-balancer | ALB, target groups, rules, attachments; reads network, EC2 node, and existing Kubernetes Services |
| Azure network | Resource group, VNet, subnets |
| Azure kubernetes | AKS, identity, and subnet permissions |
| Azure load-balancer | Standard TCP LB with explicitly configured backend addresses |
| GCP network | VPC, subnet, secondary ranges |
| GCP kubernetes | GKE, service account, node pool; consumes network configuration |
| GCP load-balancer | Regional passthrough TCP LB with explicitly configured backend VMs |

Matching component names do not imply identical cloud capabilities. See each module's variables.tf and outputs.tf for its contract.
AWS catalogs use `!terraform.state`: Kubernetes reads network subnet_ids, Nexus reads vpc_id and `.subnet_ids.a`,
and ALB reads the VPC and all subnets. Therefore, network is created first and deleted last.
Access preparation follows Kubernetes; applications follow access; ALB follows applications.

## Helmfile and stack values

```text
stacks/catalog/helmfile/argocd.yaml: vars.values
   + customer1/aws/staging.yaml overrides
   → resolved Atmos vars
   → Helmfile state values (.Values)
   → components/helmfile/argocd/values.yaml.gotmpl
   → Helm chart values
```

The Helmfile template selects the chart repository, version, release, namespace, and values files.
The values template serializes `.Values.values` for the chart. Stack values describe a deployment;
the component defines how those settings reach the chart. For example, the Argo CD catalog defaults to one replica
and ClusterIP; customer1 overrides these to two replicas and NodePort. Chart versions use `.Values.chart_version`.

Istio contains base and istiod releases and a separate `base_values` block.
MinIO contains minio and minio-bucket releases and a separate `bucket_values` block.
Helmfile `needs` orders these releases. The workflow orders components: Istio → Argo CD → Kiali → MinIO → Headlamp.

## Workflows and readiness

Customer1 scenarios are defined in [aws.yaml](../workflows/customers/customer1/aws.yaml).

```text
network → plan/apply Kubernetes → Prepare-Cluster → plan Nexus
                                                  ↓
                                               parallel
                                               ├─ Nexus apply → readiness
                                               └─ applications → plan/apply ALB
```

`deploy-staging` uses the nexus-ready hook from `stacks/catalog/aws/nexus.yaml`.
`deploy-staging-no-hook` skips only that hook with `--skip-hooks=nexus-ready` on Nexus apply,
then resolves the endpoint and checks HTTP readiness in explicit workflow steps. Both operate on the same stack.
VM provisioning can finish before Nexus installation; HTTP 200 from `/service/rest/v1/status/writable`
confirms write readiness without an admin password.

The internal workflows deploy-nexus-staging, deploy-nexus-staging-no-hook, and deploy-platform-staging
are called by the main scenarios. Nexus branches require a saved plan and are not standalone first-run entry points.
Parallel branches run in separate processes through `type: atmos`.
`wait_all` lets both branches finish and fails the workflow if either fails; resources are not rolled back.

`destroy-staging` deletes sequentially. `destroy-staging-parallel` deletes Nexus and the platform concurrently,
then network. Its internal destroy-platform-staging branch removes ALB, Kiali CR, Helm releases, and Kubernetes in that order.
If either branch fails, network deletion does not start.

## State and generated files

AWS workspaces are explicitly set in final stack metadata. With the current local backend, state lives under
each component at `terraform.tfstate.d/customer1-aws-staging/terraform.tfstate`.
Atmos generates varfiles and plans beside it, such as `customer1-aws-staging-aws-nexus.planfile`.
State changes can invalidate saved plans; rerunning the main deployment regenerates them.
Do not run concurrent workflows against the same stack. Team use requires a separately selected remote backend.

## Extending the project

- Customer: add defaults and final stack manifests importing the required catalogs.
- Environment: add a YAML manifest under the customer's cloud directory with distinct stage, workspace, and kubeconfig.
- Terraform component: add a root module, catalog, stack import, and workflow steps respecting its dependencies.
- Helm component: add a Helmfile/values directory, parameter catalog, stack import, and workflow step.
- Additional cluster in one environment: first extend stack identity and state/kubeconfig separation to prevent collisions.

Use these concrete commands to inspect the current AWS stack:

```powershell
atmos validate stacks
atmos describe component network -s customer1-aws-staging --process-functions=false
```

Review the Terraform plan before applying. See [Azure/GCP preparation](deployment.md) for cloud templates.
