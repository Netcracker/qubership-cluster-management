# Install Kubernetes on VMs with Kubemarine

This workflow installs Kubernetes with [Kubemarine](https://github.com/Netcracker/kubemarine) on plain AWS or Azure
VMs, as if the environment had no Internet access. The nodes and Nexus sit in private subnets.
**Everything the cluster needs comes from a Nexus VM**: OS packages, Kubernetes binaries, images, and Helm charts.
The operator builds an offline bundle and uploads it to that Nexus. Kubemarine installs Kubernetes over SSH through a
jump host, and Helmfile uses the same Nexus for charts. Secrets live in the repository, encrypted with SOPS.

Managed clusters (the EKS, AKS, and GKE stacks) are unchanged and still pull charts and images from the Internet.

See [stack dependencies](architecture.md#kubemarine-stack-dependencies) for the catalog map.

## How it works

```text
 operator environment (tools image)                  cloud: private network, no Internet route
 ──────────────────────────────────                  ─────────────────────────────────────────
 bundle/build.sh ──► .local-runtime/bundle
                                                     ┌─ jump host (public IP, SSH from operator CIDR)
 atmos / helmfile / kubemarine ═══ SSH + SOCKS ═════►│
                                                     ├─► Nexus VM   :8081 raw "bundle" (files, apt, charts)
                                                     │              :8082 docker "images"
                                                     └─► nodes ──── containerd / apt / kubeadm pull from Nexus
```

`deploy-vm` runs these steps in order:

| Step | What happens | Command inside `deploy-vm` |
|---|---|---|
| `network` | VPC or VNet with a public subnet for the jump host and private subnets for everything else | `terraform apply network` |
| `open-access` | Jump host, then a SOCKS tunnel through it on `127.0.0.1:1080` | `workflow open-access` |
| `nodes` | Cluster node VMs | `terraform apply vms` |
| `nexus` | Nexus VM, Nexus installed from the bundle, bundle uploaded | `workflow deploy-nexus` |
| `kubemarine` | `cluster.yaml` generated from the VM outputs; `kubemarine install` runs in the operator environment through the jump host | `terraform apply kubemarine` |
| `access` | kubeconfig taken from the first control-plane node; the API is reached through the tunnel | `lab.sh prepare-vms` |
| `apps` | Helmfile installs Istio, Argo CD, Kiali, MinIO, and Headlamp; charts come from Nexus, images through containerd mirrors | `workflow deploy-apps` |
| `close-access` | Tunnel stopped, jump host destroyed | `workflow close-access` |

The VM groups are applied one after another on purpose. They share one module directory and its selected
Terraform workspace, so parallel applies would run against each other's state.

### Components

The component names are the same in every cloud, so a stack switches cloud by switching catalogs.

| Component | Terraform module | Purpose |
|---|---|---|
| `network` | `<cloud>/network` | Subnets with `public: false` get no Internet route (AWS: no IGW route; Azure: no default outbound access; GCP: VMs without an external IP) |
| `jump-host` | `<cloud>/vms` | One public VM, SSH only from `allowed_cidrs` |
| `nexus` | `<cloud>/vms` | One private VM, ports 22, 8081, and 8082 open to the VPC |
| `vms` | `<cloud>/vms` | Cluster nodes with Kubemarine roles, ports 22, 80, 443, and 6443 open to the VPC, all traffic inside the group |
| `kubemarine` | `kubemarine` | Cloud-independent: builds `cluster.yaml` and runs `kubemarine install` |

`<cloud>/vms` is one generic VM group module. Each group has its own state, so the jump host can be destroyed alone.
The module output `vms` (name, roles, address, internal address) is what the `kubemarine` component and
`local/lab.sh` read. Another provider, such as OpenStack or vSphere, needs only a module with the same inputs and output.

The Kubemarine catalogs are in [stacks/catalog/kubemarine/](../stacks/catalog/kubemarine/):

| Catalog | What it supplies |
|---|---|
| [aws-vms.yaml](../stacks/catalog/kubemarine/aws-vms.yaml), [azure-vms.yaml](../stacks/catalog/kubemarine/azure-vms.yaml), [gcp-vms.yaml](../stacks/catalog/kubemarine/gcp-vms.yaml) | The `jump-host`, `nexus`, and `vms` groups with sizes and ports, inheriting the abstract `vm-group` |
| [install.yaml](../stacks/catalog/kubemarine/install.yaml) | Wires Kubemarine to the VM outputs and Nexus; Calico with `crossSubnet: false` |
| [offline.yaml](../stacks/catalog/kubemarine/offline.yaml) | Nexus chart repository URL, SOCKS proxy for Helmfile, chart versions from the bundle manifest |

Stack templates exist for AWS and Azure:

| Cloud | Stack | Template | Workflow file |
|---|---|---|---|
| AWS | `customer1-aws-staging-kubemarine` | [staging-kubemarine.yaml.example](../stacks/customers/customer1/aws/staging-kubemarine.yaml.example) | [kubemarine/aws.yaml](../workflows/customers/customer1/kubemarine/aws.yaml) |
| Azure | `customer1-azure-staging-kubemarine` | [staging-kubemarine.yaml.example](../stacks/customers/customer1/azure/staging-kubemarine.yaml.example) | [kubemarine/azure.yaml](../workflows/customers/customer1/kubemarine/azure.yaml) |

GCP has only the catalog so far. Workflow files are per stack because Atmos does not pass the stack name to shell steps.

## 1. Prepare the operator environment

Run the Bash commands from the repository root in Linux or WSL 2. Use the tools pinned in the
[Dockerfile](../Dockerfile), or build and enter the tools container from a Bash shell with access to the
Docker engine. The image has Atmos, Terraform, Helmfile, kubectl, Kubemarine, sops, age, gpg, crane, and yq.
The example uses Linux containers and a Docker socket at `/var/run/docker.sock`.

```bash
docker build --platform linux/amd64 -t qcm-tools .
docker run --rm -it --platform linux/amd64 \
  --mount "type=bind,source=$PWD,target=/workspace" \
  --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
  qcm-tools
```

The checkout mount keeps Terraform state, the bundle, and kubeconfigs across container runs.
Run commands that share a tunnel in the same environment. A tunnel started in the container exits
when that container stops. Use a checkout path without spaces for the SSH proxy command.

To open the Nexus UI or port-forwarded applications from a browser on the host, add `--network host` to `docker run`.
On Docker Desktop this also needs Settings → Resources → Network → **Enable host networking**.

## 2. Build the bundle

[bundle/manifest.yaml](../bundle/manifest.yaml) is the single list of what the installation needs, with versions and
original sources: Nexus itself, node packages, Kubemarine binaries and images, Helm charts, and application images.
[offline.yaml](../stacks/catalog/kubemarine/offline.yaml) reads chart versions from it, so a version changes in one place.

Run the build where the Internet is reachable:

```bash
bash ./bundle/build.sh   # → .local-runtime/bundle, about 2.4 GB and 10 minutes
```

| Bundle part | Nexus location | Used by |
|---|---|---|
| `nexus.tar.gz` | None; copied to the Nexus VM | `lab.sh nexus-install` |
| `files/…` (kubeadm, kubelet, kubectl, calicoctl, crictl, etcd) | `bundle` raw repository, `files/` | Kubemarine `registry.thirdparties` |
| `apt/` (packages and dependencies, flat repository with `Packages`) | `bundle` raw repository, `apt/` | Kubemarine `services.packages` |
| `charts/` with `index.yaml` | `bundle` raw repository, `charts/` (a Helm repository) | Helmfile |
| `images/*.tar` | `images` docker repository, port 8082 | containerd on the nodes |

Kubemarine images are stored without a registry name (`kube-apiserver`, `calico/node`), because Kubemarine prefixes
them with its mirror name. Application images keep their registry (`quay.io/argoproj/argocd`). containerd on every node
maps each registry listed in `app_images` to that prefix in Nexus, so charts and values stay unchanged.

The build skips artifacts that already exist. Use a fresh bundle directory when changing manifest versions.
To update a version, edit the manifest, rebuild, and rerun `nexus-load` (see [section 6](#6-work-with-the-cluster-later)).
The `kubemarine` section of the manifest comes from the Kubemarine package
(`kubemarine/resources/configurations/compatibility/internal/*.yaml`); regenerate it when the Kubemarine or Kubernetes
version changes. Application images include those charts pull at run time (Istio sidecar, Kiali server). After adding
a chart, compare `atmos helmfile template` output with the manifest.

If the bundle was built on a different machine, transfer `.local-runtime/bundle` to the operator checkout as a
directory or one tar.

### Bundle from a GitHub release

The [Bundle workflow](../.github/workflows/bundle.yml) builds the same bundle on a GitHub runner and publishes it as a
release. Push a tag `bundle-<version>`, or run the workflow from the Actions tab with a new tag name. A release asset
must be under 2 GiB, so the bundle is one tar split into 1900 MiB parts, with `SHA256SUMS` and the manifest beside them.

```bash
gh release download bundle-<version> -p 'qcm-bundle.tar.part-*' -p SHA256SUMS -D bundle-download
(cd bundle-download && sha256sum -c --ignore-missing SHA256SUMS)
mkdir -p .local-runtime
cat bundle-download/qcm-bundle.tar.part-* | tar -x -C .local-runtime   # → .local-runtime/bundle
diff bundle/manifest.yaml .local-runtime/bundle/manifest.yaml && echo "bundle matches the code"
```

The release notes name the commit the bundle was built from. Check out that commit, or make sure the manifests match.

## 3. Configure secrets

Each VM stack has `secrets/<stack>.yaml`, encrypted with [SOPS](https://getsops.io). Its keys are environment variable
names, so secrets reach the tools as environment variables and are written neither to tfvars nor to Terraform state.

| Key | Used by |
|---|---|
| `TF_VAR_ssh_public_key` | `<cloud>/vms`: key pair or authorized key on every VM |
| `TF_VAR_ssh_private_key` | `kubemarine` and `lab.sh`: SSH through the jump host |
| `NEXUS_ADMIN_PASSWORD` | `bundle/load.sh`: replaces the initial Nexus password |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | AWS provider, when credentials are not taken from the standard chain |
| `ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET` | Azure provider (service principal) |

### Recipients

`.sops.yaml` lists every key a file is encrypted for. Any of them decrypts it, so operators, CI, and cloud KMS keys
work side by side. If the file does not exist, copy [.sops.yaml.example](../.sops.yaml.example) to `.sops.yaml`.

For a fresh operator key:

```bash
age-keygen -o local/age.key   # prints the public key; local/age.key is git-ignored
```

Put the printed public key in the `age:` line of `.sops.yaml` (comma-separated for several keys). If the stack
already has encrypted secrets, send your public key to someone who can decrypt them. They add it to `.sops.yaml` and
run `sops updatekeys secrets/<stack>.yaml`.

The decrypting key source is chosen at run time, without code changes:

| Source | How | Typical use |
|---|---|---|
| Local file | `SOPS_AGE_KEY_FILE=<path>`; `lab.sh` uses `local/age.key` when nothing else is set | Operator environment |
| Variable | `SOPS_AGE_KEY=AGE-SECRET-KEY-…` | CI secret |
| Cloud secret manager | `SOPS_AGE_KEY_CMD='aws secretsmanager get-secret-value --secret-id sops-age --query SecretString --output text'` (or `az keyvault secret show … -o tsv`) | Cloud runners |
| Cloud KMS | Add `kms` or `azure_keyvault` to `.sops.yaml`; the runner's cloud identity decrypts | No key material at all |
| PGP | Add the fingerprint to `pgp:` in `.sops.yaml`; sops decrypts with the secret key in the gpg keyring | Operators who already have a PGP key |

With PGP, the tools container has its own keyring: import your secret key once per container with
`gpg --import <secret-key.asc>`. If the key has a passphrase, run `export GPG_TTY=$(tty)` first. In CI, use a key
without a passphrase and import it from a secret: `gpg --batch --import <<<"$SOPS_PGP_KEY"`.

### Create the stack secrets

Set the stack variables used in the rest of this guide:

```bash
cloud=aws   # Set to azure for Azure.
stack="customer1-$cloud-staging-kubemarine"
workflow="customers/customer1/kubemarine/$cloud"
manifest="stacks/customers/customer1/$cloud/staging-kubemarine.yaml"
export SOPS_AGE_KEY_FILE="$PWD/local/age.key"
```

```bash
bash ./local/lab.sh secrets-init "$stack"   # one time: SSH key pair and Nexus password, encrypted
sops "secrets/$stack.yaml"                  # add the cloud credentials
```

Or set single values without an editor:

```bash
sops set "secrets/$stack.yaml" '["ARM_CLIENT_SECRET"]' '"<password>"'
```

Every value in the file shows as `ENC[...]`, so it is safe to commit. Commands get the values through
`bash ./local/lab.sh with-secrets "$stack" <command>`. You can also use credentials from the provider's standard
authentication chain inside the operator environment.

## 4. Configure the stack

```bash
cp -n "$manifest.example" "$manifest"
curl -s https://ifconfig.me; echo   # your public IP
```

Set the operator's public CIDR in `components.terraform.jump-host.vars.allowed_cidrs` (replace `203.0.113.10/32`).
Only these addresses can reach the jump host. Keep the public jump subnet and the private node subnets of the template.
Node sizes and counts are in the cloud catalog and can be overridden in the stack.

- **AWS** — replace `components.terraform.vm-group.vars.ami_id` with a Canonical Ubuntu 24.04 amd64 AMI in the
  selected region. Kubemarine 0.55 needs containerd 2.2, which Ubuntu 24.04 ships. The AWS defaults inherit
  `HTTPS_PROXY=http://127.0.0.1:12334` from the Floci lab. Set `env.HTTPS_PROXY` in this VM manifest to a proxy
  reachable from the operator environment, or set it to `""` for direct access.
- **Azure** — the VM module already selects an Ubuntu 24.04 amd64 image. The region is `northeurope` from
  `customer1/azure/_defaults.yaml`; to use another, set `vars.region` in the stack. Review the prerequisites below.

What the default catalogs create:

| | AWS (`us-east-1`) | Azure (`northeurope`) |
|---|---|---|
| Jump host | t3.small, public subnet | Standard_B2s, public subnet |
| Nexus | m5.large, 200 GB disk, private | Standard_D2s_v5, 200 GB disk, private |
| 3 control-plane + 2 worker nodes | m5.xlarge each, private | Standard_D4s_v5 each, private |
| Approximate cost (list prices of 2026-11-04) | about $1.1 per hour | about $1.3 per hour |

Always finish with [section 7](#7-destroy).

### Azure prerequisites

Run these in Azure Cloud Shell (Bash) or with the Azure CLI.

1. **vCPU quota.** The stack needs 24 vCPUs in the region: 22 of the DSv5 family and 2 of the BS family.
   New subscriptions usually have lower limits; request an increase in the portal under **Quotas** → **Compute**.
   Free Trial subscriptions must be upgraded to Pay-As-You-Go first.

   ```bash
   az vm list-usage --location northeurope -o table | grep -E "Total Regional vCPUs|DSv5 Family|BS Family"
   ```

2. **Resource providers.** Register them now to avoid a slow first apply.

   ```bash
   az provider register --namespace Microsoft.Compute --wait
   az provider register --namespace Microsoft.Network --wait
   ```

3. **Service principal for Terraform.** Copy `appId`, `password`, and `tenant` from the output, together with the
   subscription ID, into the `ARM_*` secrets. The password is shown only once.

   ```bash
   SUBSCRIPTION=$(az account show --query id -o tsv)
   az ad sp create-for-rbac --name "qcm-$stack" --role Contributor --scopes "/subscriptions/$SUBSCRIPTION"
   ```

### Check the configuration

```bash
atmos validate stacks
atmos workflow deploy-vm -f "$workflow" --dry-run
bash ./local/lab.sh with-secrets "$stack" atmos terraform plan network -s "$stack"   # creates nothing
```

Validation prints `All stacks validated successfully`. Dry-run lists the top-level steps. The plan checks cloud access.

## 5. Deploy

```bash
bash ./local/lab.sh with-secrets "$stack" atmos workflow deploy-vm -f "$workflow"
```

Expected durations; most of the time is Kubemarine and the bundle upload:

| Step | Takes |
|---|---|
| `network` | 1–2 min |
| `open-access` | 2–4 min |
| `nodes` | 2–4 min |
| `nexus` (2.4 GB uploaded through the tunnel) | 10–40 min, depends on the upload speed |
| `kubemarine` | 30–60 min |
| `access` | 1–5 min |
| `apps` | 10–15 min |
| `close-access` | 1–2 min |

These are estimates, not measurements. Kubemarine output streams into the `kubemarine` apply. Its dump with logs and
the final inventory stays in `.local-runtime/kubemarine/$stack/dump`.

The workflow ends with `close-access`: the jump host is destroyed, so nothing in the environment accepts connections
from outside. If a step fails, fix the cause and run the same command again. Applied Terraform components change
nothing, Kubemarine does not reinstall, and the bundle upload skips what Nexus already has.

## 6. Work with the cluster later

Open access, check the cluster, and close access in the same operator environment:

```bash
bash ./local/lab.sh with-secrets "$stack" atmos workflow open-access -f "$workflow"
export KUBECONFIG="$PWD/.local-runtime/kubeconfig-$stack.yaml"   # proxy-url to the tunnel is in the kubeconfig
kubectl get nodes -o wide   # 5 nodes Ready, internal IPs only
kubectl get pods -A         # all Running or Completed
bash ./local/lab.sh with-secrets "$stack" atmos workflow close-access -f "$workflow"
```

Check the isolation while access is open: a node cannot reach the Internet but reaches Nexus.

```bash
node=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
bash ./local/lab.sh with-secrets "$stack" bash ./local/lab.sh ssh "$stack" "$node" \
  'curl -sS -m 5 -o /dev/null https://archive.ubuntu.com && echo "INTERNET REACHABLE" || echo "isolated: OK"'
```

Other tasks while access is open:

| Task | Command |
|---|---|
| Reapply the apps | `bash ./local/lab.sh with-secrets "$stack" atmos workflow deploy-apps -f "$workflow"` |
| Reload Nexus after a bundle change | `bash ./local/lab.sh with-secrets "$stack" bash ./local/lab.sh nexus-load "$stack"` |
| Shell on a private VM | `bash ./local/lab.sh with-secrets "$stack" bash ./local/lab.sh ssh "$stack" <private address>` |
| Nexus private address | `atmos terraform output nexus -s "$stack"` (`internal_address`) |

To open an application, port-forward from the container and open `http://localhost:<port>` on the host:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:80   # user admin
```

Use the same pattern for Headlamp (`-n headlamp svc/headlamp`), the MinIO console (`-n storage svc/minio-console`),
and Kiali (`-n istio-system svc/kiali 20001`). `--address 0.0.0.0` is needed because the container's `127.0.0.1` is
not the host's. For the Nexus UI, set the browser's SOCKS proxy to `127.0.0.1:1080` and open
`http://<Nexus private address>:8081` as `admin` with `NEXUS_ADMIN_PASSWORD` from `sops -d "secrets/$stack.yaml"`.
Both need the container started with `--network host` (see [section 1](#1-prepare-the-operator-environment)).

The `kubemarine` component installs once per environment. Later inventory changes go through Kubemarine procedures
(`kubemarine add_node`, `upgrade`, and others) with `.local-runtime/kubemarine/$stack/cluster.yaml`.
A clean reinstall is:

```bash
bash ./local/lab.sh with-secrets "$stack" atmos terraform apply kubemarine -s "$stack" -replace=terraform_data.install
```

## 7. Destroy

```bash
bash ./local/lab.sh with-secrets "$stack" atmos workflow destroy-vm -f "$workflow"
```

Destroy stops the tunnel and removes the installer state, VMs, Nexus, jump host, and network. Terraform state is local
(`components/terraform/*/terraform.tfstate.d/`): keep the checkout until destroy finishes. On Azure, also check that
the resource group is gone (`az group list -o table`) and delete the service principal (`az ad sp delete --id <appId>`).

## Troubleshooting

| Symptom | Check |
|---|---|
| `No SSH key` from `lab.sh` | The command was not run under `with-secrets`. |
| SOPS: `no identity matched` or cannot decrypt | Check `SOPS_AGE_KEY_FILE` (or another key source) and the recipients in the encrypted file. |
| AWS API or registry connection refused | Check the inherited HTTPS proxy from inside the operator shell. |
| `Timed out waiting for SSH on the jump host` | Your public IP changed: update `allowed_cidrs` and rerun `open-access`. |
| `bind 127.0.0.1:1080: Address already in use` | An old tunnel lost its control socket: `pkill -f 'ssh.*-D 127.0.0.1:1080'`, then rerun `open-access`. |
| Kubernetes API or Nexus is unreachable | Run `open-access` in the same environment. Check the operator CIDR. |
| SSH `REMOTE HOST IDENTIFICATION HAS CHANGED` after VMs were recreated | Delete `.local-runtime/known_hosts-$stack`. |
| Nexus upload fails | Check that `.local-runtime/bundle/nexus.tar.gz` exists. On the VM: `systemctl status nexus`, `/opt/sonatype-work/nexus3/log/nexus.log`. |
| Kubemarine fails on packages or images | Nexus is not fully loaded: rerun `nexus-load` with access open, then reinstall with `-replace=terraform_data.install`. |
| Kubemarine fails otherwise | The apply output and `.local-runtime/kubemarine/$stack/dump/debug.log`. |
| Application pod `ImagePullBackOff` | The image is missing from `app_images` in the manifest, or its registry is new: rebuild, reload, and reinstall `kubemarine` so containerd gets the mirror. |
| Azure `QuotaExceeded` | The vCPU quota is lower than the stack needs; see [Azure prerequisites](#azure-prerequisites). |
| Azure `SkuNotAvailable` | The VM size has no capacity in the region: choose another `region` or override `instance_type` in the stack. |
| Azure `AuthorizationFailed` | The service principal lacks `Contributor`, or the `ARM_*` values are wrong. |
| Azure `MissingSubscriptionRegistration` | Register the resource providers and rerun. |

## Verification status

- Stack validation and workflow dry-runs have been checked with this repository layout.
- Locally checked: Terraform module tests, the generated `cluster.yaml` against the Kubemarine schema, SOPS key
  sources, and bundle build and upload into a real Nexus 3.97.1.
- The Azure flow was deployed in a real subscription with the earlier stack layout. A full run with the
  `*-staging-kubemarine` stacks, and any run on AWS or GCP, is still unverified.
- `bundle/load.sh` accepts the [Nexus Community Edition EULA](https://links.sonatype.com/products/nxrm/ce-eula) on the
  Nexus instance it configures.
