# Project architecture

## Purpose and scope

Atmos resolves customer, cloud, and environment settings. Terraform provisions infrastructure.
Helmfile installs applications. Managed stacks use the cloud Kubernetes module. Floci supplies
the local AWS and Azure environments. Kubemarine stacks provision VMs and install Kubernetes
over SSH with packages, images, and charts served by Nexus.

## Core concepts

| Concept | Meaning in this project | Example |
|---|---|---|
| Component | A reusable unit of infrastructure or application installation | network, kubernetes, nexus, argocd |
| Component implementation | Files describing resources or release installation | `components/terraform/aws/network/`, `components/helmfile/argocd/` |
| Configuration catalog | Shared component configuration imported into stacks | `stacks/catalog/aws/network.yaml` |
| Stack | Resolved component configuration for a customer, cloud, and environment | `customer1-aws-staging` |
| Stack manifest | A file importing defaults/catalogs and defining deployment-specific overrides | `stacks/customers/customer1/aws/staging.yaml` |
| Workflow | A named sequence of commands, parallel branches, and checks | `deploy-staging` in `workflows/customers/customer1/staging-terraform.yaml` |

The same component can serve multiple stacks with different parameters. Resource instances must have separate
workspaces/backends and names. Deployment and deletion workflows operate on the same stack. A stack describes configuration; a workflow describes execution.

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
    aws/{network,kubernetes,load-balancer,nexus,vms}/
    azure/{network,kubernetes,load-balancer,vms}/
    gcp/{network,kubernetes,load-balancer,vms}/
    kubemarine/                           # Kubernetes inventory and installer
  helmfile/{argocd,istio,kiali,minio,headlamp}/
stacks/
  catalog/
    {aws,azure,gcp}/                       # cloud infrastructure settings
    helmfile/                             # shared application settings
    kubemarine/                           # VM groups, installer, Nexus chart settings
  customers/
    customer1/
      _defaults.yaml
      aws/{_defaults.yaml,staging.yaml,staging-kubemarine.yaml.example}
      azure/{_defaults.yaml,staging.yaml,staging.yaml.example,staging-kubemarine.yaml.example}
      gcp/{_defaults.yaml,staging.yaml.example}
    customer2/
      _defaults.yaml
      aws/{_defaults.yaml,staging.yaml}
workflows/
  customers/customer1/                   # managed staging and readiness examples
  customers/customer1/kubemarine/{aws,azure}.yaml
  customers/customer2/aws.yaml
  {azure,gcp,helmfile}.yaml
bundle/                                   # offline artifact manifest and scripts
secrets/                                  # SOPS instructions and encrypted stack secrets
Dockerfile                                # Linux tools image
local/
  {compose.yml,compose.azure.yml,settings.example.json}
  scripts/                                # Floci and managed access
  lab.sh                                  # Kubemarine operator tasks
docs/
```

Local settings, runtime files, Floci data, and Terraform state are excluded from Git.
Provider lock files remain in the repository.

## File discovery and stack names

[atmos.yaml](../atmos.yaml) defines component, stack, and workflow paths.
Atmos discovers final stack manifests through `customers/**/*.yaml`, excluding `_defaults.yaml`.
`.yaml.example` templates are inactive. Defaults and catalogs are loaded through explicit `import` entries;
directory nesting does not create inheritance automatically.

The stack name combines `tenant`, `cloud`, and `stage`, for example `customer1-aws-staging`.
The migrated AWS `environment` remains `customer1-staging`: this identifies resources, rather than the Atmos stack.
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
| `stacks/catalog/...` | Shared component parameters, physical Terraform paths, output references, and Terraform-managed Nexus readiness settings |
| Final `staging.yaml` | stage, environment, CIDRs, workspaces, kubeconfig, and application overrides |

Maps merge by key; lists are replaced as a whole. The final stack overrides imported values.
Customer2 imports network, kubernetes, and five Helmfile components, without Nexus or ALB.
It has separate CIDRs, workspaces, and kubeconfig. Its existing deployment is sequential and requests Terraform confirmation;
no customer2 destroy workflow is currently defined.

### Inheritance versus execution dependencies

- `import` loads and merges YAML configuration. It does not execute Terraform or Helmfile.
- `metadata.inherits` is Atmos component configuration inheritance. Kubemarine VM groups inherit settings from an abstract VM component.
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

## Kubemarine stack dependencies

The AWS and Azure VM templates use the stage `staging-kubemarine`. Each imports its customer
and cloud defaults, the cloud network, the shared application catalogs, and the
[Kubemarine catalog](../stacks/catalog/kubemarine/).

| Catalog file | What it supplies |
|---|---|
| `aws-vms.yaml` or `azure-vms.yaml` | Maps `jump-host`, `nexus`, and `vms` to the cloud VM module. The groups consume network outputs and have separate state. The workflow applies them sequentially because they share a module working directory. |
| `install.yaml` | Passes VM outputs to the installer. Terraform generates the inventory and runs Kubemarine on the operator machine. Kubemarine connects to the nodes through the jump host. |
| `offline.yaml` | Reads the private Nexus address from Terraform state and the chart versions from the bundle manifest. Supplies the repository URL and SOCKS proxy to the shared Helmfile components. |

See the [VM installation guide](vm-installation.md) for deployment, access, and deletion commands.

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

### Where Helm settings live

There are three places to distinguish when looking for an application's configuration:

| Location | Contents | When to edit it |
|---|---|---|
| `components/helmfile/<component>/helmfile.yaml.gotmpl` | Chart repository, release name, namespace, version reference, and values file references | Change how the component is installed |
| `stacks/catalog/helmfile/<component>.yaml` | Shared chart version and chart values, under `components.helmfile.<component>.vars` | Change defaults for every stack importing this catalog |
| `stacks/customers/<customer>/<cloud>/<stage>.yaml` | Imports and deployment-specific overrides of the same component vars | Change one customer/environment |

The adjacent `values.yaml.gotmpl` files for Argo CD, Kiali, and Headlamp contain:

```gotmpl
{{ .Values.values | toYaml }}
```

That file is a bridge from resolved Atmos configuration to Helm chart values. It does not contain the application
defaults itself. To find those defaults, open the matching file in `stacks/catalog/helmfile/`.
Istio and MinIO have additional values templates for their multiple releases, as described above.

For a concrete existing override, the [customer1 AWS staging manifest](../stacks/customers/customer1/aws/staging.yaml)
sets Argo CD server replicas to two and its Service type to NodePort under
`components.helmfile.argocd.vars.values.server`. The [shared Argo CD catalog](../stacks/catalog/helmfile/argocd.yaml)
supplies one replica and ClusterIP by default. Atmos merges these maps before Helmfile runs.
To change Kiali for only one customer/environment, use the equivalent
`components.helmfile.kiali.vars.values` path in that customer's final manifest; changing the shared catalog affects all importers.

### Why some .yaml files look like JSON

The current Argo CD, Kiali, and MinIO Helmfile catalogs are serialized using JSON-style braces, quoted keys, and commas.
They remain Atmos stack configuration files: the YAML parser accepts this JSON syntax and reads the same mappings,
lists, strings, numbers, and booleans. Neither the `.yaml` extension nor the `catalog` directory makes them Kubernetes manifests.

For example, this actual part of the Kiali catalog:

```json
"cr": {
  "create": true,
  "name": "kiali",
  "namespace": "istio-system"
}
```

has the same mapping content as this ordinary YAML excerpt:

```yaml
cr:
  create: true
  name: kiali
  namespace: istio-system
```

These excerpts show only three keys; the complete catalog also contains `cr.spec` and the surrounding Atmos structure.
JSON formatting is not required by Atmos or Helmfile and adds no extra inheritance or processing step.
This documentation update leaves the existing configuration files unchanged.

### Kiali: from catalog settings to a Custom Resource

The Kiali Custom Resource is configured in [stacks/catalog/helmfile/kiali.yaml](../stacks/catalog/helmfile/kiali.yaml),
at **`components.helmfile.kiali.vars.values.cr`**. There is currently no separate checked-in `kind: Kiali` manifest.

| Catalog path, relative to `components.helmfile.kiali.vars` | Current value and purpose |
|---|---|
| `chart_version` | `2.33.0`: version of the `kiali/kiali-operator` Helm chart |
| `values.cr.create` | `true`: asks the chart to include a Kiali Custom Resource |
| `values.cr.name` | `kiali`: Custom Resource name |
| `values.cr.namespace` | `istio-system`: namespace of the Custom Resource and managed Kiali instance |
| `values.cr.spec.auth.strategy` | `anonymous`: laboratory authentication setting |
| `values.cr.spec.deployment.view_only_mode` | `true`: Kiali UI uses view-only mode |
| `values.cr.spec.deployment.service_type` | `NodePort`: type of the managed Kiali Service |
| `values.cr.spec.server.node_port` | `30081`: Kiali HTTP NodePort |
| `values.cr.spec.server.web_root` | `/`: web root |
| `values.cr.spec.external_services` | Prometheus, Grafana, and tracing are disabled in the shared laboratory configuration |

The complete creation chain is:

```text
stacks/customers/customer1/aws/staging.yaml
  imports catalog/helmfile/kiali
    → stacks/catalog/helmfile/kiali.yaml: components.helmfile.kiali.vars
    → resolved Atmos component configuration, including any stack overrides
    → components/helmfile/kiali/helmfile.yaml.gotmpl
    → components/helmfile/kiali/values.yaml.gotmpl: .Values.values | toYaml
    → kiali/kiali-operator chart 2.33.0: templates/kiali-cr.yaml
    → Kiali Custom Resource named kiali in istio-system
    → Kiali Operator reconciles the resource and creates the Kiali workload and Service
```

The Helm release and operator run in namespace **`kiali-operator`**; the Kiali Custom Resource and application
are in **`istio-system`**. Helm renders and submits the Custom Resource; the operator acts on its specification.
The chart also adds labels and default settings, so the rendered manifest contains more than the catalog excerpt.

The same shared catalog/component chain is used by the active customer1 Azure and customer2 AWS stacks.
Kiali therefore has one common definition with stack-specific overrides available, rather than a copy per cloud.
During destruction, the workflows delete the Kiali Custom Resource before uninstalling its operator so cleanup can complete.

### Inspect the resolved configuration and rendered manifest

Run these commands from the repository root. Both were checked in this repository and do not apply resources:

```powershell
atmos describe component kiali -s customer1-aws-staging --process-functions=false --format yaml
atmos helmfile template kiali -s customer1-aws-staging --skip-deps
```

The first command shows the resolved Atmos configuration: look for `vars.values.cr`.
The second renders the Helm chart: look for `# Source: kiali-operator/templates/kiali-cr.yaml`,
`kind: Kiali`, `metadata.name: kiali`, and `metadata.namespace: istio-system`.
Helmfile rendering needs Helm, Helmfile, helm-diff, and chart availability as described in the local development guide.
`--process-functions=false` is for configuration inspection; it leaves any Atmos function references unevaluated.

## Workflows and readiness

Customer1 deployment and deletion are defined in [staging-terraform.yaml](../workflows/customers/customer1/staging-terraform.yaml).

```text
network → plan/apply Kubernetes → Prepare-Cluster
                                   ↓
                                parallel
                                ├─ Nexus: one apply → VM → endpoint → HTTP 200
                                └─ applications → plan/apply ALB
```

The internal workflows `deploy-nexus` and `deploy-platform` are called by `deploy-staging`.
The Nexus catalog enables `nexus_wait_for_ready`; the workflow inherits this setting through the stack.
Within the Nexus Terraform module, the HTTP data source depends on the VM and its ingress rule.
For local Floci, the external provider calls `local/scripts/Get-NexusTerraformEndpoint.ps1` with the VM ID
and supplies the dynamically published URL to the HTTP provider. In real AWS, the URL uses the instance public
IP, falling back to private IP, and the external script is not called. The Terraform runner needs network access.
HTTP 200 from `/service/rest/v1/status/writable` confirms write readiness without an admin password.
On initial creation, endpoint discovery and the HTTP read run after their dependencies in the same apply;
with unchanged dependencies, Terraform can read data sources during planning. There is no Atmos readiness hook.

Parallel branches run in separate processes through `type: atmos`.
`wait_all` lets both branches finish and fails the workflow if either fails; resources are not rolled back.

`destroy-staging` deletes Nexus and the platform concurrently, then the network. Its internal `destroy-platform`
branch removes ALB, Kiali CR, Helm releases, and Kubernetes in that order. Nexus readiness is disabled on destroy.
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
