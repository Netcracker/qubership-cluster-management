#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$script:Local = Split-Path -Parent $PSScriptRoot
$script:Root = Split-Path -Parent $script:Local
$script:Compose = Join-Path $script:Local 'compose.yml'
$script:Runtime = Join-Path $script:Root '.local-runtime'
$script:Settings = Get-Content (Join-Path $script:Local 'settings.json') -Raw | ConvertFrom-Json
$script:NodesFile = Join-Path $script:Runtime 'nodes.json'

function Invoke-LabCommand {
    param([string]$Program, [string[]]$Arguments, [switch]$AllowFailure, [string[]]$InputLines)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($PSBoundParameters.ContainsKey('InputLines')) {
            # Linux resolv.conf must use LF: PowerShell's Windows native pipeline adds CRLF.
            $process = [Diagnostics.Process]::new()
            $process.StartInfo.FileName = $Program
            $process.StartInfo.UseShellExecute = $false
            $process.StartInfo.CreateNoWindow = $true
            $process.StartInfo.RedirectStandardInput = $true
            $process.StartInfo.RedirectStandardOutput = $true
            $process.StartInfo.RedirectStandardError = $true
            foreach ($argument in $Arguments) { $process.StartInfo.ArgumentList.Add($argument) }
            $process.Start() | Out-Null
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.Write(($InputLines -join "`n") + "`n")
            $process.StandardInput.Close()
            $process.WaitForExit()
            $lines = @($stdout.GetAwaiter().GetResult(), $stderr.GetAwaiter().GetResult())
            $code = $process.ExitCode
            $process.Dispose()
        } else {
            $lines = & $Program @Arguments 2>&1
            $code = $LASTEXITCODE
        }
    } finally { $ErrorActionPreference = $previousPreference }
    $output = (@($lines) | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0 -and -not $AllowFailure) { throw "$Program failed ($code): $output" }
    return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

function Initialize-Lab {
    param([string[]]$RequiredTools = @('docker', 'aws', 'kubectl', 'atmos'))
    foreach ($tool in $RequiredTools) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required tool is missing: $tool" }
    }
    $env:NO_PROXY = ((@($env:NO_PROXY -split ',') + @('localhost','127.0.0.1','::1','floci')) |
        Where-Object { $_ } | Select-Object -Unique) -join ','
    $env:AWS_ACCESS_KEY_ID = 'test'
    $env:AWS_SECRET_ACCESS_KEY = 'test'
    $env:AWS_PAGER = ''
    New-Item -ItemType Directory -Path $script:Runtime -Force | Out-Null
    Invoke-LabCommand docker @('info', '--format', '{{.ServerVersion}}') | Out-Null
}

function Invoke-LabAws {
    param([string[]]$Arguments, [switch]$AllowFailure)
    Invoke-LabCommand aws ($Arguments + @('--endpoint-url', $script:Settings.endpoint,
        '--region', $script:Settings.region, '--no-cli-pager')) -AllowFailure:$AllowFailure
}

function Get-LabContainer {
    param([string]$Name)
    $result = Invoke-LabCommand docker @('inspect', $Name) -AllowFailure
    if ($result.ExitCode -ne 0) { return $null }
    return @($result.Output | ConvertFrom-Json)[0]
}

function Get-LabEndpoint {
    param($Container)
    return $Container.NetworkSettings.Networks.PSObject.Properties[$script:Settings.network].Value
}

function Wait-Lab {
    param([scriptblock]$Condition, [string]$Description, [int]$Seconds = 180)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for $Description."
}

function Get-LabStack {
    param([string]$Stack)
    if ($Stack -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { throw "Invalid stack name: $Stack" }
    # Each concurrent caller gets its own data file; CLI messages are not JSON.
    $configFile = Join-Path ([IO.Path]::GetTempPath()) ("atmos-lab-" + [guid]::NewGuid() + '.json')
    try {
        $result = Invoke-LabCommand atmos @('describe', 'component', 'argocd', '-s', $Stack, '--format', 'json', '--file', $configFile)
        if (-not (Test-Path -LiteralPath $configFile)) { throw "Atmos did not write configuration for stack $Stack." }
        $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
        if ($null -eq $config) { throw "Atmos wrote an empty configuration for stack $Stack." }
    } finally {
        if (Test-Path -LiteralPath $configFile) { Remove-Item -LiteralPath $configFile -Force }
    }
    if (-not $config.settings.local_lab) { throw "Stack $Stack is not a local Floci stack." }
    if (-not $config.vars.environment) { throw "Stack $Stack does not define environment." }
    return [pscustomobject]@{
        Stack = $Stack
        Identity = [string]$config.vars.environment
        Cluster = "$($config.vars.environment)-eks"
        Container = "floci-aws-eks-$($config.vars.environment)-eks"
        Profile = "floci-$($config.vars.environment)"
        User = "$($config.vars.environment)-kubectl"
        Kubeconfig = Join-Path $script:Runtime "kubeconfig-$Stack.yaml"
    }
}

function Get-LabClusterPlan {
    param([string]$Stack)
    $plan = Get-LabStack $Stack
    $description = (Invoke-LabAws @('eks', 'describe-cluster', '--name', $plan.Cluster, '--output', 'json')).Output | ConvertFrom-Json
    $generation = ([DateTimeOffset]$description.cluster.createdAt).ToUniversalTime().ToString('o')
    Wait-Lab -Description "$($plan.Cluster) container" -Condition {
        $container = Get-LabContainer $plan.Container
        return ($null -ne $container -and $container.State.Status -in @('running','exited'))
    }
    $records = @{}
    if (Test-Path $script:NodesFile) { $records = Get-Content $script:NodesFile -Raw | ConvertFrom-Json -AsHashtable }
    $container = Get-LabContainer $plan.Container
    $network = Get-LabEndpoint $container
    $ip = $null
    if ($records.ContainsKey($Stack) -and $records[$Stack].generation -eq $generation) {
        $ip = $records[$Stack].ip
    } else {
        # The EC2 record preserves the node address even for a stopped k3s container.
        $instances = (Invoke-LabAws @('ec2','describe-instances','--filters',
            "Name=vpc-id,Values=$($description.cluster.resourcesVpcConfig.vpcId)",
            'Name=instance-state-name,Values=running',
            "Name=tag:eks:cluster-name,Values=$($plan.Cluster)",'--output','json')).Output | ConvertFrom-Json
        $nodeInstances = @($instances.Reservations.Instances | Where-Object { $_.PrivateIpAddress })
        if ($nodeInstances.Count -ne 1) { throw "Expected one local k3s node for $Stack; found $($nodeInstances.Count)." }
        $ip = $nodeInstances[0].PrivateIpAddress
        if (-not $ip) { $ip = $network.IPAddress }
    }
    if (-not $ip) { throw "Cannot determine the persisted node address for $Stack." }
    $records[$Stack] = @{ ip = $ip; generation = $generation }
    $records | ConvertTo-Json -Depth 5 | Set-Content $script:NodesFile -Encoding utf8
    $plan | Add-Member IP $ip
    return $plan
}

function Repair-LabNetworks {
    param([object[]]$Plans)
    $repairs = @($Plans | Where-Object {
        $network = Get-LabEndpoint (Get-LabContainer $_.Container)
        -not $network -or $network.IPAMConfig.IPv4Address -ne $_.IP
    })
    # Detach all affected endpoints first to handle swapped dynamic addresses.
    foreach ($plan in $repairs) {
        Write-Host "Restoring $($plan.Stack) node address $($plan.IP)"
        $container = Get-LabContainer $plan.Container
        if ($container.State.Running) { Invoke-LabCommand docker @('stop','--timeout','30',$plan.Container) | Out-Null }
        if (Get-LabEndpoint $container) {
            Invoke-LabCommand docker @('network','disconnect',$script:Settings.network,$plan.Container) | Out-Null
        }
    }
    foreach ($plan in $repairs) {
        Invoke-LabCommand docker @('network','connect','--ip',$plan.IP,$script:Settings.network,$plan.Container) | Out-Null
    }
}

function Repair-LabNode {
    param($Plan)
    $flociID = (Invoke-LabCommand docker @('compose','-f',$script:Compose,'ps','-q','floci')).Output.Trim()
    if (-not $flociID) { throw 'Floci is not running. Start the local lab first.' }
    $flociIP = (Get-LabEndpoint (Get-LabContainer $flociID)).IPAddress
    if (-not $flociIP) { throw 'Floci has no address on the lab network.' }
    $temporaryFile = [IO.Path]::GetTempFileName()
    try {
        Invoke-LabCommand docker @('cp',"$($Plan.Container):/etc/token-webhook.yaml",$temporaryFile) | Out-Null
        $before = [IO.File]::ReadAllText($temporaryFile)
        $after = $before -replace 'http://[^/\s]+:4566/', 'http://floci:4566/'
        if ($after -notmatch 'server:\s+http://floci:4566/') { throw 'Unexpected token-webhook format.' }
        if ($before -ne $after) {
            if ((Get-LabContainer $Plan.Container).State.Running) {
                Invoke-LabCommand docker @('stop','--timeout','30',$Plan.Container) | Out-Null
            }
            [IO.File]::WriteAllText($temporaryFile,$after,[Text.UTF8Encoding]::new($false))
            Invoke-LabCommand docker @('cp',$temporaryFile,"$($Plan.Container):/etc/token-webhook.yaml") | Out-Null
        }
    } finally { Remove-Item -LiteralPath $temporaryFile -ErrorAction SilentlyContinue }
    if (-not (Get-LabContainer $Plan.Container).State.Running) {
        Invoke-LabCommand docker @('start',$Plan.Container) | Out-Null
    }
    # Floci's synthetic VPC DNS is unreachable by containerd in this lab.
    $hosts = (Invoke-LabCommand docker @('exec',$Plan.Container,'cat','/etc/hosts')).Output -split '\r?\n'
    $hosts = @($hosts | Where-Object { $_ -and $_ -notmatch '(^|\s)floci(\s|$)' }) + "$flociIP floci"
    Invoke-LabCommand docker @('exec','-i',$Plan.Container,'tee','/etc/hosts') -InputLines $hosts | Out-Null
    $resolvers = @($script:Settings.dnsServers | ForEach-Object { "nameserver $_" })
    Invoke-LabCommand docker @('exec','-i',$Plan.Container,'tee','/etc/resolv.conf') -InputLines $resolvers | Out-Null
    Wait-Lab -Description "$($Plan.Stack) Kubernetes API" -Condition {
        (Invoke-LabCommand docker @('exec',$Plan.Container,'kubectl','--request-timeout=5s','get','--raw=/readyz') -AllowFailure).ExitCode -eq 0
    }
}

function Set-LabAccess {
    param($Plan, [switch]$CreateAccess)
    $expectedArn = "arn:aws:iam::000000000000:user/$($Plan.User)"
    $identity = Invoke-LabAws @('sts','get-caller-identity','--profile',$Plan.Profile,'--query','Arn','--output','text') -AllowFailure
    if ($identity.ExitCode -ne 0 -or $identity.Output.Trim() -ne $expectedArn) {
        if (-not $CreateAccess) { throw "Profile $($Plan.Profile) is unavailable. Run Prepare-Cluster.ps1 -Stack $($Plan.Stack)." }
        Invoke-LabAws @('iam','get-user','--user-name',$Plan.User) | Out-Null
        $savedKey = (Invoke-LabCommand aws @('configure','get','aws_access_key_id','--profile',$Plan.Profile) -AllowFailure).Output.Trim()
        $keys = (Invoke-LabAws @('iam','list-access-keys','--user-name',$Plan.User,'--output','json')).Output | ConvertFrom-Json
        if ($savedKey -and $savedKey -in @($keys.AccessKeyMetadata.AccessKeyId)) {
            throw "Saved credentials exist but do not authenticate. Check profile $($Plan.Profile)."
        }
        Write-Host "Creating local access for $($Plan.User)"
        $key = ((Invoke-LabAws @('iam','create-access-key','--user-name',$Plan.User,'--output','json')).Output | ConvertFrom-Json).AccessKey
        if (-not $key.AccessKeyId -or -not $key.SecretAccessKey) { throw 'Floci returned incomplete credentials.' }
        foreach ($setting in @{
            aws_access_key_id=$key.AccessKeyId; aws_secret_access_key=$key.SecretAccessKey
            region=$script:Settings.region; endpoint_url=$script:Settings.endpoint
        }.GetEnumerator()) {
            Invoke-LabCommand aws @('configure','set',$setting.Key,$setting.Value,'--profile',$Plan.Profile) | Out-Null
        }
        $identity = Invoke-LabAws @('sts','get-caller-identity','--profile',$Plan.Profile,'--query','Arn','--output','text')
        if ($identity.Output.Trim() -ne $expectedArn) { throw 'Unexpected identity after configuring the AWS profile.' }
    }
    Invoke-LabAws @('eks','update-kubeconfig','--name',$Plan.Cluster,'--profile',$Plan.Profile,
        '--kubeconfig',$Plan.Kubeconfig,'--alias',$Plan.Profile,'--user-alias',$Plan.Profile) | Out-Null
    Invoke-LabCommand kubectl @('--kubeconfig',$Plan.Kubeconfig,'config','set-credentials',$Plan.Profile,
        '--exec-command=aws','--exec-api-version=client.authentication.k8s.io/v1beta1',
        '--exec-arg=--region',"--exec-arg=$($script:Settings.region)",
        '--exec-arg=eks','--exec-arg=get-token','--exec-arg=--cluster-name',"--exec-arg=$($Plan.Cluster)",
        '--exec-arg=--profile',"--exec-arg=$($Plan.Profile)",'--exec-arg=--output','--exec-arg=json') | Out-Null
    Wait-Lab -Description "$($Plan.Stack) authentication" -Condition {
        (Invoke-LabCommand kubectl @('--kubeconfig',$Plan.Kubeconfig,'--request-timeout=5s','get','--raw=/readyz') -AllowFailure).ExitCode -eq 0
    }
    foreach ($arguments in @(
        @('wait','--for=condition=Ready','nodes','--all','--timeout=120s'),
        @('wait','--for=condition=Available','deployment/coredns','-n','kube-system','--timeout=180s')
    )) {
        Write-Host (Invoke-LabCommand kubectl (@('--kubeconfig',$Plan.Kubeconfig) + $arguments)).Output
    }
    Write-Host "$($Plan.Stack) is ready. Kubeconfig: $($Plan.Kubeconfig)"
}

function Get-ExistingLabStacks {
    $clusters = @(((Invoke-LabAws @('eks','list-clusters','--output','json')).Output | ConvertFrom-Json).clusters)
    $stacks = @((Invoke-LabCommand atmos @('list','stacks','--format','json')).Output | ConvertFrom-Json)
    foreach ($entry in $stacks) {
        $description = Invoke-LabCommand atmos @('describe', 'component', 'argocd', '-s', $entry.Stack, '--process-functions=false', '--format', 'json')
        if (-not ($description.Output | ConvertFrom-Json).settings.local_lab) { continue }
        $stack = Get-LabStack $entry.Stack
        if ($stack.Cluster -in $clusters) { $stack.Stack }
    }
}

function Start-LabNexus {
    $instances = (Invoke-LabAws @('ec2','describe-instances','--filters',
        'Name=tag:Role,Values=nexus','Name=tag:ManagedBy,Values=terraform',
        'Name=instance-state-name,Values=running,stopped','--output','json')).Output | ConvertFrom-Json
    foreach ($instance in @($instances.Reservations.Instances)) {
        if (-not $instance.InstanceId) { continue }
        $name = "floci-aws-ec2-$($instance.InstanceId)"
        $container = Get-LabContainer $name
        if (-not $container) { throw "Nexus container $name is missing." }
        Write-Host "Starting Nexus on $($instance.InstanceId)"
        if (-not $container.State.Running) {
            Invoke-LabCommand docker @('start',$name) | Out-Null
        }
        # Starting the EC2 container alone does not start the Nexus Java process.
        Invoke-LabCommand docker @('exec',$name,'bash','-lc',
            'runuser -u nexus -- /opt/nexus/bin/nexus status >/dev/null 2>&1 || runuser -u nexus -- /opt/nexus/bin/nexus start') | Out-Null
        $forward = "floci-aws-ec2-fwd-$($instance.InstanceId)-8081"
        $publisher = Get-LabContainer $forward
        if (-not $publisher) { throw "Nexus port publisher $forward is missing. Check the EC2 ingress rule for port 8081." }
        if (-not $publisher.State.Running) {
            Invoke-LabCommand docker @('start',$forward) | Out-Null
        }
        Wait-Lab -Description "$name HTTP readiness on port 8081" -Seconds 300 -Condition {
            $response = Invoke-LabCommand docker @('exec',$name,'curl','--noproxy','*',
                '--max-time','5','-s','-o','/dev/null','-w','%{http_code}','http://127.0.0.1:8081/') -AllowFailure
            $response.ExitCode -eq 0 -and $response.Output.Trim() -eq '200'
        }
        Write-Host "Nexus is ready. Published port: $((Invoke-LabCommand docker @('port',$forward,'8081/tcp')).Output)"
    }
}

function Start-Lab {
    Initialize-Lab -RequiredTools @('docker')
    if ((Invoke-LabCommand docker @('network','inspect',$script:Settings.network) -AllowFailure).ExitCode -ne 0) {
        Invoke-LabCommand docker @('network','create','--subnet',$script:Settings.subnet,'--gateway',
            $script:Settings.gateway,$script:Settings.network) | Out-Null
    }
    Write-Host 'Starting Floci and its console'
    Write-Host (Invoke-LabCommand docker @('compose','-f',$script:Compose,'up','-d')).Output
    Wait-Lab -Description 'Floci health' -Condition {
        $id = (Invoke-LabCommand docker @('compose','-f',$script:Compose,'ps','-q','floci')).Output.Trim()
        $container = if ($id) { Get-LabContainer $id }
        $container -and $container.State.Health.Status -eq 'healthy'
    }
    Write-Host 'Local environment started (Floci and UI). Console: http://127.0.0.1:4500'
}

function Stop-Lab {
    Initialize-Lab -RequiredTools @('docker')
    # Customer resources must be destroyed separately before stopping the emulator.
    Write-Host (Invoke-LabCommand docker @('compose','-f',$script:Compose,'stop','--timeout','60','floci')).Output
    Write-Host (Invoke-LabCommand docker @('compose','-f',$script:Compose,'stop','--timeout','10','ui')).Output
    Write-Host 'Local environment stopped (Floci and UI). State and data retained.'
}

function Prepare-LabCluster {
    param([Parameter(Mandatory)][string]$Stack)
    Initialize-Lab
    $plan = Get-LabClusterPlan $Stack
    Repair-LabNetworks @($plan)
    Repair-LabNode $plan
    Set-LabAccess $plan -CreateAccess
}

Export-ModuleMember -Function Start-Lab, Stop-Lab, Prepare-LabCluster
