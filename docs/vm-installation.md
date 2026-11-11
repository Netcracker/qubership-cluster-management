# Install Kubernetes on VMs with Kubemarine

This workflow uses real AWS or Azure VMs. The operator builds an offline bundle and uploads it to Nexus.
Kubemarine installs Kubernetes over SSH through a jump host. The nodes fetch packages, binaries, and
images from Nexus. Helmfile uses the same Nexus instance for charts. See [stack dependencies](architecture.md#kubemarine-stack-dependencies) for the component and file map.

## 1. Prepare the operator environment

Run the Bash commands from the repository root in Linux or WSL 2. Use the tools pinned in the
[Dockerfile](../Dockerfile), or build and enter the tools container from a Bash shell with access to the
Docker engine. The example uses Linux containers and a Docker socket at `/var/run/docker.sock`.

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

## 2. Select and configure one stack

```bash
cloud=aws   # Set to azure for Azure.
stack="customer1-$cloud-staging-kubemarine"
workflow="customers/customer1/kubemarine/$cloud"
manifest="stacks/customers/customer1/$cloud/staging-kubemarine.yaml"

cp -n "$manifest.example" "$manifest"
```

Set the operator's public CIDR in `components.terraform.jump-host.vars.allowed_cidrs`.
Keep the public jump subnet and private node subnets in the template.

- **AWS** — replace `components.terraform.vm-group.vars.ami_id` with a Canonical Ubuntu 24.04 amd64 AMI in the selected region. The AWS defaults inherit `HTTPS_PROXY=http://127.0.0.1:12334`. Set `env.HTTPS_PROXY` in this VM manifest to a proxy reachable from the operator environment, or set it to `""` for direct access.
- **Azure** — review the region, VM quotas, and subscription permissions for the network and VMs. The VM module already selects an Ubuntu 24.04 amd64 image.

## 3. Build the bundle and configure secrets

```bash
bash ./bundle/build.sh
```

This downloads artifacts listed in [the bundle manifest](../bundle/manifest.yaml) to `.local-runtime/bundle`.
If built on a different machine, transfer that directory to the operator checkout. Use a fresh bundle
directory when changing manifest versions, since the build skips existing artifacts.
The upload script accepts the [Nexus Community Edition EULA](https://links.sonatype.com/products/nxrm/ce-eula)
on the Nexus instance it configures.

For a fresh operator key, run `age-keygen -o local/age.key`. Copy `.sops.yaml.example` to `.sops.yaml`
if no configuration exists, then replace the placeholder recipient with the public key printed by age-keygen.
If the stack already has encrypted secrets, use an existing authorized key.

```bash
export SOPS_AGE_KEY_FILE="$PWD/local/age.key"
bash ./local/lab.sh secrets-init "$stack"
sops "secrets/$stack.yaml"
```

`secrets-init` is a one-time step. It creates the SSH key pair and Nexus password.
In SOPS, add AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN`
for temporary credentials) or Azure service principal credentials (`ARM_SUBSCRIPTION_ID`,
`ARM_TENANT_ID`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`). You can also use credentials available
through the provider's standard authentication chain inside the operator environment.

## 4. Deploy, verify, and destroy

```bash
atmos validate stacks
atmos workflow deploy-vm -f "$workflow" --dry-run
bash ./local/lab.sh with-secrets "$stack" atmos workflow deploy-vm -f "$workflow"
```

Dry-run lists the top-level steps. Deployment creates the network, jump host, node VMs, and Nexus,
then runs Kubemarine and installs the apps. The final step closes the tunnel and destroys the jump host.
Use the same operator environment to reopen access and check the cluster.

```bash
bash ./local/lab.sh with-secrets "$stack" atmos workflow open-access -f "$workflow"
kubectl --kubeconfig ".local-runtime/kubeconfig-$stack.yaml" get nodes
kubectl --kubeconfig ".local-runtime/kubeconfig-$stack.yaml" get pods -A
bash ./local/lab.sh with-secrets "$stack" atmos workflow close-access -f "$workflow"
```

To reapply apps while access is open, run `deploy-apps` with the same workflow file and `with-secrets` wrapper.
Kubemarine installer logs are under `.local-runtime/kubemarine/$stack/dump`.
The installer runs once per environment. Use Kubemarine procedures for node or version changes.

To remove the environment, run:

```bash
bash ./local/lab.sh with-secrets "$stack" atmos workflow destroy-vm -f "$workflow"
```

Destroy stops the tunnel and removes the installer state, VMs, and network. Keep the checkout and its
Terraform state until it finishes.

## Troubleshooting

| Symptom | Check |
|---|---|
| SOPS cannot decrypt | Check `SOPS_AGE_KEY_FILE` and the recipients in the encrypted file. |
| AWS API or registry connection refused | Check the inherited HTTPS proxy from inside the operator shell. |
| Kubernetes API or Nexus is unreachable | Run `open-access` in the same environment. Check the operator CIDR and whether local port 1080 is free. |
| Nexus upload fails | Check that `.local-runtime/bundle/nexus.tar.gz` exists and inspect Nexus logs on the VM. |
| Application pod cannot pull an image | Check the manifest's `app_images` and whether the image was uploaded to Nexus. |

Stack validation and workflow dry-runs have been checked. Full cloud deployment is still unverified.
