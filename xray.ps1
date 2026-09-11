[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [int]$Index,

    [string]$SubscriptionUrl,

    [switch]$NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$XrayPath = Join-Path $Root 'xray.exe'
$ConfigDir = Join-Path $Root 'config'
$ConfigPath = Join-Path $ConfigDir 'config.json'
$NodesPath = Join-Path $ConfigDir 'nodes.json'
$DataDir = Join-Path $Root 'data'
$PidPath = Join-Path $DataDir 'xray.pid'
$SubscriptionPath = Join-Path $DataDir 'subscription.txt'
$LogDir = Join-Path $Root 'logs'
$LogPath = Join-Path $LogDir 'xray.log'

function Initialize-Directories {
    foreach ($path in @($ConfigDir, $DataDir, $LogDir)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Write-Log([string]$Message) {
    Initialize-Directories
    Add-Content -LiteralPath $LogPath -Value "[$(Get-Date -Format s)] $Message" -Encoding UTF8
}

function Read-Nodes {
    if (-not (Test-Path -LiteralPath $NodesPath)) { return @() }
    $raw = Get-Content -LiteralPath $NodesPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $value = $raw | ConvertFrom-Json
    if ($value -is [System.Array]) { return @($value) }
    return @($value)
}

function Save-Nodes($Nodes) {
    Initialize-Directories
    @($Nodes) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $NodesPath -Encoding UTF8
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    return (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-Config($Config) {
    Initialize-Directories
    $Config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Get-XrayProcess {
    if (-not (Test-Path -LiteralPath $PidPath)) { return $null }
    try { $pid = [int](Get-Content -LiteralPath $PidPath -Raw) } catch { return $null }
    $process = Get-Process -Id $pid -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $process
}

function Test-TcpPort([string]$Host, [int]$Port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($Host, $Port)
        if (-not $task.Wait(500)) { return $false }
        return $client.Connected
    } catch { return $false } finally { $client.Dispose() }
}

function Test-Config {
    if (-not (Test-Path -LiteralPath $XrayPath)) { throw "xray.exe not found: $XrayPath" }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "config.json not found: $ConfigPath" }
    & $XrayPath run -test -c $ConfigPath 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "Xray configuration validation failed (exit code $LASTEXITCODE)." }
}

function Start-Xray {
    if (Get-XrayProcess) { Write-Host 'Xray is already running.'; return }
    Test-Config
    if (Test-TcpPort '127.0.0.1' 10808) { throw 'SOCKS5 port 10808 is already in use.' }
    if (Test-TcpPort '127.0.0.1' 10809) { throw 'HTTP port 10809 is already in use.' }

    Initialize-Directories
    $process = Start-Process -FilePath $XrayPath -ArgumentList @('run','-c',$ConfigPath) -WorkingDirectory $Root -RedirectStandardOutput $LogPath -RedirectStandardError $LogPath -PassThru
    Set-Content -LiteralPath $PidPath -Value $process.Id -Encoding ASCII
    Write-Log "Started Xray PID=$($process.Id)"
    Write-Host "Xray started. PID: $($process.Id)"
}

function Stop-Xray {
    $process = Get-XrayProcess
    if ($null -eq $process) { Write-Host 'Xray is not running.'; return }
    Stop-Process -Id $process.Id -Force
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    Write-Log "Stopped Xray PID=$($process.Id)"
    Write-Host 'Xray stopped.'
}

function Restart-Xray { Stop-Xray; Start-Sleep -Milliseconds 300; Start-Xray }

function Show-Status {
    $process = Get-XrayProcess
    $nodes = Read-Nodes
    $config = Read-Config
    $active = $nodes | Where-Object { $_.active -eq $true } | Select-Object -First 1
    if ($null -eq $process) { Write-Host 'Xray: Stopped' } else { Write-Host "Xray: Running`nPID: $($process.Id)" }
    if ($active) { Write-Host "Node: $($active.name)" }
    Write-Host 'SOCKS5: 127.0.0.1:10808'
    Write-Host 'HTTP:   127.0.0.1:10809'
}

function ConvertTo-Base64Text([string]$Text) {
    $s = ($Text.Trim() -replace '\s+', '') -replace '-', '+' -replace '_', '/'
    switch ($s.Length % 4) { 2 { $s += '==' }; 3 { $s += '=' } }
    try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) } catch { return $null }
}

function Parse-Query([string]$Query) {
    $result = @{}
    foreach ($pair in ($Query -split '&')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $parts = $pair -split '=', 2
        $key = [Uri]::UnescapeDataString($parts[0])
        $value = if ($parts.Count -eq 2) { [Uri]::UnescapeDataString($parts[1]) } else { '' }
        $result[$key] = $value
    }
    return $result
}

function New-NodeFromUri([string]$UriText, [int]$Id) {
    $scheme = $UriText.Split(':',2)[0].ToLowerInvariant()
    try { $uri = [Uri]$UriText } catch { return $null }
    $query = Parse-Query $uri.Query.TrimStart('?')
    $name = if ($uri.Fragment) { [Uri]::UnescapeDataString($uri.Fragment.TrimStart('#')) } else { "Node-$Id" }
    $node = [ordered]@{ id=$Id; name=$name; protocol=$scheme; address=$uri.Host; port=$uri.Port }

    switch ($scheme) {
        'vless' {
            $node.uuid = [Uri]::UnescapeDataString($uri.UserInfo)
            foreach ($key in @('type','security','sni','fp','pbk','sid','flow','path','mode','alpn','host')) { if ($query.ContainsKey($key)) { $node[$key] = $query[$key] } }
        }
        'trojan' {
            $node.password = [Uri]::UnescapeDataString($uri.UserInfo)
            foreach ($key in @('type','security','sni','fp','path','mode','alpn','host')) { if ($query.ContainsKey($key)) { $node[$key] = $query[$key] } }
        }
        'vmess' { return $null }
        'ss' { return $null }
        default { return $null }
    }
    return [pscustomobject]$node
}

function Parse-Subscription([string]$Content) {
    $text = $Content.Trim()
    $decoded = ConvertTo-Base64Text $text
    if ($decoded -and $decoded -match '(?im)^(vless|vmess|trojan|ss)://') { $text = $decoded }
    $nodes = @(); $id = 1
    foreach ($line in ($text -split "`r?`n")) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        if ($line -match '^vless://|^trojan://') {
            $node = New-NodeFromUri $line $id
            if ($node) { $nodes += $node; $id++ }
            continue
        }
        if ($line -match '^vmess://') {
            $json = ConvertTo-Base64Text ($line.Substring(8))
            if ($json) {
                try {
                    $v = $json | ConvertFrom-Json
                    $nodes += [pscustomobject][ordered]@{ id=$id; name=$(if ($v.pscustomObject.psobject.Properties.Name -contains 'ps') {$v.ps} else {"Node-$id"}); protocol='vmess'; address=$v.add; port=[int]$v.port; uuid=$v.id; security=$(if ($v.aid) {'auto'} else {'auto'}); network=$v.net; tls=$v.tls; serverName=$v.sni; path=$v.path; host=$v.host }
                    $id++
                } catch { Write-Log "Failed to parse VMess node: $line" }
            }
            continue
        }
    }
    return @($nodes)
}

function Update-Subscription {
    if ([string]::IsNullOrWhiteSpace($SubscriptionUrl)) { throw 'Specify -SubscriptionUrl when updating, or configure it in data/subscription-url.txt.' }
    Initialize-Directories
    Write-Host 'Updating subscription...'
    $response = Invoke-WebRequest -Uri $SubscriptionUrl -Headers @{ 'User-Agent'='Mozilla/5.0 xray-powershell' } -UseBasicParsing
    $content = [string]$response.Content
    Set-Content -LiteralPath $SubscriptionPath -Value $content -Encoding UTF8
    $nodes = Parse-Subscription $content
    Save-Nodes $nodes
    Write-Host "Parsed $($nodes.Count) nodes."
}

function Show-Nodes {
    $nodes = Read-Nodes
    if ($nodes.Count -eq 0) { Write-Host 'No nodes. Run update first.'; return }
    $nodes | Select-Object id,name,protocol,address,port | Format-Table -AutoSize
}

function New-XrayOutbound($Node) {
    switch ($Node.protocol) {
        'vless' {
            $stream = [ordered]@{ network=$(if ($Node.type) {$Node.type} else {'tcp'}); security=$(if ($Node.security) {$Node.security} else {'none'}) }
            if ($Node.security -eq 'tls') { $stream.tlsSettings = [ordered]@{ serverName=$Node.sni; fingerprint=$Node.fp } }
            if ($Node.security -eq 'reality') { $stream.realitySettings = [ordered]@{ serverName=$Node.sni; fingerprint=$(if($Node.fp){$Node.fp}else{'chrome'}); publicKey=$Node.pbk; shortId=$Node.sid } }
            $settings = [ordered]@{ vnext=@([ordered]@{ address=$Node.address; port=[int]$Node.port; users=@([ordered]@{ id=$Node.uuid; encryption='none'; flow=$(if($Node.flow){$Node.flow}else{''}) }) }) }
            return [ordered]@{ protocol='vless'; settings=$settings; streamSettings=$stream }
        }
        'trojan' {
            return [ordered]@{ protocol='trojan'; settings=[ordered]@{ servers=@([ordered]@{ address=$Node.address; port=[int]$Node.port; password=$Node.password }) }; streamSettings=[ordered]@{ network=$(if($Node.type){$Node.type}else{'tcp'}); security=$(if($Node.security){$Node.security}else{'tls'}); tlsSettings=[ordered]@{ serverName=$Node.sni } } }
        }
        default { throw "Unsupported protocol: $($Node.protocol)" }
    }
}

function Write-ConfigForNode($Node) {
    $config = [ordered]@{
        log=[ordered]@{ loglevel='warning'; access='logs/access.log'; error='logs/error.log' }
        inbounds=@(
            [ordered]@{ tag='socks-in'; listen='127.0.0.1'; port=10808; protocol='socks'; settings=[ordered]@{ udp=$true } },
            [ordered]@{ tag='http-in'; listen='127.0.0.1'; port=10809; protocol='http'; settings=[ordered]@{} }
        )
        outbounds=@( (New-XrayOutbound $Node), [ordered]@{ protocol='freedom'; tag='direct' } )
        routing=[ordered]@{ domainStrategy='AsIs'; rules=@() }
    }
    Save-Config $config
}

function Select-Node([int]$NodeId) {
    $nodes = Read-Nodes
    $node = $nodes | Where-Object { [int]$_.id -eq $NodeId } | Select-Object -First 1
    if ($null -eq $node) { throw "Node $NodeId not found." }
    foreach ($n in $nodes) { $n.active = ([int]$n.id -eq $NodeId) }
    Save-Nodes $nodes
    Write-ConfigForNode $node
    Write-Host "Selected: $($node.name)"
    if (-not $NoStart) { Restart-Xray }
}

function Show-Current {
    $node = Read-Nodes | Where-Object { $_.active -eq $true } | Select-Object -First 1
    if ($node) { $node | Format-List } else { Write-Host 'No active node.' }
}

function Test-Node([int]$NodeId) {
    $nodes = Read-Nodes
    $node = $nodes | Where-Object { [int]$_.id -eq $NodeId } | Select-Object -First 1
    if (-not $node) { throw "Node $NodeId not found." }
    if (-not (Get-XrayProcess)) { Write-ConfigForNode $node; Start-Xray }
    $uri = 'https://www.gstatic.com/generate_204'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { Invoke-WebRequest -Uri $uri -Proxy 'http://127.0.0.1:10809' -TimeoutSec 10 -UseBasicParsing | Out-Null; $sw.Stop(); [pscustomobject]@{ Node=$node.name; PingMs=$sw.ElapsedMilliseconds; Success=$true } } catch { $sw.Stop(); [pscustomobject]@{ Node=$node.name; PingMs=$null; Success=$false } }
}

function Test-AllNodes([Nullable[int]]$OnlyId) {
    $nodes = Read-Nodes
    if ($OnlyId.HasValue) { $nodes = @($nodes | Where-Object { [int]$_.id -eq $OnlyId.Value }) }
    foreach ($node in $nodes) { Test-Node ([int]$node.id) }
}

function Show-Help {
    @'
PowerShell Xray Manager

Usage:
  .\xray.ps1 start
  .\xray.ps1 stop
  .\xray.ps1 restart
  .\xray.ps1 status
  .\xray.ps1 update -SubscriptionUrl <url>
  .\xray.ps1 list
  .\xray.ps1 test [N]
  .\xray.ps1 select N
  .\xray.ps1 current

The first version intentionally keeps the controller in one PowerShell file.
Place xray.exe beside xray.ps1.
'@ | Write-Host
}

Initialize-Directories
switch ($Command.ToLowerInvariant()) {
    'start' { Start-Xray }
    'stop' { Stop-Xray }
    'restart' { Restart-Xray }
    'status' { Show-Status }
    'update' { Update-Subscription }
    'list' { Show-Nodes }
    'test' { if ($Index -gt 0) { Test-Node $Index } else { Test-AllNodes $null } }
    'select' { if ($Index -le 0) { throw 'Usage: .\xray.ps1 select N' }; Select-Node $Index }
    'current' { Show-Current }
    'help' { Show-Help }
    default { Show-Help; exit 1 }
}
