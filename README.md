# Qubership Cluster Manager

Deploy Kubernetes infrastructure and applications with Atmos, Terraform, and Helmfile.
Customer stacks combine reusable components with cloud and environment settings.
Workflows define the order of deployment and deletion.

| Deployment path | How Kubernetes is installed | Start here |
|---|---|---|
| Managed Kubernetes | Terraform uses the cloud Kubernetes API. The local AWS and Azure scenarios use Floci. | [First run with Floci](docs/getting-started.md) |
| Kubemarine on VMs | Terraform creates VMs. Kubemarine installs Kubernetes over SSH using an offline bundle served by Nexus. | [VM installation on AWS and Azure](docs/vm-installation.md) |

Both paths use shared Helmfile components. Managed stacks use public chart repositories.
Kubemarine stacks use the chart repository and versions from the Nexus bundle.

## Documentation

- [Architecture and repository layout](docs/architecture.md#repository-layout) describes the directory tree, stack imports, Terraform dependencies, and Helmfile values.
- [Local development](docs/local-development.md) explains the Floci scripts, proxy settings, readiness, and troubleshooting.
- [Managed cloud preparation](docs/deployment.md) covers real Azure and Google Cloud accounts.
- [Managed deployment diagrams](docs/diagrams/README.md) includes the draw.io source and PNG previews.
