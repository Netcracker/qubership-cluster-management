# CLAUDE.md — working context for Claude

Update as work goes on: requirements, decisions, Q&A, progress. The code is the source of truth about the code;
this file holds only what the code doesn't show (why, what was decided, what's next).

## Who is who
- Boris L in the MoM = the user (Boris Lavrishchev). Owns action items 2 (SOPS + SSH, with Pavel A),
  3 (Kubemarine through a jump host), 4 (CI/CD, runners), 6 (logs/debugging, with Pavel A).
- Document for the 2026-11-16 meeting: https://claude.ai/artifact/VVMsMjwV5JaGkmMD5aR796 (Claude Docs, doc id
  e6b5918c-3be2-433f-994c-2ada753b84fd). Keep it in sync with the decisions below.

## Requirements (MoM + Boris's clarifications, 2026-11-04)
1. Bundle: a manifest of components (Nexus, Argo CD, Headlamp, Istio, Kiali, MinIO, Kubemarine artifacts) with
   versions and original sources.
2. Deployment: 5.1 infrastructure (networks, roles) → 5.2 in parallel {Nexus VM + install + bundle upload;
   node VMs + jump host} → 5.3 wait for the VMs and a populated Nexus → 5.4 cluster.yaml → 5.5 kubemarine install →
   5.6 helmfile.
3. Nexus always runs on a separate VM (for both managed and VM setups). In the VM setup it is the ONLY source:
   nothing is downloaded from the internet.
4. Secrets (SSH keys, cloud credentials) live in the repo under SOPS, with several keys; the key source is easy
   to switch: local file / CI variable / cloud secret manager.
5. MoM: 3 Terraform steps — (1) jump host + Nexus, (2) Kubemarine, (3) remove the jump host.

## Boris's answers (2026-11-04)
1. The bundle gets into Nexus from the operator's machine through the jump host.
2. Helmfile runs on the operator's machine, the same place as atmos (`atmos helmfile ... -s`).
3. Only the VM setup is isolated. Managed (EKS/AKS/GKE) still pulls charts and images from the internet for now.

## Decisions
- VM setup components (per cloud aws/azure/gcp):
  - `<cloud>/network`: a `public` flag on the subnet (AWS: no route to the IGW; Azure: `default_outbound_access_enabled`;
    GCP: isolation = VMs without an external IP). Output `vpc_cidr`.
  - `<cloud>/vms` — shared "VM group" module: `name`, `vms` (map: roles, instance_type, subnet, volume_size),
    `public`, `ports`, `allowed_cidrs`, `ssh_public_key`. Output `vms` = [{name, roles, address, internal_address}].
    Three instances per stack: `jump-host` (public, 22 from the admin CIDR), `nexus` (private, 22/8081/8082 from the
    VPC CIDR), `vms` (nodes, private, 22/80/443/6443 from the VPC CIDR). No SG references between components → the
    jump host can be destroyed on its own. Do NOT apply in parallel: the shared module directory and
    `.terraform/environment` → apply ran against another workspace (on Azure, nexus destroyed the nodes, 2026-11-06).
    The nodes → nexus steps run sequentially.
  - `kubemarine` (cloud-agnostic): builds cluster.yaml from the `vms`, `jump-host`, `nexus` outputs and runs
    `kubemarine install` on the operator's machine (tools image) through the jump host as `gateway_nodes`.
- MoM step (3) "remove the jump host via a variable" is replaced by `atmos terraform destroy jump-host` (separate component).
- SOPS: `secrets/<stack>.yaml`, keys = env variable names (`TF_VAR_ssh_public_key`, `TF_VAR_ssh_private_key`,
  `NEXUS_ADMIN_PASSWORD`, cloud credentials like `AWS_ACCESS_KEY_ID`, `ARM_CLIENT_SECRET`). Run with:
  `sops exec-env secrets/<stack>.yaml '<atmos ...>'` — secrets end up neither in tfvars nor in state.
  age key source: `SOPS_AGE_KEY_FILE` (default `local/age.key`, gitignored), `SOPS_AGE_KEY` (CI),
  `SOPS_AGE_KEY_CMD` (a command that reads the key from a cloud secret manager); plus KMS keys in `.sops.yaml`.
  age is the default; PGP (from the MoM) works as an extra key: `gnupg` in the tools image, fingerprint in `pgp:`,
  secret key imported into the container's keyring (2026-11-11). Verified in the tools image: a file encrypted for
  age + PGP decrypts with either alone; CI-style `gpg --batch --import` from a variable works. Passphrase prompt untested.
- Operator access to the private network: a SOCKS tunnel through the jump host (`local/lab.sh tunnel`). Helmfile gets
  `HTTP(S)_PROXY=socks5://127.0.0.1:<port>`, kubeconfig gets `proxy-url`, server = the control plane's internal IP.
- Nexus: installed over SSH from the bundle (tarball via ProxyJump), `nexus.security.randompassword=false`, then the
  admin password from SOPS. Repositories: one raw hosted `bundle` (third-party files, a flat apt repository, Helm charts
  with index.yaml) and one docker hosted `images` on port 8082, anonymous read.
- Images: Kubemarine images are stored in Nexus without a registry name (`kube-apiserver`, `calico/node`), because
  Kubemarine prepends `registry.mirror_registry`. Application images are stored as `<source registry>/<path>`, with
  containerd mirrors for docker.io/quay.io/ghcr.io/registry.k8s.io using `override_path`.
- Kubemarine 0.55.0: defaults are K8s v1.34.2, calico v3.32.0, nginx-ingress v1.16.0 (ghcr.io/netcracker).
  It needs containerd 2.2.* → Ubuntu 24.04 has it (verified), so the node image is Ubuntu 24.04.
- Azure drops IPIP → Calico VXLAN (in `catalog/azure/vms.yaml`). Kubemarine defaults to `crossSubnet: true` →
  pod traffic inside a subnet is not encapsulated → clouds drop it (on Azure: DNS from pods didn't work, 2026-11-06).
  `crossSubnet: false` in `catalog/kubemarine.yaml` for all clouds.
- Tools in the tools image: sops 3.13.3, age 1.3.2, crane 0.22.1 (+ kubemarine 0.55.0 in a venv).

## Environment facts (verified)
- Floci DOES run EC2 instances as containers with user_data (that's how Nexus works in the AWS lab). Kubemarine still
  needs real VMs (systemd, kernel modules). The docs phrase "Floci doesn't run VMs" is wrong — fix it.
- Atmos doesn't pass the stack name to workflow shell steps → workflows are written for a specific stack.
- Atmos finds stacks only under `stacks/customers/**` → `secrets/`, `bundle/` live outside stacks.
- azurerm validates ID format even with a mock provider → mocks need properly shaped IDs.
- Atmos 1.231.1-rc.0: in `!terraform.state comp '<yq>'` a string literal at the START of the expression is lost
  (`'"http://" + .x'` → `.x`); start with a path: `'.x | "http://" + .'`.
- List comparison in tftest is strictly typed → compare via `jsonencode`.

## Run cost (prices as of 2026-11-04, pay-as-you-go USD, in the meeting document)
- Azure northeurope: ≈ $1.29/h (5×D4s_v5 $0.214, D2s_v5 $0.107, B2s $0.045, StandardSSD E6×5/E15/E4, IP $0.005).
- AWS us-east-1: ≈ $1.13/h (5×m5.xlarge $0.192, m5.large $0.096, t3.small $0.0208, gp3 $0.08/GB-month × 470 GB, IPv4 $0.005).
- Minimal setup 1 CP + 1 worker: Azure ≈ $0.63/h, AWS ≈ $0.54/h. Sources: Azure Retail Prices API, AWS Price List CSV.

## Bundle and GitHub Releases (2026-11-04)
- Full bundle: 2.4 GB (images 1.6G, nexus 500M, files 318M, apt 74M, charts 0.5M), build takes ~10 min; build.sh on
  the full manifest ran without errors.
- GitHub limits: asset file < 2 GiB, total size and bandwidth unlimited, up to 1000 assets (docs.github.com, about-releases).
- `.github/workflows/bundle.yml`: tag `bundle-*` or workflow_dispatch → tar | split 1900M → 2 parts + SHA256SUMS +
  manifest → `gh release create`. Packing/unpacking verified locally (byte-identical), actionlint clean.
  Ran successfully in the fork (borislavr/qubership-cluster-management, workflow_dispatch, 6m17s) → release
  `bundle-2026.11.04-001` (2 parts + SHA256SUMS + manifest).

## CI (2026-11-06)
- `ci.yml`: on a PR from a fork the token is read-only → the `image` job builds the tools image with `docker build`
  (no push to ghcr) and passes it as the `tools-image` artifact; `validate`/`deploy` `docker load` it. Otherwise the
  image is published to ghcr as before. actionlint clean; not yet run on a fork PR.
- All actions in `ci.yml`/`bundle.yml` are pinned to release commit SHAs with the tag in a comment:
  checkout v7.0.1, upload-artifact v7.0.2, download-artifact v8.0.2, qubership-workflow-hub docker-action v2.8.2.

## Azure quickstart (2026-11-04)
- Boris's request: install customer1-azure-staging into an empty Azure subscription, K8s via Kubemarine on VMs, bundle
  from a GitHub Release (the bundle is published and downloaded by Boris).
- Decision: `customer1-azure-staging` in the repo = the Floci lab with AKS, deployed by CI. Per the repo convention
  (`staging.yaml.example`), a real cloud = a copy of the template over staging.yaml in a working branch. Added
  `stacks/customers/customer1/azure/staging-vms.yaml.example`, `workflows/customers/customer1/azure-vm.yaml`,
  `lab.sh ssh`, `docs/azure-vm-quickstart.md`. Azure credentials = a service principal (Cloud Shell) → `sops set` into secrets.
- Needs 24 vCPUs in the region (22 DSv5 + 2 BS) — a new subscription's quotas are usually lower, step 5.1 of the guide.
- Deployed by Boris in a real Azure subscription (2026-11-06). Issues found and fixed on the way: parallel
  nodes/nexus apply hitting the wrong workspace, pod DNS (`crossSubnet: false`), `nexus_charts` URL scheme,
  special characters in Nexus file upload URLs, port-forward on Docker Desktop (`--address 0.0.0.0` + host networking).
- `open-access` fails with "bind 127.0.0.1:1080: Address already in use" when an old `ssh -D` lost its control
  socket: kill it (`pkill -f 'ssh.*-D 127.0.0.1:1080'`) or keep using it.
- Nexus private IP: `internal_address` in `atmos terraform output nexus -s <stack>`.

## Open questions (for the 11-16 meeting)
- CI age key and the GitHub secret `SOPS_AGE_KEY`: who creates them, whose keys to add to `.sops.yaml`.
- Loading Nexus in the managed setup: same loader, but not wired into a workflow yet.
- Testing on AWS and GCP: needs an account/project (Azure is done).
- Saving Kubemarine logs (dump) to S3 — item 6.
- Deferred (2026-11-06): replace `lab.sh with-secrets` (sops exec-env) with the built-in `atmos secret` (available in
  1.231.1-rc.0, EXPERIMENTAL, SOPS provider, `!secret`, `atmos secret exec`). Check first: does `!secret` work in the
  `env` section (in `vars` the secret would land in tfvars.json), does the sops Go SDK support `SOPS_AGE_KEY_CMD`.

## Progress (2026-11-04)
- [x] Networks: `public` flag, `vpc_cidr` output (aws/azure/gcp)
- [x] `<cloud>/vms` = shared VM group for aws/azure/gcp (+ tests with mock providers)
- [x] kubemarine: local-exec + gateway + Nexus, `mirrored_registries` from the manifest; cluster.yaml passes the
      Kubemarine 0.55.0 JSON schema (0 errors)
- [x] SOPS: `.sops.yaml` (Boris's recipient = `local/age.key`), `lab.sh secrets-init` / `with-secrets`;
      key sources verified: file, `SOPS_AGE_KEY`, `SOPS_AGE_KEY_CMD`
- [x] Bundle: manifest/build/load/nexus-install. Verified on a local sonatype/nexus3:3.97.1 + a mini manifest:
      apt install from the flat repo, helm show chart, file, anonymous image pull, repeated load — ok
- [x] lab.sh: tunnel, nexus-install, nexus-load, prepare-vms (NOT run against real VMs)
- [x] Catalogs `catalog/{aws,azure,gcp}/vms.yaml` (jump-host/nexus/vms via abstract vm-group),
      `catalog/kubemarine.yaml`; helmfile catalogs take versions/repos from the manifest via `!include`;
      helmfile url = `{{ .Values | get "nexus_charts" .Values.chart_repository }}`
- [x] Example stack `customers/customer1/aws/vm.yaml.example`, workflow `customers/customer1/aws-vm.yaml`
      (deploy-vm, deploy-nexus, deploy-apps, open-access, close-access, destroy-vm)
- [x] Docs: `docs/vm-installation.md` (main guide), architecture/getting-started/README updated
- [x] Meeting document: context, process (diagram), decisions, SOPS, bundle, questions
- [x] Full `lab.sh check --init` in the tools image — ok; status filled in the document, 1 question-comment left
      (Kubemarine from the operator's machine or on the jump host)
- [x] Real run in Azure (2026-11-06)
- [x] Example stack/workflow for Azure (`staging-vms.yaml.example`, `azure-vm.yaml`)
- [x] First run of the Bundle workflow in GitHub Actions (fork, 2026-11-04)
- [x] CI: local tools image for fork PRs, actions pinned to SHAs (2026-11-06)
- [ ] Real run in AWS and GCP (needs an account)
- [ ] Example stack/workflow for GCP (catalog only so far)
- [ ] PR to upstream: drop CLAUDE.md from the diff, restore LF line endings in README.md

## How to verify locally
- Modules: `terraform init -backend=false && terraform test` in the module directory (or `lab.sh check --init` in the tools image).
- Tools image: `docker build -t qcm-tools:dev .`; run with `-v /var/run/docker.sock:/var/run/docker.sock` for build.sh.
- Nexus loading: `docker run -d --name qcm-nexus --network qcm-test -e NEXUS_SECURITY_RANDOMPASSWORD=false
  sonatype/nexus3:3.97.1`, then build.sh/load.sh in a tools container on the same network (BUNDLE_MANIFEST = mini manifest).
- Kubemarine schema: jsonschema + `kubemarine/resources/schemas/cluster.json` from the tools image's venv.
