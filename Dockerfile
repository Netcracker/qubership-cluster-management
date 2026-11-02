# Operator tools for Atmos stacks: the versions match docs/getting-started.md.
FROM docker:28.5.2-cli AS docker

FROM ubuntu:24.04
ARG ATMOS_VERSION=1.231.1-rc.0
ARG TERRAFORM_VERSION=1.16.5
ARG KUBECTL_VERSION=1.34.3
ARG HELM_VERSION=4.3.1
ARG HELM_DIFF_VERSION=3.15.13
ARG HELMFILE_VERSION=1.8.1
ARG AWSCLI_VERSION=2.37.9

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq unzip less \
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
 && rm -rf /tmp/*

WORKDIR /workspace
CMD ["bash"]
