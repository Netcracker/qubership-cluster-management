#!/usr/bin/env bash
# Operator helpers: the local Floci laboratory and the VM installation (secrets, SSH through the jump host,
# Nexus, kubeconfig; see docs/vm-installation.md). Run `local/lab.sh` without arguments for usage.
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

# --- VM installation: docs/vm-installation.md -------------------------------------------------------------

# The operator key in local/age.key, unless SOPS_AGE_KEY, SOPS_AGE_KEY_CMD or SOPS_AGE_KEY_FILE picks another source.
default_age_key() {
    [[ -n ${SOPS_AGE_KEY:-}${SOPS_AGE_KEY_CMD:-}${SOPS_AGE_KEY_FILE:-} || ! -f local/age.key ]] ||
        export SOPS_AGE_KEY_FILE=$PWD/local/age.key
}

cmd_secrets_init() {
    local stack=$1 file tmp; check_stack "$stack"
    file=secrets/$stack.yaml tmp=$(mktemp -d)
    [[ ! -e $file ]] || die "$file exists; edit it with: sops $file"
    default_age_key
    ssh-keygen -q -t ed25519 -N '' -C "$stack" -f "$tmp/id"
    {
        echo "TF_VAR_ssh_public_key: $(cat "$tmp/id.pub")"
        echo 'TF_VAR_ssh_private_key: |'; sed 's/^/  /' "$tmp/id"
        echo "NEXUS_ADMIN_PASSWORD: $(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    } | sops encrypt --filename-override "$file" --input-type yaml --output-type yaml /dev/stdin >"$tmp/out" &&
        mv "$tmp/out" "$file"
    rm -rf "$tmp"
    [[ -f $file ]] || die "Encryption failed; check the keys in .sops.yaml."
    echo "Created $file. Add cloud credentials (environment variables) with: sops $file"
}

# Runs a command with the stack's decrypted secrets as environment variables; nothing is written to disk.
cmd_with_secrets() {
    local stack=$1; shift; check_stack "$stack"
    [[ -f secrets/$stack.yaml ]] || die "No secrets/$stack.yaml; run local/lab.sh secrets-init $stack."
    (($#)) || die 'Usage: local/lab.sh with-secrets STACK COMMAND...'
    default_age_key
    exec sops exec-env "secrets/$stack.yaml" "$(printf '%q ' "$@")"
}

# Jump host, Nexus, nodes and tunnel port from the kubemarine component; "(computed)" = not applied yet.
vm_context() {
    local config; config=$(describe kubemarine "$1")
    JUMP=$(jq -r '(.vars.jump_host | objects | .address) // empty' <<<"$config")
    NEXUS=$(jq -r '.vars.nexus_address | select(. != "(computed)") // empty' <<<"$config")
    NODES=$(jq -c '.vars.nodes | arrays' <<<"$config")
    PORT=$(jq -r '.settings.tunnel_port // 1080' <<<"$config")
    SSH_USER=$(jq -r '.vars.ssh_user // "ubuntu"' <<<"$config")
    [[ -n $JUMP ]] || die "Stack $1 has no jump host yet: apply jump-host first."
}

# The private key from the secrets (with-secrets) as a file for this run only.
ssh_setup() {
    [[ -n ${TF_VAR_ssh_private_key:-} ]] || die "No SSH key: run as local/lab.sh with-secrets $1 local/lab.sh ..."
    KEY=$RUNTIME/ssh-$$.key
    (umask 077 && printf '%s\n' "$TF_VAR_ssh_private_key" >"$KEY")
    trap 'rm -f "$KEY"' EXIT
    SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
        -o "UserKnownHostsFile=$RUNTIME/known_hosts-$1")
}
on_jump() { ssh "${SSH_OPTS[@]}" "$SSH_USER@$JUMP" "$@"; }
through_jump() { # private address, command...
    ssh "${SSH_OPTS[@]}" -o "ProxyCommand=ssh ${SSH_OPTS[*]} -W %h:%p $SSH_USER@$JUMP" "$SSH_USER@$1" "${@:2}"
}
# Unix sockets are limited to 108 chars and ssh appends 17 while binding: a checkout path would not fit.
tunnel_sock() { echo "/tmp/qcm-tunnel-$1.sock"; }
tunnel_running() { ssh -S "$(tunnel_sock "$1")" -O check tunnel 2>/dev/null; }
# curl reads only the lowercase http_proxy; Go tools read either.
proxy_env() {
    export http_proxy=socks5://127.0.0.1:$PORT
    export HTTP_PROXY=$http_proxy HTTPS_PROXY=$http_proxy https_proxy=$http_proxy
}

cmd_tunnel() {
    local stack=$1; check_stack "$stack"
    if [[ ${2:-} == stop ]]; then
        ssh -S "$(tunnel_sock "$stack")" -O exit tunnel 2>/dev/null || true
        echo "Tunnel for $stack stopped."; return
    fi
    vm_context "$stack"; ssh_setup "$stack"
    tunnel_running "$stack" && { echo "Tunnel for $stack is already running on 127.0.0.1:$PORT."; return; }
    wait_for "SSH on the jump host $JUMP" 300 quiet on_jump true
    ssh "${SSH_OPTS[@]}" -f -N -M -S "$(tunnel_sock "$stack")" -D "127.0.0.1:$PORT" \
        -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 "$SSH_USER@$JUMP"
    echo "SOCKS proxy socks5://127.0.0.1:$PORT into the $stack network (stop: local/lab.sh tunnel $stack stop)."
}

cmd_nexus_install() {
    local stack=$1 bundle=${BUNDLE_DIR:-$RUNTIME/bundle}; check_stack "$stack"
    vm_context "$stack"; ssh_setup "$stack"
    [[ -n $NEXUS ]] || die "Stack $stack has no Nexus VM yet: apply nexus first."
    [[ -f $bundle/nexus.tar.gz ]] || die "No bundle in $bundle; run bundle/build.sh."
    wait_for "SSH on Nexus $NEXUS" 300 quiet through_jump "$NEXUS" true
    echo "Copying Nexus to $NEXUS through $JUMP"
    through_jump "$NEXUS" 'cat >/tmp/nexus.tar.gz' <"$bundle/nexus.tar.gz"
    through_jump "$NEXUS" sudo bash -s <bundle/nexus-install.sh
    echo "Nexus is starting on $NEXUS; nexus-load waits for it."
}

cmd_nexus_load() {
    local stack=$1; check_stack "$stack"
    vm_context "$stack"
    [[ -n $NEXUS ]] || die "Stack $stack has no Nexus VM yet: apply nexus first."
    tunnel_running "$stack" || die "Start the tunnel first: local/lab.sh with-secrets $stack local/lab.sh tunnel $stack"
    proxy_env
    NEXUS_URL=http://$NEXUS:8081 bash bundle/load.sh
}

# A shell or a command on a private VM (Nexus, a node) through the jump host.
cmd_ssh() {
    local stack=$1 host=${2:-}; check_stack "$stack"
    [[ -n $host ]] || die 'Usage: local/lab.sh ssh STACK PRIVATE_ADDRESS [COMMAND...]'
    vm_context "$stack"; ssh_setup "$stack"
    through_jump "$host" "${@:3}"
}

# After kubemarine apply: kubeconfig from the first control-plane, reaching the API through the tunnel.
cmd_prepare_vms() {
    local stack=$1 cp kubeconfig; check_stack "$stack"
    vm_context "$stack"; ssh_setup "$stack"
    cp=$(jq -r '[.[] | select(.roles | index("control-plane"))][0].internal_address // empty' <<<"${NODES:-[]}")
    [[ -n $cp ]] || die "Stack $stack has no control-plane node yet: apply vms first."
    tunnel_running "$stack" || die "Start the tunnel first: local/lab.sh with-secrets $stack local/lab.sh tunnel $stack"
    kubeconfig=$RUNTIME/kubeconfig-$stack.yaml
    through_jump "$cp" sudo cat /etc/kubernetes/admin.conf >"$kubeconfig.tmp"
    yq -i ".clusters[0].cluster.server = \"https://$cp:6443\" |
        .clusters[0].cluster.\"proxy-url\" = \"socks5://127.0.0.1:$PORT\"" "$kubeconfig.tmp"
    chmod 600 "$kubeconfig.tmp" && mv "$kubeconfig.tmp" "$kubeconfig"
    kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready nodes --all --timeout=300s
    echo "$stack is ready. Kubeconfig: $kubeconfig"
}

# --- Run logs: one archive per run, collected on success and on failure --------------------------------------

# Runs COMMAND with the stack secrets (when secrets/STACK.yaml exists), then collects logs into
# .local-runtime/logs/STACK-<UTC time>-<ok|failed>.tar.gz and uploads it when LOGS_UPLOAD_URL is set.
cmd_run() {
    local stack=$1; shift; check_stack "$stack"
    (($#)) || die 'Usage: local/lab.sh run STACK COMMAND...'
    if [[ -f secrets/$stack.yaml && -z ${QCM_SECRETS_LOADED:-} ]]; then
        default_age_key
        exec sops exec-env "secrets/$stack.yaml" "QCM_SECRETS_LOADED=1 bash ./local/lab.sh run $(printf '%q ' "$stack" "$@")"
    fi
    local started name dir code status
    started=$(date -u +%Y%m%d-%H%M%S)
    dir=$RUNTIME/logs/$stack-$started
    mkdir -p "$dir/run"
    printf '%q ' "$@" >"$dir/run/command.txt"
    # Ctrl-C stops the command, not the log collection.
    trap 'echo "Interrupted: collecting logs" >&2' INT
    set +e
    "$@" 2>&1 | tee "$dir/run/console.log"
    code=${PIPESTATUS[0]}
    set -e
    trap - INT
    ((code == 0)) && status=ok || status=failed
    echo "Collecting logs ($status, exit code $code)"
    collect_logs "$stack" "$dir" "$code" "$started"
    name=$stack-$started-$status
    mv "$dir" "$RUNTIME/logs/$name"
    tar -czf "$RUNTIME/logs/$name.tar.gz" -C "$RUNTIME/logs" "$name"
    echo "Logs: .local-runtime/logs/$name.tar.gz"
    upload_logs "$RUNTIME/logs/$name.tar.gz" || echo "Log upload failed; the archive stays local." >&2
    return "$code"
}

collect_logs() { # stack dir exit-code started
    local stack=$1 dir=$2 code=$3 kubeconfig=$RUNTIME/kubeconfig-$1.yaml installer=$RUNTIME/kubemarine/$1
    local commit; commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
    git diff --quiet HEAD 2>/dev/null || commit="$commit (with local changes)"
    cat >"$dir/run/summary.txt" <<EOF
stack:     $stack
command:   $(cat "$dir/run/command.txt")
exit code: $code
started:   $4 UTC
finished:  $(date -u +%Y%m%d-%H%M%S) UTC
commit:    $commit
EOF
    # Each part is optional: what cannot be reached is noted in run/collect.log and skipped.
    part() { # name command...
        echo "== $1" >>"$dir/run/collect.log"
        ("${@:2}") >>"$dir/run/collect.log" 2>&1 || echo "$1: not collected" >>"$dir/run/collect.log"
    }
    config_part() { mkdir -p "$dir/config"; atmos describe stacks -s "$stack" >"$dir/config/stack.yaml"; }
    # Kubemarine inventory and dump (debug.log, finalized inventory); key files and kubeconfigs are left out.
    installer_part() {
        [[ -d $installer ]] || { echo "no $installer"; return 1; }
        mkdir -p "$dir/kubemarine"
        tar -C "$installer" --exclude='id_*' --exclude='*.key' --exclude='admin.conf' --exclude='kubeconfig*' -cf - . |
            tar -C "$dir/kubemarine" -xf -
    }
    # Cluster state, events and container logs, one folder per namespace; needs the API (tunnel for VM stacks).
    kubernetes_part() {
        [[ -f $kubeconfig ]] || { echo "no $kubeconfig"; return 1; }
        kubectl --kubeconfig "$kubeconfig" --request-timeout=10s get --raw=/readyz >/dev/null
        mkdir -p "$dir/kubernetes"
        kubectl --kubeconfig "$kubeconfig" get nodes,pods -A -o wide >"$dir/kubernetes/overview.txt" 2>&1 || true
        kubectl --kubeconfig "$kubeconfig" cluster-info dump --all-namespaces --output-directory="$dir/kubernetes/dump" >/dev/null
    }
    # VM stacks while the jump host exists (after a failure it usually does): Nexus and node service logs.
    vms_part() {
        vm_context "$stack"; ssh_setup "$stack"
        if [[ -n $NEXUS ]]; then
            mkdir -p "$dir/nexus"
            through_jump "$NEXUS" 'sudo systemctl status nexus --no-pager; sudo tail -n 5000 /opt/sonatype-work/nexus3/log/nexus.log' \
                >"$dir/nexus/nexus.log" 2>&1 || true
        fi
        local name address
        jq -r '.[] | .name + " " + .internal_address' <<<"${NODES:-[]}" | while read -r name address; do
            mkdir -p "$dir/nodes"
            through_jump "$address" 'sudo journalctl -u containerd -u kubelet --no-pager -n 3000' \
                >"$dir/nodes/$name.log" 2>&1 </dev/null || true
        done
    }
    part config config_part
    part kubemarine installer_part
    part kubernetes kubernetes_part
    part vms vms_part
}

# LOGS_UPLOAD_URL picks the storage by its form (put it in secrets/STACK.yaml or a CI variable):
#   s3://bucket/prefix                                       AWS S3 (or S3-compatible with AWS_ENDPOINT_URL_S3)
#   https://ACCOUNT.blob.core.windows.net/CONTAINER/prefix?SAS  Azure Blob Storage, container SAS with write rights
#   gs://bucket/prefix                                       Google Cloud Storage through its S3-compatible API,
#                                                            HMAC key in LOGS_GCS_HMAC_ACCESS_ID / LOGS_GCS_HMAC_SECRET
upload_logs() {
    local file=$1 url=${LOGS_UPLOAD_URL:-} name; name=$(basename "$1")
    [[ -n $url ]] || return 0
    url=${url%/}
    case $url in
        s3://*) aws s3 cp --no-progress "$file" "$url/$name" >/dev/null ;;
        gs://*)
            [[ -n ${LOGS_GCS_HMAC_ACCESS_ID:-} && -n ${LOGS_GCS_HMAC_SECRET:-} ]] ||
                { echo 'gs:// needs LOGS_GCS_HMAC_ACCESS_ID and LOGS_GCS_HMAC_SECRET' >&2; return 1; }
            # GCS rejects the checksum trailers that recent AWS CLI versions send by default.
            env -u AWS_SESSION_TOKEN -u AWS_PROFILE \
                AWS_ACCESS_KEY_ID="$LOGS_GCS_HMAC_ACCESS_ID" AWS_SECRET_ACCESS_KEY="$LOGS_GCS_HMAC_SECRET" \
                AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
                aws s3 cp --no-progress --endpoint-url https://storage.googleapis.com --region auto \
                "$file" "s3://${url#gs://}/$name" >/dev/null ;;
        https://*.blob.core.windows.net/*\?*)
            curl -fsS -X PUT -H 'x-ms-blob-type: BlockBlob' -T "$file" "${url%%\?*}/$name?${url#*\?}" >/dev/null ;;
        *) echo 'Unsupported LOGS_UPLOAD_URL: s3://..., gs://..., or an Azure Blob container URL with SAS' >&2; return 1 ;;
    esac || return
    echo "Logs uploaded: ${url%%\?*}/$name"
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
    secrets-init) cmd_secrets_init "${2:-}" ;;
    with-secrets) shift; cmd_with_secrets "$@" ;;
    tunnel) cmd_tunnel "${2:-}" "${3:-}" ;;
    nexus-install) cmd_nexus_install "${2:-}" ;;
    nexus-load) cmd_nexus_load "${2:-}" ;;
    prepare-vms) cmd_prepare_vms "${2:-}" ;;
    ssh) shift; cmd_ssh "$@" ;;
    run) shift; cmd_run "$@" ;;
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
VM installation (docs/vm-installation.md); SSH commands run as: local/lab.sh with-secrets STACK local/lab.sh ...
  secrets-init STACK     create secrets/STACK.yaml (SSH key, Nexus password) encrypted for the keys in .sops.yaml
  with-secrets STACK CMD run CMD with the decrypted secrets as environment variables
  tunnel STACK [stop]    SOCKS proxy through the jump host into the private network
  nexus-install STACK    copy Nexus from the bundle to its VM through the jump host and start it
  nexus-load STACK       create the Nexus repositories and upload the bundle (through the tunnel)
  prepare-vms STACK      after kubemarine: kubeconfig from the control plane, API through the tunnel
  ssh STACK ADDRESS [CMD] shell or command on a private VM through the jump host
  run STACK CMD          run CMD (with secrets, if the stack has them), collect logs into one archive on success
                         or failure: .local-runtime/logs/STACK-<time>-<ok|failed>.tar.gz; LOGS_UPLOAD_URL uploads it
EOF
       exit 2 ;;
esac
