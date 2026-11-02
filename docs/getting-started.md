# First run

This guide explains what to install after cloning, which commands to run, and how to deploy.
Docker runs Floci and the Kubernetes nodes; Atmos, Terraform, Helmfile, and [local/lab.sh](../local/lab.sh)
run either inside the tools image or natively on the host.

The supported host is Linux x64 with Docker Engine (Ubuntu in CI). The commands use bash.
Windows users can work inside WSL 2. Cloud accounts, Azure CLI, gcloud, and a separate Kubernetes installation are not needed.

## The complete sequence

```text
Get tools (image or native) -> clone repository -> review network access
  -> lab.sh check --init: download providers and validate, without deployment
  -> lab.sh start OR lab.sh start-azure: start the selected emulator
  -> Atmos deploy workflow: create customer infrastructure and applications
  -> check Kubernetes and access applications
  -> Atmos destroy workflow: delete customer resources
  -> stop the selected emulator
```

Start does not call deploy. Stop does not call destroy. Choose AWS or Azure for your first run.

## 1. Docker and Git

Install [Docker Engine](https://docs.docker.com/engine/install/) with the Compose plugin and Git, then check:

```bash
docker version
docker compose version
```

Allow enough RAM/disk for Kubernetes, applications, and AWS Nexus; there is no tested sizing guarantee.
The scripts talk to Floci through `localhost` and to k3s nodes through Docker network addresses,
so they must run on the Docker host or in a container with `--network host`.

## 2. Tools

### Option A: tools image (recommended)

The [Dockerfile](../Dockerfile) contains every tool with tested versions. CI publishes it as
`ghcr.io/netcracker/qubership-cluster-management-tools` (`latest` from main, the commit SHA for each build).
Build it locally or pull the published image:

```bash
docker build -t qcm-tools .
docker run -d --name qcm-tools --network host \
  -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD:$PWD" -w "$PWD" qcm-tools sleep infinity
docker exec -it qcm-tools bash
```

Mount the repository at the same path: Compose bind mounts are resolved by the host Docker daemon.
Keep the container between commands: AWS CLI profiles and the trusted Floci Azure CA live inside it.
Run the remaining commands in that shell.

### Option B: native installation

| Tool | Tested version | Purpose |
|---|---|---|
| Atmos | 1.231.1-rc.0 | Stacks and workflows |
| Terraform | 1.16.5 | Infrastructure |
| kubectl | 1.34.3 | Kubernetes access |
| Helm | 4.3.1 | Chart installation |
| helm-diff | 3.15.13 | Helmfile change detection |
| Helmfile | 1.8.1 | Application releases |
| AWS CLI | 2.37.9 | AWS API/EKS tokens; AWS lab only |
| jq, curl | distribution | Script dependencies |

The [Dockerfile](../Dockerfile) shows the exact download URLs. Install helm-diff after Helm:

```bash
helm plugin install https://github.com/databus23/helm-diff --version v3.15.13 --verify=false
```

For Helm 4, `--verify=false` skips plugin signature verification for this legacy Git installation; it does not disable TLS.
`lab.sh start-azure` writes to the system CA store and uses sudo when not run as root (Debian/Ubuntu layout).

## 3. Repository and settings

```bash
git clone https://github.com/Netcracker/qubership-cluster-management.git
cd qubership-cluster-management
```

AWS scripts read `local/settings.json`, falling back to `local/settings.example.json`.
Copy the example only if you need different values:

```bash
cp -n local/settings.example.json local/settings.json
```

The AWS defaults use Docker subnet 172.18.0.0/16; check VPN/other-network conflicts.
Compose fixed IPs must remain consistent with local settings.

## 4. Network access, proxies, and providers

Stacks do not define an outbound proxy. Terraform, Helm, and Helmfile inherit `HTTPS_PROXY`/`HTTP_PROXY` from the calling shell.
If you need a proxy, set it before running checks and workflows, and keep local APIs bypassed:

```bash
export HTTPS_PROXY=http://proxy.example:3128 HTTP_PROXY=http://proxy.example:3128
export NO_PROXY=localhost,127.0.0.1,::1,floci
```

The stacks set NO_PROXY for their child tools, and `lab.sh` extends it. Configure the Docker daemon proxy separately if image pulls need one.
Do not commit proxy passwords.

### Optional provider mirror

When direct downloads are unavailable, use an approved mirror, for example
`https://terraform-mirror.yandexcloud.net/` ([setup guide](https://yandex.cloud/en/docs/terraform/quickstart)).
Merge into `~/.terraformrc` rather than overwriting it:

```hcl
provider_installation {
  network_mirror {
    url     = "https://terraform-mirror.yandexcloud.net/"
    include = ["registry.terraform.io/hashicorp/*"]
  }
  direct {
    exclude = ["registry.terraform.io/hashicorp/*"]
  }
}
```

See [Terraform CLI configuration](https://developer.hashicorp.com/terraform/cli/config/config-file#provider-installation).
Keep the committed `.terraform.lock.hcl` files; do not delete locks or use `init -upgrade` to bypass a download error.
Provider mirrors do not cover Helm charts, Docker images, or Nexus installation downloads.

## 5. Configuration check

```bash
local/lab.sh check --init
```

Expected: `Configuration checks passed. No infrastructure changes were applied.`
`--init` downloads providers for all modules; add `--render` to render Helmfile releases. Nothing is deployed.

## 6. Deploy AWS customer1

```bash
local/lab.sh start
atmos workflow deploy-staging-no-hook -f customers/customer1/aws
```

Start creates the external network if absent, starts Floci/UI, and waits for emulator health.
The workflow creates infrastructure, prepares Kubernetes access, then runs Nexus/readiness and applications/ALB in parallel.
Use `deploy-staging` instead for hook-based Nexus readiness; choose one variant per run.

```bash
kubectl --kubeconfig .local-runtime/kubeconfig-customer1-aws-staging.yaml get pods -A
helm --kubeconfig .local-runtime/kubeconfig-customer1-aws-staging.yaml list -A
local/lab.sh nexus-endpoint customer1-aws-staging
```

Open http://localhost:4500 for Floci UI and http://argocd.localhost, http://kiali.localhost,
http://minio.localhost, http://headlamp.localhost for applications. Nexus uses the script's dynamic URL.

## 7. Deploy Azure customer1

```bash
local/lab.sh start-azure
atmos workflow deploy-staging -f customers/customer1/azure
```

`start-azure` starts Floci Azure on port 4577 and trusts its CA so Terraform can call it over TLS.
The stack records load-balancer backend IP 172.19.0.3; compare it with the node InternalIP
(`kubectl get nodes -o wide`) and update `backend_addresses.kubernetes` if different.
Floci Azure LB does not forward traffic regardless of this setting.
Before repeating infrastructure apply, inspect its plan: Floci AKS read-back omits properties and has caused replacement plans.
For an existing cluster, refresh access and apply applications/LB only:

```bash
atmos workflow deploy-staging -f customers/customer1/azure --from-step access
kubectl --kubeconfig .local-runtime/kubeconfig-customer1-azure-staging.yaml -n argocd port-forward svc/argocd-server 18080:80
```

## 8. Destroy resources, then stop

Keep the emulator running until deletion succeeds.

```bash
atmos workflow destroy-staging-parallel -f customers/customer1/aws && local/lab.sh stop
atmos workflow destroy-staging -f customers/customer1/azure && docker compose -f local/compose.azure.yml stop
```

Stop retains state/data. Do not delete state or Floci data as a substitute for resource deletion.

## Troubleshooting

| Symptom | Check / action |
|---|---|
| Command not found | Use the tools image, or install the tool and check PATH |
| Terraform init HTTP 403 | Review region/access restrictions, proxy, and mirror; retries alone do not fix denial |
| Local API 502 | Keep local endpoints in NO_PROXY |
| Azure TLS errors | Re-run `local/lab.sh start-azure` in the same container/host that runs Terraform |
| helm-diff missing | Install the plugin and check `helm diff version` |
| Port already allocated | AWS uses 80/4500/4566; Azure API 4577 and AKS ports 6600–6699 |
| Kubeconfig missing | Deploy/access preparation creates it; start alone does not |

The same sequence runs in CI ([.github/workflows/ci.yml](../.github/workflows/ci.yml)) for every active stack.
See [local development](local-development.md) for script internals/recovery and [architecture](architecture.md) for imports/values.
