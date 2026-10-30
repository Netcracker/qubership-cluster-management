# First run on Windows

This guide explains what to install after cloning, which scripts to run, and how to deploy.
Docker Desktop runs Floci and Kubernetes nodes. Atmos, Terraform, Helmfile, and preparation scripts run on Windows;
Docker Desktop alone is not enough. There is no all-in-one project installer or operator-tools image yet.

The documented host is Windows x64 (Intel/AMD), PowerShell 7, and Docker Desktop with Linux containers.
Azure startup uses the Windows certificate store; Linux/macOS startup is not validated.
Cloud accounts, Azure CLI, gcloud, Java, Python, and a separate Kubernetes installation are not needed for these local labs.

## The complete sequence

```text
Install tools once -> clone/open repository -> create local settings and review network access
  -> Test-Project.ps1 -Initialize: download providers and validate, without deployment
  -> Start-Local.ps1 OR Start-AzureLocal.ps1: start the selected emulator
  -> Atmos deploy workflow: create customer infrastructure and applications
  -> check Kubernetes and access applications
  -> Atmos destroy workflow: delete customer resources
  -> stop the selected emulator
```

Installing tools does not start the lab. Start does not call deploy. Stop does not call destroy.
Choose AWS or Azure for your first run; starting both is not required.

## 1. Docker Desktop, Git, and PowerShell

If Docker Desktop is already installed and running, skip installation.
Otherwise follow the [official Windows installation guide](https://docs.docker.com/desktop/setup/install/windows-install/)
for supported Windows versions, virtualization, WSL 2, and any required restart.
Start Docker Desktop manually, select Linux containers, and wait for the engine.
Its built-in Kubernetes is not needed: Floci creates k3s itself.
Allow enough RAM/disk for Kubernetes, applications, and AWS Nexus; Docker's minimum requirements alone are not a tested lab sizing guarantee.

```powershell
docker version
docker info --format '{{.OSType}}'
docker compose version
```

Expected: Docker client/server available, OSType `linux`, Compose version printed. Compose is bundled with Docker Desktop.
Do not install a second Docker daemon inside WSL for this guide.

Install Git and PowerShell 7 if absent, from your existing Windows terminal:

```powershell
winget install --id Git.Git --exact --source winget
winget install --id Microsoft.PowerShell --exact --source winget
```

If winget is unavailable, use [Git for Windows](https://git-scm.com/install/windows) and
[Microsoft's PowerShell installer](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows).
Finish installation, close the terminal, and open PowerShell 7 from Start. Run remaining commands there.
Windows PowerShell 5.1 (`powershell.exe`) does not satisfy scripts requiring PowerShell 7 (`pwsh.exe`).

## 2. Install the deployment tools

These versions were observed on the development machine on 2026-10-28. They are a reproducibility baseline;
arbitrary newer versions have not been tested with these hooks and parallel workflows.

| Tool | Tested version | Purpose | Windows x64 download |
|---|---|---|---|
| Atmos | 1.231.1-rc.0 | Stacks and workflows | [Executable](https://github.com/cloudposse/atmos/releases/download/v1.231.1-rc.0/atmos_1.231.1-rc.0_windows_amd64.exe) |
| Terraform | 1.16.5 | Infrastructure | [ZIP](https://releases.hashicorp.com/terraform/1.16.5/terraform_1.16.5_windows_amd64.zip) |
| kubectl | 1.34.3 | Kubernetes access | [Executable](https://dl.k8s.io/release/v1.34.3/bin/windows/amd64/kubectl.exe) |
| Helm | 4.3.1 | Chart installation | [ZIP](https://get.helm.sh/helm-v4.3.1-windows-amd64.zip) |
| Helmfile | 1.8.1 | Application releases | [tar.gz](https://github.com/helmfile/helmfile/releases/download/v1.8.1/helmfile_1.8.1_windows_amd64.tar.gz) |
| AWS CLI | 2.37.9 | AWS API/EKS tokens; AWS lab only | [MSI](https://awscli.amazonaws.com/AWSCLIV2-2.37.9.msi) |
| helm-diff | 3.15.13 | Helmfile change detection | Install after Helm below |

Install AWS CLI using its MSI if running AWS workflows. Create a per-user directory for the other tools:

```powershell
$toolsDirectory = Join-Path $env:LOCALAPPDATA 'Qubership\bin'
New-Item -ItemType Directory -Path $toolsDirectory -Force | Out-Null
$toolsDirectory
```

Download and verify releases using the publishers' checksum/signature instructions. Place these executables in that directory:

1. Rename the Atmos download to `atmos.exe`.
2. Extract `terraform.exe` from its ZIP.
3. Copy `kubectl.exe`.
4. Extract `helm.exe` from Helm's `windows-amd64` subdirectory.
5. Extract `helmfile.exe` from its tar.gz. Windows `tar` supports these archives; use the downloaded filename in an empty extraction directory.

Add the directory to user PATH and the current session:

```powershell
$toolsDirectory = Join-Path $env:LOCALAPPDATA 'Qubership\bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($toolsDirectory -notin @($userPath -split ';')) {
    [Environment]::SetEnvironmentVariable('Path', "$toolsDirectory;$userPath", 'User')
}
$env:Path = "$toolsDirectory;$env:Path"
```

Reopen PowerShell after the AWS CLI installer to receive its PATH update.
If Docker Desktop provides another kubectl, `Get-Command kubectl -All` shows which executable wins.
Official installation/verification references: [Atmos](https://atmos.tools/install/),
[Terraform](https://developer.hashicorp.com/terraform/install), [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/),
[Helm](https://helm.sh/docs/intro/install/), [Helmfile](https://helmfile.readthedocs.io/en/latest/#installation),
[AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).

### Install helm-diff and check the toolchain

Once Git, PowerShell 7, and Helm are on PATH, run once:

```powershell
helm plugin install https://github.com/databus23/helm-diff --version v3.15.13 --verify=false
helm plugin list
helm diff version
```

For Helm 4, `--verify=false` explicitly skips plugin signature verification for this legacy Git installation;
it does not disable TLS verification. URL/version refer to the upstream project.
See [helm-diff installation](https://github.com/databus23/helm-diff#install). If already installed, inspect its version instead.

```powershell
$PSVersionTable.PSVersion
Get-Command docker, git, pwsh, atmos, terraform, kubectl, helm, helmfile
atmos version
terraform version
kubectl version --client
helm version --short
helmfile --version
aws --version
```

Expected: PowerShell major version 7 or later and required tools found. Skip the AWS CLI check for Azure-only use.
No manual Floci image download is needed: Compose pulls missing images when Start runs.

## 3. Get the repository and create settings

If you already have a checkout, open PowerShell in its root and skip cloning.
Otherwise run from the directory where you want it:

```powershell
git clone https://github.com/Netcracker/qubership-cluster-management.git
Set-Location qubership-cluster-management
```

All remaining commands assume the repository root containing `atmos.yaml`. For AWS, create settings once:

```powershell
if (-not (Test-Path -LiteralPath ./local/settings.json)) {
    Copy-Item ./local/settings.example.json ./local/settings.json
}
```

Review endpoint, region, Docker subnet, and DNS. The AWS defaults use Docker subnet 172.18.0.0/16;
check VPN/other-network conflicts. Compose fixed IPs must remain consistent with local settings.

## 4. Network access, proxies, and providers

Downloading Terraform itself and downloading its providers are separate operations. Terraform can be installed
while `terraform init` cannot reach the registry or download server. Requests from restricted
networks may receive HTTP 403; proxy, DNS, TLS, and connection errors have different causes.
An existing provider cache does not prove a fresh machine can download providers.

| Setting | Purpose | Location |
|---|---|---|
| HTTPS_PROXY / HTTP_PROXY | External CLI requests through an available proxy | Calling terminal; Atmos component environment where overridden |
| NO_PROXY | Direct access to local Floci/Kubernetes | Calling terminal and stack environment |
| Docker Desktop proxy | Docker image downloads | Docker Desktop settings, separately from stack variables |
| Terraform provider mirror | Alternative provider package source | Terraform CLI configuration, separately from project .tf files |

The committed `http://127.0.0.1:12334` proxy belongs to the development machine. This repository does not supply it.
Before deployment, review `env.HTTPS_PROXY` in:

- `stacks/customers/customer1/aws/_defaults.yaml` for AWS;
- `stacks/customers/customer1/azure/staging.yaml` for Azure.

Remove that YAML entry if no proxy is needed, or replace it with your working proxy address.
A terminal setting alone does not override a conflicting value explicitly set in the Atmos stack.
Review inherited terminal proxy variables too. Configure Docker Desktop's proxy separately if image pulls need one.
Do not commit proxy passwords. No proxy settings are changed automatically by this guide.

The validation script runs Terraform directly, so its provider downloads use the calling terminal's environment,
not the Atmos stack's env block. Set the same working proxy in that terminal before initialization.
For the development machine's address, the commands are below; use them only if a proxy actually listens on that port,
or replace the URL with your available proxy:

```powershell
$env:HTTPS_PROXY = 'http://127.0.0.1:12334'
$env:HTTP_PROXY = $env:HTTPS_PROXY
```

If no proxy is needed, remove stale values from this terminal instead:

```powershell
Remove-Item Env:HTTPS_PROXY, Env:HTTP_PROXY -ErrorAction SilentlyContinue
```

These commands affect this terminal and its children; they do not update other terminals or stack YAML.

Keep local APIs bypassed in the calling terminal:

```powershell
$env:NO_PROXY = 'localhost,127.0.0.1,::1,floci'
```

The stack also defines NO_PROXY for its child tools. Do not add registry.terraform.io or releases.hashicorp.com
to NO_PROXY when they must use your proxy. NO_PROXY does not unblock an external server; it prevents local API
requests from being sent through that external proxy.

### Optional provider mirror

When direct downloads are unavailable, use an approved mirror. Yandex Cloud documents
`https://terraform-mirror.yandexcloud.net/` in its [setup guide](https://yandex.cloud/en/docs/terraform/quickstart).
Check coverage for the exact locked provider version and Windows platform. This changes the download source, not the deployment cloud.

On Windows, edit the current user's `%APPDATA%\terraform.rc`, not `terraform.rc.txt`.
Merge with any existing configuration instead of overwriting it. For this project's HashiCorp providers:

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

Exclusion prevents matching providers from also consulting the blocked origin.
See [Terraform CLI configuration](https://developer.hashicorp.com/terraform/cli/config/config-file#provider-installation)
for mirror selection and the TF_CLI_CONFIG_FILE override; check that variable if the default config appears ignored.
Provider sources stay hashicorp/aws, hashicorp/azurerm, hashicorp/google, and hashicorp/kubernetes.
Keep committed .terraform.lock.hcl files; do not delete locks or use init -upgrade just to bypass a download error.
A missing mirror version or checksum mismatch needs investigation, not disabled integrity checks.

`versions.tf` sets compatible version ranges; each root module's `.terraform.lock.hcl` records its selected versions
and checksums. The current locks contain AWS 6.68.0 or 6.70.0 depending on the module, AzureRM 4.81.0,
Google 7.46.2, and Kubernetes 3.4.0. Do not silently unify or upgrade them during machine setup.
On 2026-10-28, the mirror metadata listed Windows amd64 archives for all five provider/version combinations.
This metadata check is not a full clean-machine initialization or an availability guarantee for another network/date.

### Diagnose download access

These commands report connectivity/status and intentionally have finite timeouts:

```powershell
curl.exe -I --connect-timeout 10 --max-time 20 https://registry.terraform.io/.well-known/terraform.json
curl.exe -I --connect-timeout 10 --max-time 20 https://releases.hashicorp.com/
```

If using the mirror, inspect its AWS provider listing too:

```powershell
curl.exe --fail --connect-timeout 10 --max-time 20 https://terraform-mirror.yandexcloud.net/registry.terraform.io/hashicorp/aws/index.json
```

An accessible listing does not prove a particular archive exists. Terraform init is the final download check.
Repeated 403 responses require a working download route/mirror; endless retries do not solve access denial.
After fixing settings, rerun initialization without deleting state/locks.
Provider mirrors do not cover Helm charts, Docker images, or Nexus installation downloads.

## 5. Run the configuration check

After installing tools and reviewing network settings:

```powershell
atmos validate stacks
pwsh -NoProfile -File ./local/scripts/Test-Project.ps1 -Initialize
```

Expected: `Configuration checks passed. No infrastructure changes were applied.`
Initialize downloads providers for all modules and validates them; it does not start Docker or deploy customer resources.
Resolve provider failures before deployment using the preceding section.
Kubeconfigs, state, and emulator data are excluded from Git and are created later.

## 6. Start and deploy AWS customer1

```powershell
pwsh -NoProfile -File ./local/scripts/Start-Local.ps1
if ($LASTEXITCODE -ne 0) { throw 'AWS emulator startup failed.' }
atmos workflow deploy-staging-no-hook -f customers/customer1/aws
if ($LASTEXITCODE -ne 0) { throw 'Deployment failed; inspect the reported workflow step.' }
```

Start creates the external network if absent, starts Floci/UI, and waits for emulator health.
It does not deploy or wait for Argo CD/Nexus. The workflow creates infrastructure, prepares Kubernetes access,
then runs Nexus/readiness and applications/ALB in parallel. Terraform uses -auto-approve.
Use deploy-staging instead for hook-based Nexus readiness; choose one variant per run.
First deployment includes downloads and Nexus installation, so completion can take time.

```powershell
kubectl --kubeconfig ./.local-runtime/kubeconfig-customer1-aws-staging.yaml get nodes
kubectl --kubeconfig ./.local-runtime/kubeconfig-customer1-aws-staging.yaml get pods -A
helm --kubeconfig ./.local-runtime/kubeconfig-customer1-aws-staging.yaml list -A
pwsh -NoProfile -File ./local/scripts/Get-NexusEndpoint.ps1 -Stack customer1-aws-staging
```

Expected: Ready node, ready application pods, deployed Helm releases. A completed MinIO bucket Job is normal.
Open http://localhost:4500 for Floci UI and http://argocd.localhost, http://kiali.localhost,
http://minio.localhost, http://headlamp.localhost for applications. Nexus uses the script's dynamic URL.
Application login/token requirements still apply.

## 7. Start and deploy Azure customer1

Azure uses a separate Compose/API on port 4577; AWS Floci and Azure CLI are not required.
Start trusts the emulator CA in the current Windows user's root store and starts the emulator only.
For a fresh Azure environment with no existing cluster/state:

```powershell
pwsh -NoProfile -File ./local/scripts/Start-AzureLocal.ps1
if ($LASTEXITCODE -ne 0) { throw 'Azure emulator startup failed.' }
atmos workflow deploy-staging -f customers/customer1/azure
if ($LASTEXITCODE -ne 0) { throw 'Deployment failed; inspect the reported workflow step.' }
```

The stack records load-balancer backend IP 172.19.0.3; Docker can allocate another address on a new machine.
After access preparation, compare the node's InternalIP with
components.terraform.load-balancer.vars.backend_addresses.kubernetes in the Azure staging manifest:

```powershell
kubectl --kubeconfig ./.local-runtime/kubeconfig-customer1-azure-staging.yaml get nodes -o wide
```

Update that local setting if different. Floci Azure LB does not forward traffic, regardless of this configuration.
Before repeating infrastructure apply, inspect its plan: Floci AKS read-back omits properties and has caused replacement plans.
With existing network state:

```powershell
atmos terraform plan kubernetes -s customer1-azure-staging -input=false
```

For an existing cluster, refresh access and apply applications/LB without reapplying Kubernetes:

```powershell
atmos workflow deploy-staging -f customers/customer1/azure --from-step access
kubectl --kubeconfig ./.local-runtime/kubeconfig-customer1-azure-staging.yaml get nodes
kubectl --kubeconfig ./.local-runtime/kubeconfig-customer1-azure-staging.yaml get pods -A
```

Run each port-forward in a separate terminal from the repository root:

```powershell
kubectl --kubeconfig ./.local-runtime/kubeconfig-customer1-azure-staging.yaml -n argocd port-forward svc/argocd-server 18080:80
```

```powershell
kubectl --kubeconfig ./.local-runtime/kubeconfig-customer1-azure-staging.yaml -n istio-system port-forward svc/kiali 18081:20001
```

Leave these running and open http://localhost:18080 and http://localhost:18081; both returned HTTP 200 in validation.
Ctrl+C ends that port-forward, not the application. See [Azure limitations](../README.md#azure-emulator-limitations).
GCP is an inactive template; no unverified GCP launch sequence is provided here.

## 8. Destroy resources, then stop

Keep Docker and the emulator running until deletion succeeds. AWS customer1:

```powershell
atmos workflow destroy-staging-parallel -f customers/customer1/aws
if ($LASTEXITCODE -ne 0) { throw 'Deletion failed. Keep Floci running.' }
pwsh -NoProfile -File ./local/scripts/Stop-Local.ps1
```

Azure customer1:

```powershell
atmos workflow destroy-staging -f customers/customer1/azure
if ($LASTEXITCODE -ne 0) { throw 'Deletion failed. Keep Floci Azure running.' }
docker compose -f ./local/compose.azure.yml stop
```

Terraform steps use -auto-approve. Kiali CR is deleted before its operator; applications/LB before Kubernetes/network.
AWS parallel destroy and Azure destroy have been checked with dry-run, not real end-to-end deletion in this session.
Stop retains state/data. Azure preserves AKS across emulator shutdowns, so destroy must come first.
Do not delete state or Floci data as a substitute for resource deletion.

## First-run troubleshooting

| Symptom | Check / action |
|---|---|
| Command not found | Complete installation, reopen terminal, inspect PATH / Get-Command |
| PowerShell version error | Use pwsh, not Windows PowerShell 5.1 |
| Script blocked by execution policy | Review script and organization policy; use Microsoft's documented process-scoped options if appropriate |
| Docker unavailable / wrong engine | Start Docker Desktop; select Linux containers |
| settings.json missing | Copy the example before AWS Start |
| Terraform init HTTP 403 | Review region/access restrictions, proxy, and mirror; retries alone do not fix denial |
| Local API 502 / attempts to use port 12334 | Correct HTTPS_PROXY and keep local endpoints in NO_PROXY |
| TLS errors | Review trusted certificates and corporate proxy CA; do not disable TLS verification as the default fix |
| helm-diff missing | Install plugin and check helm diff version |
| Port already allocated | Inspect containers/processes: AWS uses 80/4500/4566; Azure API 4577 and AKS ports in 6600–6699 |
| Docker Address already in use | Inspect networks; see recovery notes. Do not delete shared networks/state |
| Kubeconfig missing | Deploy/access preparation creates it; Start alone does not |
| Azure LB IP does not open UI | Expected emulator limitation; use port forwarding |

## Verification scope

Repository paths, workflow names, installed versions, configuration checks, and workflow dry-runs were checked.
Earlier AWS/Azure deployments and Azure UI port-forward checks were performed. The complete installation sequence
has not been run on a clean Windows VM; an already provisioned machine does not establish that result.

See [local development](local-development.md) for script internals/recovery, [architecture](architecture.md)
for imports/values, and [five-page diagrams](diagrams/README.md) for visual explanations.
