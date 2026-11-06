# Quickstart: customer1-azure-staging on Kubemarine VMs in Azure

This guide takes you from **a link to this repository, the downloaded bundle and an empty Azure subscription** to
the `customer1-azure-staging` stack running in Azure: Kubernetes installed by Kubemarine on 5 VMs (not AKS), Nexus on
its own VM, apps installed by Helmfile, and nothing in the cluster able to reach the Internet. Background for every
step is in [VM installation](vm-installation.md).

What gets created in the subscription (region `northeurope`, from `stacks/customers/customer1/azure/_defaults.yaml`):

| Resource | Size | Network |
|---|---|---|
| Jump host | Standard_B2s | public subnet, public IP, SSH from your IP only |
| Nexus | Standard_D2s_v5, 200 GB disk | private subnet, no Internet |
| 3 control-plane + 2 worker nodes | Standard_D4s_v5 each | private subnet, no Internet |

Cost: about **$1.3 per hour** while it exists (list prices of 2026-11-04). A first run with troubleshooting
is a few hours; always finish with [step 10](#10-destroy-everything).

Times below are estimates, not measurements.

## 0. What you need

- Linux x64 or Windows with WSL 2, with Docker Engine and Git (as in [First run](getting-started.md#1-docker-and-git)).
- The bundle release assets you downloaded: `qcm-bundle.tar.part-*` and `SHA256SUMS`.
- Owner rights on the Azure subscription, and a browser for the Azure portal.
- About 10 GB free disk.

## 1. Clone the repository at the bundle's commit

The bundle must match `bundle/manifest.yaml` of the code that loads it. The release notes name the commit the bundle
was built from (`Nexus bundle built from bundle/manifest.yaml at <commit>`).

```bash
git clone https://github.com/<org>/qubership-cluster-management.git
cd qubership-cluster-management
git checkout <commit from the release notes>
git switch -c customer1-azure-staging-vms     # your working branch; never push it to main (step 4 replaces a CI stack)
```

## 2. Unpack the bundle

```bash
mkdir -p .local-runtime
(cd <download dir> && sha256sum -c --ignore-missing SHA256SUMS)
cat <download dir>/qcm-bundle.tar.part-* | tar -x -C .local-runtime
diff bundle/manifest.yaml .local-runtime/bundle/manifest.yaml && echo "bundle matches the code"
```

Expected: both parts `OK`, then `bundle matches the code`. The result is `.local-runtime/bundle` (2.4 GB).

## 3. Start the tools container

Every remaining command runs inside it. It has Atmos, Terraform, Helmfile, kubectl, Kubemarine, sops, age, crane and yq.

```bash
docker build -t qcm-tools .                   # ~5 min; or pull ghcr.io/netcracker/qubership-cluster-management-tools
docker run -d --name qcm-tools --network host -v "$PWD:$PWD" -w "$PWD" qcm-tools sleep infinity
docker exec -it qcm-tools bash
```

Keep this container until step 10: the SSH tunnel to Azure runs inside it. `--network host` also lets your browser
use that tunnel (step 9).

Check that you can decrypt secrets. The repository's [.sops.yaml](../.sops.yaml) lists the keys allowed to decrypt them:

```bash
ls local/age.key || age-keygen -o local/age.key
grep "public key" local/age.key
```

If the printed public key is not in `.sops.yaml`, add it to the `age:` line (comma-separated). Nothing is encrypted yet
for this stack, so no `sops updatekeys` is needed.

## 4. Create the stack

`customer1-azure-staging` in the repository is the local Floci lab with AKS, deployed by CI. Replace it in your branch
with the Kubemarine-on-VMs version:

```bash
cp stacks/customers/customer1/azure/staging-vms.yaml.example stacks/customers/customer1/azure/staging.yaml
curl -s https://ifconfig.me; echo              # your public IP
```

In `stacks/customers/customer1/azure/staging.yaml` replace `203.0.113.10/32` with `<your IP>/32`: only this address
can reach the jump host. To use another region, add `region: <region>` under `vars:`.

Check: `atmos validate stacks` prints `All stacks validated successfully`.

## 5. Prepare the Azure subscription (Azure Cloud Shell)

Open the [Azure portal](https://portal.azure.com) → Cloud Shell (the `>_` icon) → **Bash**. Nothing is installed locally.

```bash
az account show --query "{subscription:id, tenant:tenantId, name:name}" -o table
```

**5.1 vCPU quota.** The stack needs 24 vCPUs in the region: 22 of the DSv5 family, 2 of the BS family.

```bash
az vm list-usage --location northeurope -o table | grep -E "Total Regional vCPUs|DSv5 Family|BS Family"
```

If `Limit` is lower than 24 / 22 / 2, request an increase: portal → **Quotas** → **Compute** → region `North Europe` →
the rows above → **New quota request**. Free Trial subscriptions have low
fixed limits: upgrade to Pay-As-You-Go first.

**5.2 Resource providers.** An empty subscription has them unregistered; registering now avoids a slow first apply.

```bash
az provider register --namespace Microsoft.Compute --wait
az provider register --namespace Microsoft.Network --wait
```

**5.3 Service principal for Terraform.**

```bash
SUBSCRIPTION=$(az account show --query id -o tsv)
az ad sp create-for-rbac --name qcm-customer1-azure-staging --role Contributor --scopes "/subscriptions/$SUBSCRIPTION"
```

Copy `appId`, `password` and `tenant` from the output, and the subscription ID. The password is shown only once.

## 6. Store the secrets

Back in the tools container:

```bash
export SOPS_AGE_KEY_FILE=$PWD/local/age.key
local/lab.sh secrets-init customer1-azure-staging           # SSH key for all VMs + Nexus admin password
f=secrets/customer1-azure-staging.yaml
sops set $f '["ARM_SUBSCRIPTION_ID"]' '"<subscription id>"'
sops set $f '["ARM_TENANT_ID"]' '"<tenant>"'
sops set $f '["ARM_CLIENT_ID"]' '"<appId>"'
sops set $f '["ARM_CLIENT_SECRET"]' '"<password>"'
```

Every value in the file shows as `ENC[...]` (`cat $f`). It is safe to commit to your branch; it never reaches
Terraform state or disk in plain text: commands get it as environment variables through `local/lab.sh with-secrets`.

Check access to Azure (creates nothing):

```bash
local/lab.sh with-secrets customer1-azure-staging atmos terraform plan network -s customer1-azure-staging
```

Expected: `Plan: 4 to add` (resource group, VNet, 2 subnets).

## 7. Deploy

```bash
local/lab.sh with-secrets customer1-azure-staging atmos workflow deploy-vm -f customers/customer1/azure-vm
```

What you will see, in order (about 1–2 hours in total, most of it Kubemarine and the bundle upload):

| Step | What happens | Takes |
|---|---|---|
| `network` | Resource group `customer1-azure-staging-rg`, VNet `10.60.0.0/16`, subnets `public` and `kubernetes` | 1–2 min |
| `open-access` | Jump host, then the SOCKS tunnel `127.0.0.1:1080` through it | 2–4 min |
| `nodes` | 5 VMs | 2–4 min |
| `nexus` | VM → Nexus copied from the bundle and started → 2.4 GB uploaded through the tunnel | 10–40 min, depends on your upload speed |
| `kubemarine` | `cluster.yaml` generated, `kubemarine install` streams its log | 30–60 min |
| `access` | kubeconfig taken from control-plane-1, waits for all nodes `Ready` | 1–5 min |
| `apps` | Istio, Argo CD, Kiali operator, MinIO, Headlamp from Nexus | 10–15 min |
| `close-access` | Tunnel stopped, jump host destroyed | 1–2 min |

After `close-access` nothing in the subscription accepts connections from outside. A failed step stops the workflow;
fix the cause and run the same command again: applied Terraform components change nothing, Kubemarine does not
reinstall, the bundle upload skips what Nexus already has (Nexus itself is copied again).

## 8. Open access and check the cluster

```bash
local/lab.sh with-secrets customer1-azure-staging atmos workflow open-access -f customers/customer1/azure-vm
export KUBECONFIG=$PWD/.local-runtime/kubeconfig-customer1-azure-staging.yaml
kubectl get nodes -o wide            # 5 nodes Ready, INTERNAL-IP in 10.60.1.0/24, no EXTERNAL-IP
kubectl get pods -A                  # all Running or Completed
```

Every image came from Nexus (`kubectl get pods -A -o jsonpath='{..image}' | tr ' ' '\n' | sort -u` shows the original
names; containerd pulled them through the Nexus mirrors).

Check the isolation: a node cannot reach the Internet, but reaches Nexus.

```bash
NODE=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')   # any node
local/lab.sh with-secrets customer1-azure-staging local/lab.sh ssh customer1-azure-staging $NODE \
  'curl -sS -m 5 -o /dev/null https://archive.ubuntu.com && echo "INTERNET REACHABLE" || echo "isolated: OK"'
```

## 9. Open the applications

While access is open, port-forward from the container (`--network host` makes it reachable from your browser):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:80      # http://127.0.0.1:8080, user admin
```

The same way: Headlamp (`-n headlamp svc/headlamp`), MinIO (`-n storage svc/minio-console`), Kiali
(`-n istio-system svc/kiali 20001`). Nexus UI: set the browser's SOCKS proxy to `127.0.0.1:1080` and open
`http://<Nexus private IP>:8081` (`admin`, password `NEXUS_ADMIN_PASSWORD` from `sops -d secrets/customer1-azure-staging.yaml`).

Close access when done:

```bash
local/lab.sh with-secrets customer1-azure-staging atmos workflow close-access -f customers/customer1/azure-vm
```

## 10. Destroy everything

```bash
local/lab.sh with-secrets customer1-azure-staging atmos workflow destroy-vm -f customers/customer1/azure-vm
```

Terraform state is local (`components/terraform/*/terraform.tfstate.d/`): do not delete the clone before this step.
Then, in Cloud Shell, check that nothing is left and remove the service principal:

```bash
az group list -o table                        # no customer1-azure-staging-rg
az ad sp delete --id <appId>
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `QuotaExceeded` / `OperationNotAllowed ... quota` | Step 5.1: the vCPU quota is lower than the stack needs |
| `SkuNotAvailable` | The VM size has no capacity in the region: another `region`, or other `instance_type` values in the stack (`catalog/azure/vms.yaml` lists them) |
| `AuthorizationFailed` | The service principal lacks `Contributor` on the subscription, or the `ARM_*` values are wrong (`sops -d secrets/customer1-azure-staging.yaml`) |
| `MissingSubscriptionRegistration` | Step 5.2 was skipped; register the provider and re-run |
| `Timed out waiting for SSH on the jump host` | Your public IP changed: update `allowed_cidrs` (step 4), re-run `open-access` |
| Kubemarine fails on packages or images | Nexus is not fully loaded: `local/lab.sh with-secrets customer1-azure-staging local/lab.sh nexus-load customer1-azure-staging` (with access open), then `atmos terraform apply kubemarine -s customer1-azure-staging -replace=terraform_data.install` |

More symptoms and log locations: [VM installation → Troubleshooting](vm-installation.md#troubleshooting).
