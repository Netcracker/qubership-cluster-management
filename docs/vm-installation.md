# Isolated Kubernetes on VMs

Kubernetes is installed by [Kubemarine](https://github.com/Netcracker/kubemarine) on plain VMs in AWS, Azure or
GCP as if the environment had no Internet: the nodes and Nexus sit in private subnets, and **everything the cluster
needs — OS packages, Kubernetes binaries, images, Helm charts — comes from a Nexus VM** that the operator fills from
a prepared bundle. Secrets live in the repository, encrypted with SOPS.

Managed clusters (EKS/AKS/GKE stacks) are unchanged and still pull charts and images from the Internet.

> Status: every piece below is checked locally (Terraform tests, Kubemarine schema, SOPS, bundle build and upload
> into a real Nexus 3.97.1). A full run on a real cloud account has not been done yet; see [Not verified](#not-verified).

## How it works

```text
 operator machine (tools image)                      cloud: private network, no Internet route
 ─────────────────────────────                       ───────────────────────────────────────────
 bundle/build.sh ──► .local-runtime/bundle
                                                     ┌─ jump host (public IP, SSH from operator CIDR)
 atmos / helmfile / kubemarine ═══ SSH + SOCKS ═════►│
                                                     ├─► Nexus VM   :8081 raw "bundle" (files, apt, charts)
                                                     │              :8082 docker "images"
                                                     └─► nodes ──── containerd / apt / kubeadm pull from Nexus
```

| Step | What happens | Command (inside `deploy-vm`) |
|---|---|---|
| 5.1 | VPC/VNet with a public subnet for the jump host and private ones for everything else | `terraform apply network` |
| — | Jump host, then a SOCKS tunnel through it | `workflow open-access` |
| 5.2 | **In parallel:** Nexus VM → Nexus installed from the bundle → bundle uploaded; cluster node VMs | `workflow deploy-nexus` ∥ `terraform apply vms` |
| 5.3 | The parallel step finishes only when both branches have | — |
| 5.4–5.5 | `cluster.yaml` generated from the VM outputs; `kubemarine install` runs on the operator machine, through the jump host | `terraform apply kubemarine` |
| — | kubeconfig taken from the control plane; the API is reached through the tunnel | `lab.sh prepare-vms` |
| 5.6 | Helmfile installs the apps; charts come from Nexus, images through containerd mirrors | `workflow deploy-apps` |
| — | Tunnel stopped, jump host destroyed | `workflow close-access` |

### Components

The same component names exist in every cloud, so a stack switches cloud by switching catalogs.

| Component | Terraform module | Purpose |
|---|---|---|
| `network` | `<cloud>/network` | Subnets with `public: false` get no Internet route (AWS: no IGW route; Azure: no default outbound access; GCP: VMs without external IP) |
| `jump-host` | `<cloud>/vms` | One public VM, SSH only from `allowed_cidrs` (the operator) |
| `nexus` | `<cloud>/vms` | One private VM, ports 22/8081/8082 open to the VPC |
| `vms` | `<cloud>/vms` | Cluster nodes with Kubemarine roles, ports 22/80/443/6443 open to the VPC, all traffic inside the group |
| `kubemarine` | `kubemarine` | Cloud-independent: builds `cluster.yaml` and runs `kubemarine install` |

`<cloud>/vms` is one generic "group of VMs" module; every group has its own state, so groups are created in parallel
and the jump host is destroyed alone. Its output `vms` (name, roles, address, internal address) is what the
`kubemarine` component and `local/lab.sh` read. Another provider (OpenStack, vSphere) needs only a module with the
same inputs and output.

Catalogs: [catalog/aws/vms.yaml](../stacks/catalog/aws/vms.yaml) (same for `azure`, `gcp`) defines the three groups;
[catalog/kubemarine.yaml](../stacks/catalog/kubemarine.yaml) wires Kubemarine to them and points Helmfile at Nexus.

## 1. Build the bundle

[bundle/manifest.yaml](../bundle/manifest.yaml) is the one list of what the installation needs, with versions and
original sources: Nexus itself, node packages, Kubemarine binaries and images, Helm charts and application images.
Stack catalogs read chart versions from it too, so a version is changed in one place.

Run where the Internet is reachable, in the tools image (it has docker, helm, crane, yq):

```bash
bundle/build.sh                      # → .local-runtime/bundle (2.4 GB, ~10 min); a re-run skips what exists
```

| Bundle part | Nexus location | Used by |
|---|---|---|
| `nexus.tar.gz` | — (copied to the Nexus VM) | `lab.sh nexus-install` |
| `files/…` (kubeadm, kubelet, kubectl, calicoctl, crictl, etcd) | `bundle` raw repo, `files/` | Kubemarine `registry.thirdparties` |
| `apt/` (packages + their dependencies, flat repo with `Packages`) | `bundle` raw repo, `apt/` | Kubemarine `services.packages` |
| `charts/` (+ `index.yaml`) | `bundle` raw repo, `charts/` (a Helm repository) | Helmfile |
| `images/*.tar` | `images` docker repo, port 8082 | containerd on the nodes |

Kubemarine images are stored without a registry (`kube-apiserver`, `calico/node`): Kubemarine prefixes them with its
mirror name. Application images keep their registry (`quay.io/argoproj/argocd`), and containerd on every node maps
each registry from the manifest to that prefix in Nexus. Charts and their values are therefore not changed.

To update a version: edit the manifest, rebuild, re-run `lab.sh nexus-load`. The Kubemarine section comes from the
Kubemarine package (`kubemarine/resources/configurations/compatibility/internal/*.yaml`); regenerate it when the
Kubemarine or Kubernetes version changes. Application images include those the charts pull at run time (Istio
sidecar, Kiali server); after adding a chart, compare `atmos helmfile template` output with the manifest.

Move `.local-runtime/bundle` to the operator machine of the isolated environment as a directory or one tar.

### Bundle as a GitHub release

The [Bundle workflow](../.github/workflows/bundle.yml) builds the same bundle on a GitHub runner and publishes it as a
release: push a tag `bundle-<version>` (or run the workflow with a new tag name). A release asset must be under 2 GiB,
so the bundle is one tar split into 1900 MiB parts, with `SHA256SUMS` and the manifest beside them. To use it:

```bash
gh release download bundle-<version> -p 'qcm-bundle.tar.part-*' -p SHA256SUMS -D bundle-download
(cd bundle-download && sha256sum -c --ignore-missing SHA256SUMS)
cat bundle-download/qcm-bundle.tar.part-* | tar -x -C .local-runtime    # → .local-runtime/bundle
```

## 2. Secrets

Each VM stack has `secrets/<stack>.yaml`, encrypted with [SOPS](https://getsops.io). Its keys are environment variable
names, so secrets reach tools without being written anywhere:

| Key | Used by |
|---|---|
| `TF_VAR_ssh_public_key` | `<cloud>/vms` (key pair / authorized key on every VM) |
| `TF_VAR_ssh_private_key` | `kubemarine` and `lab.sh` (SSH through the jump host); never in Terraform state |
| `NEXUS_ADMIN_PASSWORD` | `bundle/load.sh` (replaces Nexus' initial password) |
| `AWS_ACCESS_KEY_ID`, `ARM_CLIENT_SECRET`, `GOOGLE_CREDENTIALS`, … | Cloud providers, when credentials are not taken from a profile |

```bash
local/lab.sh secrets-init customer1-aws-vm          # new SSH key + Nexus password, encrypted
sops secrets/customer1-aws-vm.yaml                  # edit (add cloud credentials)
local/lab.sh with-secrets customer1-aws-vm <command>   # run a command with them as environment variables
```

### Keys: several, any one decrypts

[.sops.yaml](../.sops.yaml) lists every key a file is encrypted for. Any of them decrypts it, so operators, CI and
cloud KMS keys work side by side. After adding a key there, run `sops updatekeys secrets/<stack>.yaml` for each file.

Where the decrypting key comes from is chosen at run time, without code changes:

| Source | How | Typical use |
|---|---|---|
| Local file | `SOPS_AGE_KEY_FILE=<path>`; `lab.sh` uses `local/age.key` (git-ignored) when nothing else is set | Operator machine |
| Variable | `SOPS_AGE_KEY=AGE-SECRET-KEY-…` | CI secret |
| Cloud secret manager | `SOPS_AGE_KEY_CMD='aws secretsmanager get-secret-value --secret-id sops-age --query SecretString --output text'` (or `az keyvault secret show … -o tsv`, `gcloud secrets versions access latest --secret …`) | Cloud runners |
| Cloud KMS | add `kms` / `azure_keyvault` / `gcp_kms` to `.sops.yaml`; the runner's cloud identity decrypts | No key material at all |

A new operator: `age-keygen -o local/age.key`, send the printed public key to someone who can already decrypt; they
add it to `.sops.yaml` and run `sops updatekeys`.

## 3. Create the stack

```bash
cp stacks/customers/customer1/aws/vm.yaml.example stacks/customers/customer1/aws/vm.yaml
```

Fill the Ubuntu 24.04 AMI of the region (Kubemarine 0.55 needs containerd 2.2, which Ubuntu 24.04 ships) and the
operator CIDR for the jump host. Node sizes and counts are in `catalog/aws/vms.yaml` and can be overridden in the stack.
Azure: a complete walkthrough from an empty subscription is [Azure quickstart](azure-vm-quickstart.md)
(template `customer1/azure/staging-vms.yaml.example`). GCP stacks import `catalog/gcp/vms` the same way; the Azure network needs a
`public` subnet and a `kubernetes` subnet with `public: false`.

The workflow file is per stack (Atmos does not pass the stack name to shell steps):
[workflows/customers/customer1/aws-vm.yaml](../workflows/customers/customer1/aws-vm.yaml).

## 4. Deploy

```bash
local/lab.sh with-secrets customer1-aws-vm atmos workflow deploy-vm -f customers/customer1/aws-vm
```

Kubemarine's output streams into the `kubemarine` apply; its dump (logs, final inventory) stays in
`.local-runtime/kubemarine/<environment>/dump`. The workflow ends with `close-access`: the jump host is destroyed,
so nothing in the environment is reachable from outside.

## 5. Working with the cluster later

```bash
local/lab.sh with-secrets customer1-aws-vm atmos workflow open-access -f customers/customer1/aws-vm
kubectl --kubeconfig .local-runtime/kubeconfig-customer1-aws-vm.yaml get pods -A   # proxy-url is in the kubeconfig
local/lab.sh with-secrets customer1-aws-vm atmos workflow deploy-apps -f customers/customer1/aws-vm
local/lab.sh with-secrets customer1-aws-vm atmos workflow close-access -f customers/customer1/aws-vm
```

Nexus UI while the tunnel runs: a browser with SOCKS proxy `127.0.0.1:1080`, then `http://<nexus address>:8081`
(`admin` / `NEXUS_ADMIN_PASSWORD`).

The `kubemarine` component installs once per environment. Later inventory changes go through Kubemarine procedures
(`kubemarine add_node`, `upgrade`, … with `.local-runtime/kubemarine/<environment>/cluster.yaml`); a clean reinstall
is `atmos terraform apply kubemarine -s <stack> -replace=terraform_data.install`.

## 6. Destroy

```bash
local/lab.sh with-secrets customer1-aws-vm atmos workflow destroy-vm -f customers/customer1/aws-vm
```

## Troubleshooting

| Symptom | Where to look |
|---|---|
| `No SSH key` from `lab.sh` | The command was not run under `with-secrets` |
| SOPS: `no identity matched` / `but none were` | No key source set, or the key is not in `.sops.yaml` for this file |
| SSH `REMOTE HOST IDENTIFICATION HAS CHANGED` after VMs were recreated | Delete `.local-runtime/known_hosts-<stack>` |
| Nexus does not answer | On the VM: `systemctl status nexus`, `/opt/sonatype-work/nexus3/log/nexus.log` |
| Kubemarine fails | Apply output; `.local-runtime/kubemarine/<environment>/dump/debug.log` |
| Pods `ImagePullBackOff` | The image is missing in `app_images` of the manifest, or its registry is new: rebuild, reload, re-apply `kubemarine` (`-replace`) so containerd gets the mirror |

## Not verified

- A full run on real AWS, Azure or GCP accounts (Floci runs EC2 as containers, but Kubemarine needs real VMs with
  systemd and kernel modules).
- containerd pulling application images through the `override_path` mirrors on real nodes.
- Kubemarine through the jump host as `gateway_nodes` on real VMs (the inventory passes Kubemarine's schema).
- Loading Nexus for managed stacks: `bundle/load.sh` works for any reachable Nexus, but no managed workflow calls it yet.
- `bundle/load.sh` accepts the [Nexus Community Edition EULA](https://links.sonatype.com/products/nxrm/ce-eula) on
  every Nexus it configures.
