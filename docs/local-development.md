# Local development

## Prerequisites

For a fresh machine, follow [First run](getting-started.md) first. It covers the tools image, native installation,
proxy/NO_PROXY, provider mirrors, and the full first-run sequence for AWS/Azure.
This reference describes the AWS commands of [local/lab.sh](../local/lab.sh) and recovery in more detail.

Run the commands from the repository root in bash on the Docker host or in the tools container with `--network host`.
Internet access is required for packages, Nexus, and charts.

Both customer1 deployment variants were successfully run with Atmos 1.231.1-rc.0.

## Configuration and stored data

| Path | Purpose |
|---|---|
| `local/compose.yml` | Floci API on 4566, UI on 4500, ALB HTTP entry point on 80 |
| `local/settings.json` | Optional override of the local endpoint, region, Docker network, subnet/gateway, DNS |
| `local/settings.example.json` | Defaults, used when settings.json is absent |
| `stacks/customers/<customer>/aws/_defaults.yaml` | Terraform endpoint, local_lab, NO_PROXY |
| `local/floci-data/` | Persisted Floci API data; the bind mount is relative to local/ |
| `.local-runtime/` | Kubeconfig and nodes.json containing node IP and generation |
| `components/terraform/.../terraform.tfstate.d/` | Per-workspace Terraform state |
| Docker volumes | k3s/EC2/registry data stored separately from repository files |

Settings, runtime files, state, and Floci data are excluded from Git. AWS CLI profiles use the user's standard AWS CLI storage
(inside the tools container, its `/root/.aws`).
Removing runtime files does not delete resources. Clearing Floci data while retaining populated Terraform state causes a mismatch.

Stacks do not set an outbound proxy; tools inherit HTTPS_PROXY from the calling shell.
NO_PROXY must include localhost,127.0.0.1,::1,floci; lab.sh extends this list for its own process and children.

## Commands

| Command | Behavior |
|---|---|
| `lab.sh start` | Checks Docker, creates the external network if absent, starts Floci/UI, waits for Floci health |
| `lab.sh stop` | Stops Floci/UI and retains data; does not delete customer resources |
| `lab.sh prepare STACK` | After Kubernetes creation, fixes node networking/webhook/DNS, configures AWS access/kubeconfig, waits for node/CoreDNS |
| `lab.sh nexus-endpoint STACK` | Resolves the Nexus VM and prints its readiness URL, using the Docker-published port locally |
| `lab.sh start-azure` / `prepare-azure STACK` | The same for Floci Azure: start and trust its CA / write the kubeconfig |
| `lab.sh check [--init] [--render] [--stack STACK]` | Validates configuration without apply |

Start does not wait for Argo CD or Nexus. Floci itself may restore persisted resources.
Prepare is called after Kubernetes apply; do not run it before a first deployment.
It requires a local stack with `settings.local_lab: true`.
`check --init` runs `terraform init -backend=false`; it does not start Docker or the environment.

### Invocation chain

```text
User
├─ lab.sh start → Docker Compose → Floci + UI
├─ Atmos deploy workflow → Terraform network, Kubernetes
│  └─ access → lab.sh prepare
│     ├─ Atmos describe → selected stack configuration
│     ├─ AWS CLI → local Floci EKS/EC2/IAM/STS
│     ├─ Docker → k3s network and node settings
│     └─ AWS CLI + kubectl → profile, kubeconfig, access checks
│  after access succeeds → parallel branches
│     ├─ Terraform Nexus → hook or explicit readiness steps
│     │  └─ lab.sh nexus-endpoint → Atmos + AWS CLI + Docker → URL
│     │     └─ Atmos HTTP step → Nexus readiness
│     └─ Helmfile → applications → Terraform load-balancer
├─ Atmos destroy workflow → customer resource deletion
└─ lab.sh stop → Docker Compose stop
```

Start does not call deploy. Deploy does not start Docker or the emulator. Stop does not call destroy.

### Configuration producers and consumers

| Setting | Consumer | Effect |
|---|---|---|
| settings endpoint and region | lab.sh prepare | AWS CLI target during access preparation |
| network, subnet, gateway | lab.sh start / prepare | External Docker network name and addressing on creation |
| dnsServers | lab.sh prepare | nameserver entries inside the k3s container |
| registryIP | Existing configuration format | Not used by the current commands |
| STACK argument | prepare / nexus-endpoint | Stack queried from Atmos |
| vars.environment | Both commands after describe | Customer cluster, IAM user, and VM identity |
| vars.local_endpoint and vars.region | Terraform providers / nexus-endpoint | Cloud API target |
| Final stack env.KUBECONFIG | Helmfile launched through Atmos | Cluster access for charts |
| load-balancer.vars.kubeconfig_path | Terraform ALB Kubernetes provider | Access to existing Services |

Local settings and Atmos defaults are separate inputs for separate consumers. Changing one does not update the other;
keep endpoint and region aligned. Stack kubeconfig paths are relative to component directories.
Prepare writes the actual kubeconfig under the repository root's runtime directory.

### Start: actions and result

`lab.sh start` creates the network if absent, runs `docker compose up -d`, and waits for Floci health.
The result is an available Floci API and UI. Customer VPC, cluster, Nexus, and applications are created by deployment.
Floci uses the Docker socket to create k3s, EC2, registry, and port-forwarding containers as APIs are called.
Those containers are not separate services in our Compose file.

### Prepare: inputs, actions, outputs

1. Reads the argocd component's configuration through Atmos. Argo CD is only the configuration lookup target;
   an installed Argo CD server is not required for this lookup.
2. environment=customer1-staging determines cluster customer1-staging-eks, container floci-aws-eks-customer1-staging-eks,
   AWS profile floci-customer1-staging, and IAM user customer1-staging-kubectl.
3. Queries EKS/EC2 for node addressing and compares createdAt with nodes.json to identify cluster generations.
4. Pins the node IP, stopping/reconnecting the container when needed; fixes the token webhook,
   floci hosts entry and DNS, starts a stopped node, and waits for its Kubernetes API.
5. Checks the profile identity, creates an access key for the Terraform-created IAM user when necessary,
   and saves credentials/region/endpoint in the AWS CLI profile.
6. Updates kubeconfig with an `aws eks get-token` exec configuration, verifies authentication,
   and waits for Ready nodes and Available CoreDNS.

Prepare changes container configuration and access settings; it is not just a read-only configuration display.

| Output | Subsequent consumer |
|---|---|
| .local-runtime/nodes.json | Future preparation of the same cluster |
| .local-runtime/kubeconfig-customer1-aws-staging.yaml | kubectl, Helmfile, Terraform ALB Kubernetes provider, Kiali CR deletion |
| AWS profile floci-customer1-staging | AWS CLI token generation for kubectl/Helm/Kubernetes provider |
| Fixed node network, hosts, DNS, webhook | k3s and its applications |

To restore access to an existing cluster manually:

```bash
local/lab.sh prepare customer1-aws-staging
```

### nexus-endpoint: inputs and output

The command reads Nexus configuration from Atmos, including environment, region, and local_endpoint.
AWS CLI selects exactly one running VM tagged Name=<environment>-nexus and Role=nexus.
Locally, InstanceId selects `floci-aws-ec2-fwd-<InstanceId>-8081`; `docker port` returns the published host port.

Stdout contains only a URL such as `http://127.0.0.1:<port>/service/rest/v1/status/writable`.
Atmos captures the endpoint step's result; the HTTP step reads `{{ .steps.endpoint.value | trim }}`.
The command neither installs Nexus nor waits for application readiness; the caller performs that wait.
For real AWS, it selects the public VM IP, falling back to private IP, with port 8081.

### Stop and configuration checks

`lab.sh stop` stops Floci/UI through Compose. Success confirms those services stopped, not that customer resources were deleted.
Files and Docker volumes remain; run a successful destroy before stopping the environment.

`lab.sh check` validates stacks, Terraform formatting/module validity, and lab.sh syntax. Flags can be combined:

```bash
local/lab.sh check --init --render --stack customer1-aws-staging
```

Stack selects the configuration for Helmfile rendering, defaulting to customer1-aws-staging.
Terraform validation still covers all modules. Passing these checks does not verify cloud APIs or application runtime health.

## Starting and deploying

```bash
local/lab.sh start
```

Choose one customer1 deployment variant. Hook-based readiness:

```bash
atmos workflow deploy-staging -f customers/customer1/aws
```

Or explicit workflow readiness steps without the Nexus hook:

```bash
atmos workflow deploy-staging-no-hook -f customers/customer1/aws
```

Both manage the same environment. Network, Kubernetes, and Prepare run sequentially;
Nexus/readiness and applications/ALB then run concurrently. Customer1 Terraform apply/destroy use -auto-approve.
The main workflow waits for both branches and fails if either fails.

Customer2 has a separate sequential deployment with Terraform confirmation
(CI sets `ATMOS_COMPONENTS_TERRAFORM_APPLY_AUTO_APPROVE=true`):

```bash
atmos workflow deploy-staging -f customers/customer2/aws
```

It excludes Nexus/ALB and currently has no destroy workflow.

## Checking access

```bash
kubectl --kubeconfig .local-runtime/kubeconfig-customer1-aws-staging.yaml get nodes
kubectl --kubeconfig .local-runtime/kubeconfig-customer1-aws-staging.yaml get pods -A
local/lab.sh nexus-endpoint customer1-aws-staging
```

Floci UI: http://127.0.0.1:4500. Configured ALB routes serve http://argocd.localhost,
http://kiali.localhost, http://minio.localhost, and http://headlamp.localhost.
Nexus uses a dynamic host port: use the command output rather than hardcoding 30000.
Its writable status endpoint returns 200 when ready. MinIO uses persistence.enabled=false;
data is not expected to survive pod replacement.

## Deleting and stopping

Choose one deletion variant. Sequential:

```bash
atmos workflow destroy-staging -f customers/customer1/aws
```

Or delete Nexus and the platform concurrently:

```bash
atmos workflow destroy-staging-parallel -f customers/customer1/aws
```

```text
parallel
├─ destroy Nexus
└─ destroy ALB → Kiali CR → Headlamp → MinIO → Kiali → Argo CD → Istio → Kubernetes
after both branches succeed → destroy network
```

With wait_all, the other branch can finish after a failure, but network deletion is blocked.
Floci must be running and Kubernetes must remain accessible until Helm release deletion completes.
Stop the environment after a successful destroy:

```bash
local/lab.sh stop
```

## Nexus readiness details

deploy-staging uses the hook in stacks/catalog/aws/nexus.yaml after Nexus apply, including direct apply outside a workflow.
Retry wraps the entire kind: steps hook because shell-level retry did not execute in this installed version.
deploy-staging-no-hook passes --skip-hooks=nexus-ready to apply, then runs endpoint lookup retries and an HTTP readiness step.
The HTTP check makes up to 60 attempts, 10 seconds apart, with a 5-second request timeout.
Waiting does not restart installation or repair failed user-data.

lab.sh obtains stack JSON through `atmos describe ... --file`: each call reads its own temporary file,
so Atmos diagnostics are never parsed as JSON, including in parallel workflows.
Nexus user-data sets DPkg::Lock::Timeout=180 because Floci may install SSH packages concurrently.
ALB uses the customer1 stack's kubeconfig_path, matching Prepare's output file.

## Validation and recovery

```bash
local/lab.sh check
atmos workflow deploy-staging-no-hook -f customers/customer1/aws --dry-run
atmos workflow destroy-staging-parallel -f customers/customer1/aws --dry-run
atmos workflow destroy-platform-staging -f customers/customer1/aws --dry-run
```

Parallel-group dry-run does not execute child workflows; inspect them separately.
Failures leave already-created resources in place. Do not reuse a plan after state changes.
The main deployment regenerates plans. To resume application installation from a known step, for example:

```bash
atmos workflow deploy-platform-staging -f customers/customer1/aws --from-step minio
```

For Docker Address already in use, compare `docker network inspect aws-local_default` with nodes.json.
The new ordering pins Kubernetes before Nexus creation, but does not repair an existing collision automatically.
Do not delete state or shared Docker networks to bypass the failure.
For local Floci HTTP 502, check proxy bypass. For slow Nexus startup, inspect
/var/log/nexus-install.log and /opt/sonatype-work/nexus3/log/nexus.log inside its EC2 container.
