#!/usr/bin/env bash
# Local Floci laboratory helpers. Run `local/lab.sh` without arguments for usage.
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="$PWD/.local-runtime"
COMPOSE=local/compose.yml
SETTINGS=local/settings.json
[[ -f $SETTINGS ]] || SETTINGS=local/settings.example.json
ENDPOINT=$(jq -r .endpoint "$SETTINGS")
REGION=$(jq -r .region "$SETTINGS")
NETWORK=$(jq -r .network "$SETTINGS")
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}localhost,127.0.0.1,::1,floci"
export no_proxy=$NO_PROXY AWS_PAGER=""
mkdir -p "$RUNTIME"

die() { echo "$*" >&2; exit 1; }
quiet() { "$@" >/dev/null 2>&1; }
awsl() { aws --endpoint-url "$ENDPOINT" --region "$REGION" --no-cli-pager "$@"; }

wait_for() { # description seconds command...
    local description=$1 deadline=$((SECONDS + $2)); shift 2
    until "$@"; do
        ((SECONDS < deadline)) || die "Timed out waiting for $description."
        sleep 2
    done
}

check_stack() { [[ ${1:-} =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "Invalid stack name: ${1:-}"; }

# Prints the component's resolved configuration; Atmos messages go to stderr, not into the JSON.
describe() { # component stack [atmos args...]
    local file; file=$(mktemp)
    atmos describe component "$1" -s "$2" --format json --file "$file" "${@:3}" >&2 ||
        { rm -f "$file"; die "Cannot describe $1 for stack $2."; }
    [[ -s $file ]] || { rm -f "$file"; die "Atmos wrote no configuration for stack $2."; }
    cat "$file"; rm -f "$file"
}

running() { [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }
floci_healthy() {
    local id; id=$(docker compose -f "$COMPOSE" ps -q floci)
    [[ -n $id && $(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null) == healthy ]]
}
container_created() { [[ $(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null) =~ ^(running|exited)$ ]]; }

cmd_start() {
    quiet docker network inspect "$NETWORK" ||
        docker network create --subnet "$(jq -r .subnet "$SETTINGS")" --gateway "$(jq -r .gateway "$SETTINGS")" "$NETWORK" >/dev/null
    echo 'Starting Floci and its console'
    docker compose -f "$COMPOSE" up -d
    wait_for 'Floci health' 180 floci_healthy
    echo 'Local environment started (Floci and UI). Console: http://127.0.0.1:4500'
}

cmd_stop() {
    # Customer resources must be destroyed separately before stopping the emulator.
    docker compose -f "$COMPOSE" stop --timeout 60 floci
    docker compose -f "$COMPOSE" stop --timeout 10 ui
    echo 'Local environment stopped (Floci and UI). State and data retained.'
}

cmd_prepare() {
    local stack=$1 config identity cluster container profile user kubeconfig
    check_stack "$stack"
    export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
    config=$(describe argocd "$stack")
    [[ $(jq -r '.settings.local_lab // false' <<<"$config") == true ]] || die "Stack $stack is not a local Floci stack."
    identity=$(jq -r '.vars.environment // empty' <<<"$config")
    [[ -n $identity ]] || die "Stack $stack does not define environment."
    cluster="$identity-eks" container="floci-aws-eks-$identity-eks"
    profile="floci-$identity" user="$identity-kubectl"
    kubeconfig="$RUNTIME/kubeconfig-$stack.yaml"

    # Node address: the EC2 record preserves it even for a stopped k3s container.
    local description generation nodes="$RUNTIME/nodes.json" ip
    description=$(awsl eks describe-cluster --name "$cluster" --output json)
    generation=$(jq -r .cluster.createdAt <<<"$description")
    wait_for "$cluster container" 180 container_created "$container"
    [[ -f $nodes ]] || echo '{}' >"$nodes"
    ip=$(jq -r --arg s "$stack" --arg g "$generation" '.[$s] | select(.generation == $g) | .ip // empty' "$nodes")
    if [[ -z $ip ]]; then
        local ips
        ips=$(awsl ec2 describe-instances --output json --filters \
            "Name=vpc-id,Values=$(jq -r .cluster.resourcesVpcConfig.vpcId <<<"$description")" \
            Name=instance-state-name,Values=running "Name=tag:eks:cluster-name,Values=$cluster" |
            jq -r '.Reservations[].Instances[].PrivateIpAddress // empty')
        [[ $(grep -c . <<<"$ips") == 1 ]] || die "Expected one local k3s node for $stack; found $(grep -c . <<<"$ips")."
        ip=$ips
    fi
    jq --arg s "$stack" --arg g "$generation" --arg ip "$ip" '.[$s] = {ip: $ip, generation: $g}' "$nodes" >"$nodes.tmp"
    mv "$nodes.tmp" "$nodes"

    # Pin the node address on the lab network.
    local pinned
    pinned=$(docker inspect -f "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{with .IPAMConfig}}{{.IPv4Address}}{{end}}{{end}}" "$container")
    if [[ $pinned != "$ip" ]]; then
        echo "Restoring $stack node address $ip"
        if running "$container"; then docker stop --timeout 30 "$container" >/dev/null; fi
        if [[ -n $(docker inspect -f "{{if index .NetworkSettings.Networks \"$NETWORK\"}}yes{{end}}" "$container") ]]; then
            docker network disconnect "$NETWORK" "$container"
        fi
        docker network connect --ip "$ip" "$NETWORK" "$container"
    fi

    # Point the token webhook at floci by name.
    local floci_id floci_ip webhook before after
    floci_id=$(docker compose -f "$COMPOSE" ps -q floci)
    [[ -n $floci_id ]] || die 'Floci is not running. Start the local lab first.'
    floci_ip=$(docker inspect -f "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{.IPAddress}}{{end}}" "$floci_id")
    [[ -n $floci_ip ]] || die 'Floci has no address on the lab network.'
    webhook=$(mktemp)
    docker cp "$container:/etc/token-webhook.yaml" "$webhook"
    before=$(cat "$webhook")
    after=$(sed -E 's#http://[^/[:space:]]+:4566/#http://floci:4566/#g' <<<"$before")
    grep -Eq 'server:[[:space:]]+http://floci:4566/' <<<"$after" || { rm -f "$webhook"; die 'Unexpected token-webhook format.'; }
    if [[ $before != "$after" ]]; then
        if running "$container"; then docker stop --timeout 30 "$container" >/dev/null; fi
        printf '%s\n' "$after" >"$webhook"
        docker cp "$webhook" "$container:/etc/token-webhook.yaml"
    fi
    rm -f "$webhook"
    running "$container" || docker start "$container" >/dev/null

    # Floci's synthetic VPC DNS is unreachable by containerd in this lab.
    { docker exec "$container" cat /etc/hosts | grep -Ev '(^|[[:space:]])floci([[:space:]]|$)|^$' || true
      echo "$floci_ip floci"; } | docker exec -i "$container" tee /etc/hosts >/dev/null
    jq -r '.dnsServers[] | "nameserver \(.)"' "$SETTINGS" | docker exec -i "$container" tee /etc/resolv.conf >/dev/null
    wait_for "$stack Kubernetes API" 180 quiet docker exec "$container" kubectl --request-timeout=5s get --raw=/readyz

    # Access: an AWS profile for the Terraform-created IAM user and an exec kubeconfig.
    local expected="arn:aws:iam::000000000000:user/$user" saved key
    if [[ $(awsl sts get-caller-identity --profile "$profile" --query Arn --output text 2>/dev/null) != "$expected" ]]; then
        awsl iam get-user --user-name "$user" >/dev/null
        saved=$(aws configure get aws_access_key_id --profile "$profile" 2>/dev/null || true)
        if [[ -n $saved ]] && awsl iam list-access-keys --user-name "$user" --output json |
            jq -e --arg k "$saved" 'any(.AccessKeyMetadata[]; .AccessKeyId == $k)' >/dev/null; then
            die "Saved credentials exist but do not authenticate. Check profile $profile."
        fi
        echo "Creating local access for $user"
        key=$(awsl iam create-access-key --user-name "$user" --output json)
        [[ -n $(jq -r '.AccessKey.AccessKeyId // empty' <<<"$key") && -n $(jq -r '.AccessKey.SecretAccessKey // empty' <<<"$key") ]] ||
            die 'Floci returned incomplete credentials.'
        aws configure set aws_access_key_id "$(jq -r .AccessKey.AccessKeyId <<<"$key")" --profile "$profile"
        aws configure set aws_secret_access_key "$(jq -r .AccessKey.SecretAccessKey <<<"$key")" --profile "$profile"
        aws configure set region "$REGION" --profile "$profile"
        aws configure set endpoint_url "$ENDPOINT" --profile "$profile"
        [[ $(awsl sts get-caller-identity --profile "$profile" --query Arn --output text) == "$expected" ]] ||
            die 'Unexpected identity after configuring the AWS profile.'
    fi
    awsl eks update-kubeconfig --name "$cluster" --profile "$profile" --kubeconfig "$kubeconfig" \
        --alias "$profile" --user-alias "$profile" >/dev/null
    kubectl --kubeconfig "$kubeconfig" config set-credentials "$profile" \
        --exec-command=aws --exec-api-version=client.authentication.k8s.io/v1beta1 \
        --exec-arg=--region "--exec-arg=$REGION" --exec-arg=eks --exec-arg=get-token \
        --exec-arg=--cluster-name "--exec-arg=$cluster" --exec-arg=--profile "--exec-arg=$profile" \
        --exec-arg=--output --exec-arg=json >/dev/null
    wait_for "$stack authentication" 180 quiet kubectl --kubeconfig "$kubeconfig" --request-timeout=5s get --raw=/readyz
    kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready nodes --all --timeout=120s
    kubectl --kubeconfig "$kubeconfig" wait --for=condition=Available deployment/coredns -n kube-system --timeout=180s
    echo "$stack is ready. Kubeconfig: $kubeconfig"
}

# Prints only the Nexus readiness URL: Atmos captures stdout.
cmd_nexus_endpoint() {
    local stack=$1 config identity local_endpoint instances
    check_stack "$stack"
    # Do not resolve Terraform outputs while its after-apply hook is running.
    config=$(describe nexus "$stack" --process-functions=false)
    identity=$(jq -r '.vars.environment // empty' <<<"$config")
    [[ -n $identity ]] || die "Stack $stack has no environment identity."
    local args=(ec2 describe-instances --output json --no-cli-pager --region "$(jq -r .vars.region <<<"$config")"
        --filters "Name=tag:Name,Values=$identity-nexus" Name=tag:Role,Values=nexus Name=instance-state-name,Values=running)
    local_endpoint=$(jq -r '.vars.local_endpoint // empty' <<<"$config")
    if [[ -n $local_endpoint ]]; then
        args+=(--endpoint-url "$local_endpoint")
        export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
        unset AWS_PROFILE
    elif [[ -n $(jq -r '.env.AWS_PROFILE // empty' <<<"$config") ]]; then
        args+=(--profile "$(jq -r .env.AWS_PROFILE <<<"$config")")
    fi
    export AWS_EC2_METADATA_DISABLED=true
    instances=$(aws "${args[@]}" | jq -c '[.Reservations[].Instances[] | select(.InstanceId)]') ||
        die "Cannot find the Nexus instance for stack $stack."
    [[ $(jq length <<<"$instances") == 1 ]] ||
        die "Expected one running Nexus instance for $stack; found $(jq length <<<"$instances")."
    if [[ -n $local_endpoint ]]; then
        # Floci publishes container port 8081 on a dynamically assigned host port.
        local publisher port
        publisher="floci-aws-ec2-fwd-$(jq -r '.[0].InstanceId' <<<"$instances")-8081"
        port=$(docker port "$publisher" 8081/tcp 2>/dev/null | sed -nE 's/.*:([0-9]+)$/\1/p' | head -1) ||
            die "Nexus port publisher $publisher is not ready."
        [[ -n $port ]] || die "No published HTTP port was found for $publisher."
        echo "http://127.0.0.1:$port/service/rest/v1/status/writable"
    else
        local address
        address=$(jq -r '.[0] | .PublicIpAddress // .PrivateIpAddress // empty' <<<"$instances")
        [[ -n $address ]] || die 'The Nexus instance has no usable IP address.'
        echo "http://$address:8081/service/rest/v1/status/writable"
    fi
}

azure_certificate() {
    curl --noproxy '*' -fs --max-time 3 http://localhost:4577/_floci/tls-cert -o "$RUNTIME/floci-azure.crt" &&
        grep -q 'BEGIN CERTIFICATE' "$RUNTIME/floci-azure.crt"
}

cmd_start_azure() {
    docker compose -f local/compose.azure.yml up -d
    wait_for 'Floci Azure TLS certificate' 60 azure_certificate
    # Terraform's azurerm provider must trust the emulator CA (Debian/Ubuntu trust store).
    local sudo=; ((EUID == 0)) || sudo=sudo
    $sudo cp "$RUNTIME/floci-azure.crt" /usr/local/share/ca-certificates/floci-azure.crt
    $sudo update-ca-certificates >/dev/null
    echo 'Floci Azure is ready at https://localhost:4577; its CA is trusted.'
}

cmd_prepare_azure() {
    local stack=$1 config identity subscription credentials kubeconfig name port path="$RUNTIME/kubeconfig-$1.yaml"
    check_stack "$stack"
    config=$(describe argocd "$stack")
    [[ $(jq -r '.settings.local_azure_lab // false' <<<"$config") == true &&
        $(jq -r '.env.ARM_METADATA_HOSTNAME // empty' <<<"$config") == localhost:4577 ]] ||
        die 'This command requires the local Floci Azure stack.'
    identity=$(jq -r .vars.environment <<<"$config")
    subscription=$(jq -r .env.ARM_SUBSCRIPTION_ID <<<"$config")
    credentials=$(curl --noproxy '*' -fsS -X POST -H 'Content-Type: application/json' -d '{}' \
        "http://localhost:4577/subscriptions/$subscription/resourceGroups/$identity-rg/providers/Microsoft.ContainerService/managedClusters/$identity-aks/listClusterAdminCredential?api-version=2024-04-01")
    kubeconfig=$(jq -r '.kubeconfigs[0].value // empty' <<<"$credentials" | base64 -d)
    [[ -n $kubeconfig ]] || die 'Floci Azure returned no kubeconfig.'
    # Floci returns a Docker-only hostname. Use this cluster's published API port instead.
    name=$(sed -nE 's#^[[:space:]]*server:[[:space:]]*https://([a-zA-Z0-9-]+):6443[[:space:]]*$#\1#p' <<<"$kubeconfig" | head -1)
    [[ -n $name ]] || die 'Unexpected Floci Azure kubeconfig server.'
    [[ $(docker inspect -f '{{index .Config.Labels "io.floci.resource-id"}}' "$name") == "$identity-aks" ]] ||
        die 'Azure Kubernetes container belongs to another cluster.'
    port=$(docker inspect -f '{{with index .NetworkSettings.Ports "6443/tcp"}}{{(index . 0).HostPort}}{{end}}' "$name")
    [[ -n $port ]] || die 'Azure Kubernetes API has no published port.'
    printf '%s\n' "${kubeconfig//"https://$name:6443"/"https://localhost:$port"}" >"$path"
    kubectl --kubeconfig "$path" wait --for=condition=Ready nodes --all --timeout=180s
    kubectl --kubeconfig "$path" rollout status deployment/coredns -n kube-system --timeout=180s
    echo "$stack is ready. Kubeconfig: $path"
}

cmd_check() {
    local init=false render=false stack=customer1-aws-staging
    while (($#)); do
        case $1 in
            --init) init=true ;;
            --render) render=true ;;
            --stack) stack=$2; shift ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    atmos validate stacks
    terraform fmt -check -recursive components/terraform
    local module
    for module in $(find components/terraform -name versions.tf -not -path '*/.terraform/*' -exec dirname {} \;); do
        if $init; then terraform -chdir="$module" init -backend=false -input=false -no-color; fi
        terraform -chdir="$module" validate -no-color
        if $init && [[ -d $module/tests ]]; then terraform -chdir="$module" test -no-color; fi
    done
    bash -n local/lab.sh
    if $render; then
        local component
        for component in istio argocd kiali minio headlamp; do
            atmos helmfile template "$component" -s "$stack" --skip-deps >/dev/null
        done
    fi
    echo 'Configuration checks passed. No infrastructure changes were applied.'
}

case ${1:-} in
    start) cmd_start ;;
    stop) cmd_stop ;;
    prepare) cmd_prepare "${2:-}" ;;
    nexus-endpoint) cmd_nexus_endpoint "${2:-}" ;;
    start-azure) cmd_start_azure ;;
    prepare-azure) cmd_prepare_azure "${2:-}" ;;
    check) shift; cmd_check "$@" ;;
    *) cat >&2 <<'EOF'
Usage: local/lab.sh <command>
  start                  create the lab network, start Floci AWS and its UI, wait for health
  stop                   stop Floci AWS and its UI; data and customer resources are kept
  prepare STACK          after Kubernetes apply: repair the k3s node, configure AWS profile and kubeconfig
  nexus-endpoint STACK   print the Nexus readiness URL
  start-azure            start Floci Azure and trust its TLS CA
  prepare-azure STACK    write the kubeconfig for a local Floci Azure cluster
  check [--init] [--render] [--stack STACK]
                         validate stacks and Terraform; --init downloads providers, --render renders Helmfile
EOF
       exit 2 ;;
esac
