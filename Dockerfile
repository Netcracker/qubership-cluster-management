# Operator tools for Atmos stacks: the versions match docs/getting-started.md.
FROM docker:28.5.2-cli AS docker
RUN apk add --no-cache binutils && strip /usr/local/bin/docker /usr/local/libexec/docker/cli-plugins/docker-compose

FROM ubuntu:24.04
ARG ATMOS_VERSION=1.231.1-rc.0
ARG TERRAFORM_VERSION=1.16.5
ARG KUBECTL_VERSION=1.34.3
ARG HELM_VERSION=4.3.1
ARG HELM_DIFF_VERSION=3.15.13
ARG HELMFILE_VERSION=1.8.1
ARG AWSCLI_VERSION=2.37.9
ARG KUBEMARINE_VERSION=0.55.0
ARG SOPS_VERSION=3.13.3
ARG AGE_VERSION=1.3.2
ARG CRANE_VERSION=0.22.1
ARG YQ_VERSION=4.53.6

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq unzip less openssh-client python3-venv gnupg \
 && rm -rf /var/lib/apt/lists/*

COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose

RUN set -eux; cd /tmp \
 && curl -fsSLo /usr/local/bin/atmos "https://github.com/cloudposse/atmos/releases/download/v${ATMOS_VERSION}/atmos_${ATMOS_VERSION}_linux_amd64" \
 && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/atmos /usr/local/bin/kubectl \
 && curl -fsSLo tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
 && unzip -q tf.zip terraform -d /usr/local/bin \
 && curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz --strip-components=1 -C /usr/local/bin linux-amd64/helm \
 && curl -fsSL "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz" | tar -xz -C /usr/local/bin helmfile \
 && curl -fsSLo aws.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" \
 && unzip -q aws.zip && ./aws/install \
 && helm plugin install https://github.com/databus23/helm-diff --version "v${HELM_DIFF_VERSION}" --verify=false \
 && curl -fsSLo /usr/local/bin/sops "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
 && curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" | tar -xz --strip-components=1 -C /usr/local/bin age/age age/age-keygen \
 && curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" | tar -xz -C /usr/local/bin crane \
 && curl -fsSLo /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
 && chmod +x /usr/local/bin/sops /usr/local/bin/yq \
 && rm -rf /usr/local/aws-cli/v2/*/dist/awscli/examples /usr/local/aws-cli/v2/*/dist/aws_completer /usr/local/bin/aws_completer \
 && apt-get update && apt-get install -y --no-install-recommends binutils \
 && strip /root/.local/share/helm/plugins/helm-diff/bin/diff \
 && apt-get purge -y --auto-remove binutils && rm -rf /var/lib/apt/lists/* /tmp/*

# Kubemarine installs Kubernetes on <cloud>/vms through the jump host; a venv keeps its pinned dependencies apart.
RUN python3 -m venv /opt/kubemarine \
 && /opt/kubemarine/bin/pip install --no-cache-dir "kubemarine==${KUBEMARINE_VERSION}" \
 && /opt/kubemarine/bin/pip uninstall -y -q pip \
 && ln -s /opt/kubemarine/bin/kubemarine /opt/kubemarine/bin/_kubemarine /usr/local/bin/

WORKDIR /workspace
CMD ["bash"]
