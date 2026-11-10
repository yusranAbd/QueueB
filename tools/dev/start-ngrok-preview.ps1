[CmdletBinding()]
param(
    [string]$PublicUrl = $env:QUEUEB_PREVIEW_URL,
    [string[]]$AllowedEmail = @(),
    [ValidateRange(1, 65535)][int]$WebPort = 5173,
    [ValidateRange(1, 65535)][int]$ApiPort = 3000,
    [ValidateRange(1, 65535)][int]$ProxyPort = 8085,
    [ValidateRange(1, 65535)][int]$NgrokApiPort = 4045,
    [ValidateRange(10, 900)][int]$ReadyTimeoutSeconds = 600,
    [string]$Flutter = 'flutter',
    [string]$Ngrok = 'ngrok',
    [string]$NgrokConfig,
    [switch]$DemoDataOnly,
    [switch]$CheckOnly,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'preview-process.ps1')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$clientRoot = Join-Path $repoRoot 'apps/client'
$runtimeRoot = Join-Path $repoRoot '.cache/ngrok-preview'
$statePath = Join-Path $runtimeRoot 'active.json'
$groups = @()
$previewMutex = $null
$ownsMutex = $false
$runId = [Guid]::NewGuid().ToString('D')
$runRoot = Join-Path $runtimeRoot $runId

function Quote-PreviewArgument([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Invoke-PreviewCommand([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 15) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = (@($Arguments | ForEach-Object { Quote-PreviewArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Only this short-lived command's own process handle is terminated.
            $process.Kill()
            throw 'Pemeriksaan CLI preview melewati batas waktu.'
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.GetAwaiter().GetResult(); Errors = $errors.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}

function Get-PreviewNgrokMetadata([string]$Path) {
    if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 1MB) { throw 'Konfigurasi ngrok terlalu besar untuk preflight.' }
    # Inspect YAML keys and scalar presence without constructing a token string.
    # Config syntax/schema remain ngrok's responsibility, not this metadata scan.
    $reader = [IO.File]::OpenText($Path)
    $version = ''; $rootToken = $false; $agentToken = $false
    $inAgent = $false; $agentChildIndent = -1; $crlf = $false
    try {
        while ($reader.Peek() -ge 0) {
            $keys = @('version', 'agent', 'authtoken', '"version"', '"agent"', '"authtoken"', "'version'", "'agent'", "'authtoken'")
            $keyLength = 0; $keyStarted = $false; $keyFinished = $false
            $indent = 0; $colon = $false; $comment = $false
            while (($code = $reader.Read()) -ge 0 -and $code -notin @(10, 13)) {
                if ($code -eq 58) { $colon = $true; break }
                if (-not $keyStarted -and $code -eq 32) { $indent++; continue }
                if (-not $keyStarted -and $code -eq 35) { $comment = $true; $keys = @() }
                $keyStarted = $true
                if ($keys.Count -eq 0) { continue }
                if ([char]::IsWhiteSpace([char]$code) -and @($keys | Where-Object { $_.Length -eq $keyLength }).Count -gt 0) { $keyFinished = $true; continue }
                if ($keyFinished) { $keys = @(); continue }
                $keys = @($keys | Where-Object { $_.Length -gt $keyLength -and $_[$keyLength] -ceq [char]$code })
                $keyLength++
            }
            $name = ''
            $completeKeys = @($keys | Where-Object { $_.Length -eq $keyLength })
            if ($completeKeys.Count -gt 0) { $name = $completeKeys[0].Trim([char[]]@('"', "'")) }
            if ($colon -and $indent -eq 0 -and -not $comment) { $inAgent = $name -ceq 'agent'; $agentChildIndent = -1 }
            if ($colon -and $inAgent -and $indent -gt 0 -and -not $comment -and $agentChildIndent -lt 0) { $agentChildIndent = $indent }
            $isVersion = $colon -and $indent -eq 0 -and $name -ceq 'version'
            $isToken = $colon -and $name -ceq 'authtoken' -and ($indent -eq 0 -or ($inAgent -and $indent -eq $agentChildIndent))
            $present = $false; $started = $false; $done = $false; $quote = 0
            $count = 0; $first = 0; $nullLiteral = $true
            if ($colon) {
                while (($code = $reader.Read()) -ge 0 -and $code -notin @(10, 13)) {
                    if ((-not $isToken -and -not $isVersion) -or $done) { continue }
                    if (-not $started) {
                        if ([char]::IsWhiteSpace([char]$code)) { continue }
                        $started = $true
                        if ($code -in @(34, 39)) { $quote = $code; continue }
                    } elseif ($quote -ne 0 -and $code -eq $quote) { $done = $true; continue }
                    if ($quote -eq 0 -and $code -eq 35) { $done = $true; continue }
                    if ([char]::IsWhiteSpace([char]$code)) { continue }
                    if ($count -eq 0) { $first = $code }
                    if ($count -ge 4 -or [char]::ToLowerInvariant([char]$code) -cne 'null'[$count]) { $nullLiteral = $false }
                    $count++; $present = $true
                }
            }
            if ($code -eq 13 -and $reader.Peek() -eq 10) { [void]$reader.Read(); $crlf = $true }
            $nonemptyScalar = $present -and $first -notin @(62, 124) -and
                ($quote -ne 0 -or -not (($nullLiteral -and $count -eq 4) -or ($first -eq 126 -and $count -eq 1)))
            if ($isVersion -and $nonemptyScalar -and $count -eq 1 -and $first -in @(50, 51)) { $version = [string][char]$first }
            if ($isToken -and $nonemptyScalar) {
                if ($indent -eq 0) { $rootToken = $true } else { $agentToken = $true }
            }
        }
        return [pscustomobject]@{ Version = $version; HasToken = (($version -eq '2' -and $rootToken) -or ($version -eq '3' -and $agentToken)); HasCrLf = $crlf }
    } finally { $reader.Dispose() }
}

function Resolve-PreviewNgrokMetadataPath([string]$Path, [string]$Executable) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return $Path }
    # Store/MSIX ngrok sees a virtualized LocalAppData path. Keep that logical
    # path for the CLI; inspect metadata at its package-backed physical file.
    $defaultPath = Join-Path $env:LOCALAPPDATA 'ngrok/ngrok.yml'
    if ([IO.Path]::GetFullPath($Path) -ine [IO.Path]::GetFullPath($defaultPath)) { return $null }
    $aliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/ngrok.exe'
    foreach ($package in @(Get-AppxPackage -Name 'ngrok.ngrok' -ErrorAction SilentlyContinue)) {
        $packagePrefix = [IO.Path]::GetFullPath($package.InstallLocation).TrimEnd('\') + '\'
        if ([IO.Path]::GetFullPath($Executable) -ine [IO.Path]::GetFullPath($aliasPath) -and
            -not [IO.Path]::GetFullPath($Executable).StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $candidate = Join-Path (Join-Path $env:LOCALAPPDATA ('Packages/' + $package.PackageFamilyName)) 'LocalCache/Local/ngrok/ngrok.yml'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-PreviewSetting([string]$Name, [string]$Default) {
    if ($Name -notin @('NODE_ENV', 'SERVICE_TIME_ZONE')) { throw 'Metadata environment tidak diizinkan.' }
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    foreach ($file in @((Join-Path $repoRoot '.env'), (Join-Path $repoRoot 'apps/api/.env'))) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        foreach ($line in [IO.File]::ReadLines($file)) {
            if ($line -match ('^\s*(?:export\s+)?' + $Name + '\s*=\s*["'']?([A-Za-z0-9_+/-]+)["'']?\s*(?:#.*)?$')) { return $Matches[1] }
        }
    }
    return $Default
}

function Test-PreviewPort([int]$Port) {
    if (@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    $tcp = New-Object Net.Sockets.TcpClient
    try { return $tcp.ConnectAsync('127.0.0.1', $Port).Wait(500) -and $tcp.Connected }
    catch { return $false }
    finally { $tcp.Dispose() }
}

function Get-PreviewHttp([string]$Url, [string]$Origin = '', [string]$InstanceId = '', [switch]$HashBody, [int]$Attempts = 3) {
    # Retry hanya untuk timeout/pembatalan (mis. Flutter masih kompilasi); error lain langsung dilempar.
    for ($attempt = 1; ; $attempt++) {
        try { return Get-PreviewHttpOnce -Url $Url -Origin $Origin -InstanceId $InstanceId -HashBody:$HashBody }
        catch {
            $timedOut = $false
            for ($ex = $_.Exception; $null -ne $ex; $ex = $ex.InnerException) {
                if ($ex -is [Threading.Tasks.TaskCanceledException] -or $ex -is [OperationCanceledException] -or $ex -is [TimeoutException] -or $ex.Message -match 'task was canceled|timed out') { $timedOut = $true; break }
            }
            if (-not $timedOut -or $attempt -ge $Attempts) { throw }
            Start-Sleep -Seconds 2
        }
    }
}

function Get-PreviewHttpOnce([string]$Url, [string]$Origin = '', [string]$InstanceId = '', [switch]$HashBody) {
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false; $handler.UseCookies = $false; $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(8)
    $cancel = New-Object Threading.CancellationTokenSource
    $cancel.CancelAfter(8000)
    $response = $null; $stream = $null; $memory = $null; $hash = $null
    try {
        if ($Origin) { [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Origin', $Origin) }
        if ($InstanceId) { [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-QueueB-Preview-Instance', $InstanceId) }
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('ngrok-skip-browser-warning', 'preview-readiness')
        $response = $client.GetAsync($Url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
        $limit = if ($HashBody) { 32MB } else { 256KB }
        if ($response.Content.Headers.ContentLength -gt $limit) { throw 'Respons kesiapan preview terlalu besar.' }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        if ($HashBody) { $hash = [Security.Cryptography.SHA256]::Create() } else { $memory = New-Object IO.MemoryStream }
        $buffer = New-Object byte[] 65536
        [long]$total = 0
        while ($true) {
            $read = $stream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token).GetAwaiter().GetResult()
            if ($read -eq 0) { break }
            $total += $read
            if ($total -gt $limit) { throw 'Respons kesiapan preview melebihi batas pembacaan.' }
            if ($HashBody) { [void]$hash.TransformBlock($buffer, 0, $read, $buffer, 0) } else { $memory.Write($buffer, 0, $read) }
        }
        $bodyHash = ''; $body = ''
        if ($HashBody) { [void]$hash.TransformFinalBlock([byte[]]@(), 0, 0); $bodyHash = [BitConverter]::ToString($hash.Hash).Replace('-', '') }
        else { $body = [Text.Encoding]::UTF8.GetString($memory.ToArray()) }
        $cors = ''
        if ($response.Headers.Contains('Access-Control-Allow-Origin')) { $cors = [string]($response.Headers.GetValues('Access-Control-Allow-Origin') | Select-Object -First 1) }
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $body; Sha256 = $bodyHash; CorsOrigin = $cors; Location = $response.Headers.Location }
    } finally {
        foreach ($resource in @($hash, $memory, $stream, $response, $cancel, $client, $handler)) { if ($null -ne $resource) { $resource.Dispose() } }
    }
}

function Assert-PreviewApi([string]$Base, [string]$Origin) {
    $health = Get-PreviewHttp "$Base/api/v1/health"
    try { $data = $health.Body | ConvertFrom-Json } catch { $data = $null }
    if ($health.Status -ne 200 -or $null -eq $data -or $data.service -ne 'capstone-antrean-api' -or $data.database -ne 'connected') {
        throw "NestJS existing belum siap pada $Base. Jalankan npm run start:dev di apps/api; preview tidak membuat API/database baru."
    }
    $auth = Get-PreviewHttp "$Base/api/v1/auth/me" $Origin
    if ($auth.Status -ne 401 -or $auth.CorsOrigin -cne $Origin) {
        throw "API harus menolak request tanpa login (HTTP 401) dan mengizinkan Origin $Origin secara persis. Tambahkan origin itu ke CORS_ALLOWED_ORIGINS environment proses dengan mempertahankan origin existing, lalu restart API manual. Jangan memakai wildcard; .env tidak diubah script."
    }
}

function Assert-PreviewSocket([string]$Base, [string]$Origin, [string]$Expected) {
    $probe = Invoke-PreviewCommand $nodePath @((Join-Path $PSScriptRoot 'check-preview-socket.cjs'), '--url', $Base, '--origin', $Origin, '--expect', $Expected) 12
    if ($probe.ExitCode -ne 0) { throw "Pemeriksaan origin/autentikasi Socket.IO belum sesuai ($Expected). Periksa CORS_ALLOWED_ORIGINS environment proses API dan restart manual; autentikasi tidak dilewati." }
}

function Stop-RequestedPreview {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { Write-Host 'Tidak ada sesi preview yang tercatat.'; return }
    $record = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $recordId = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$record.runId, [ref]$recordId) -or $record.repoRoot -ine $repoRoot) { throw 'Metadata sesi preview tidak dikenali.' }
    $expectedRoot = Join-Path $runtimeRoot $recordId.ToString('D')
    if ([IO.Path]::GetFullPath($record.runRoot) -ine [IO.Path]::GetFullPath($expectedRoot)) { throw 'Direktori kontrol preview tidak sesuai workspace.' }
    $controller = Get-Process -Id $record.controllerPid -ErrorAction SilentlyContinue
    if ($null -eq $controller -or [Math]::Abs(($controller.StartTime.ToUniversalTime() - [DateTime]::Parse($record.controllerStartedAt).ToUniversalTime()).TotalMilliseconds) -gt 1) {
        Write-Host 'Sesi preview tersebut sudah tidak aktif; tidak ada proses yang dihentikan.'; return
    }
    # The live owner observes its own file and closes only its own Job Objects.
    [IO.File]::WriteAllText((Join-Path $expectedRoot 'stop.request'), $recordId.ToString('D'))
    Write-Host 'Permintaan shutdown dikirim ke pemilik preview. API dan proses pengguna tetap dipertahankan.'
}

try {
    if ($Stop) { Stop-RequestedPreview; return }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Launcher ini untuk Windows PowerShell; proxy Node dapat dijalankan terpisah pada platform lain.' }
    if ((Get-PreviewSetting 'NODE_ENV' 'development') -eq 'production') { throw 'Remote Preview hanya untuk development/data fiktif, bukan production.' }
    if (-not $CheckOnly -and -not $DemoDataOnly) { throw 'Tambahkan -DemoDataOnly hanya setelah memastikan backend memakai data demo fiktif. Tidak ada data yang diubah script.' }
    $publicUri = $null
    if (-not [Uri]::TryCreate($PublicUrl, [UriKind]::Absolute, [ref]$publicUri) -or $publicUri.Scheme -ne 'https' -or
        $publicUri.UserInfo -or $publicUri.Query -or $publicUri.Fragment -or $publicUri.AbsolutePath -ne '/' -or
        -not $publicUri.IsDefaultPort -or $publicUri.HostNameType -ne [UriHostNameType]::Dns -or
        $publicUri.Host -notmatch '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') { throw 'Berikan -PublicUrl berupa satu domain HTTPS ngrok milik Anda, tanpa path/query/kredensial.' }
    $PublicUrl = $publicUri.GetLeftPart([UriPartial]::Authority)
    if ($AllowedEmail.Count -eq 0 -and $env:QUEUEB_PREVIEW_EMAILS) { $AllowedEmail = $env:QUEUEB_PREVIEW_EMAILS.Split(',') }
    $emails = @($AllowedEmail | ForEach-Object { $_.Trim().ToLowerInvariant() } | Select-Object -Unique)
    if ($emails.Count -eq 0 -or @($emails | Where-Object { $_ -notmatch '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' }).Count -gt 0) { throw 'Berikan -AllowedEmail dengan email Google yang boleh mengakses. Preview tidak tersedia untuk semua akun Google.' }
    if (@($WebPort, $ApiPort, $ProxyPort, $NgrokApiPort | Select-Object -Unique).Count -ne 4 -or $ProxyPort -eq 8080) { throw 'Port Web/API/proxy/ngrok API harus berbeda; gateway lama 8080 tidak digunakan.' }
    Initialize-QueueBPreviewProcessType
    $nodePath = (Get-Command node -ErrorAction Stop).Source
    $flutterPath = (Get-Command $Flutter -ErrorAction Stop).Source
    $ngrokPath = (Get-Command $Ngrok -ErrorAction Stop).Source
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $policyPath = Join-Path $runRoot 'traffic-policy.json'
    $emailExpression = '[' + ((@($emails | ForEach-Object { "'$_'" })) -join ', ') + ']'
    $policy = @{ on_http_request = @(
        @{ actions = @(@{ type = 'oauth'; config = @{ provider = 'google' } }) },
        @{ expressions = @("!(actions.ngrok.oauth.identity.email in $emailExpression)"); actions = @(@{ type = 'deny'; config = @{ status_code = 403 } }) }
    ) }
    [IO.File]::WriteAllText($policyPath, ($policy | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $version = Invoke-PreviewCommand $ngrokPath @('version')
    if ($version.ExitCode -ne 0 -or ($version.Output + "`n" + $version.Errors) -notmatch 'ngrok version\s+3\.') { throw 'ngrok Agent v3 tidak tersedia. Instal/perbarui melalui panduan REMOTE_PREVIEW_NGROK.md.' }
    $configArgs = @('config', 'check')
    if ($NgrokConfig) { $NgrokConfig = [IO.Path]::GetFullPath($NgrokConfig); $configArgs += "--config=$NgrokConfig" }
    $configCheck = Invoke-PreviewCommand $ngrokPath $configArgs
    if (-not $NgrokConfig) {
        # ngrok 3 reports its selected file; accept either captured stream.
        $checkText = [regex]::Replace(($configCheck.Output + "`n" + $configCheck.Errors), '\x1B\[[0-?]*[ -/]*[@-~]', '')
        if ($configCheck.ExitCode -eq 0 -and $checkText -match '(?im)^\s*Valid configuration file at\s+(.+?)\s*$') {
            $NgrokConfig = $Matches[1].Trim().Trim([char[]]@('"', "'"))
        } elseif ($env:LOCALAPPDATA) {
            # Windows default, never an assumed ~/.config/ngrok path. Any
            # fallback is checked explicitly by ngrok before inspecting keys.
            $windowsConfig = Join-Path $env:LOCALAPPDATA 'ngrok/ngrok.yml'
            if (Test-Path -LiteralPath $windowsConfig -PathType Leaf) { $NgrokConfig = $windowsConfig }
        }
        $checkText = $null
    }
    $hasToken = -not [string]::IsNullOrWhiteSpace($env:NGROK_AUTHTOKEN)
    $configVersion = '3'
    if ($NgrokConfig) {
        $NgrokConfig = [IO.Path]::GetFullPath($NgrokConfig)
        if ($NgrokConfig.Contains(',')) { throw 'Path konfigurasi ngrok berisi koma. Periksa -NgrokConfig.' }
        $selectedCheck = Invoke-PreviewCommand $ngrokPath @('config', 'check', "--config=$NgrokConfig")
        if ($selectedCheck.ExitCode -ne 0) { throw 'Konfigurasi ngrok terpilih tidak valid menurut CLI; periksa ngrok config check. Tunnel tidak dibuka.' }
        $metadataPath = Resolve-PreviewNgrokMetadataPath $NgrokConfig $ngrokPath
        if (-not $metadataPath) { throw 'CLI memvalidasi konfigurasi, tetapi lokasi fisiknya belum dapat ditemukan untuk memeriksa keberadaan kredensial. Periksa -NgrokConfig; ini bukan bukti authtoken tidak ada.' }
        $metadata = Get-PreviewNgrokMetadata $metadataPath
        if ($metadata.Version -notin @('2', '3')) { throw 'Versi konfigurasi ngrok tidak dikenali. Periksa ngrok config check secara lokal.' }
        $configVersion = $metadata.Version
        $hasToken = $hasToken -or $metadata.HasToken
    } elseif ($configCheck.ExitCode -eq 0) {
        throw 'CLI menyatakan config valid, tetapi path-nya belum dapat ditemukan. Berikan -NgrokConfig dengan path yang dilaporkan ngrok config check; ini bukan bukti authtoken tidak ada.'
    } elseif ($configCheck.ExitCode -ne 0 -and -not $hasToken) {
        throw 'Konfigurasi/authtoken ngrok belum tersedia atau belum valid. Jalankan ngrok config add-authtoken <TOKEN_ANDA> secara lokal, kemudian ngrok config check. Jangan kirim token ke chat atau repository. Tunnel tidak dibuka.'
    }
    if (-not $hasToken) { throw 'Authtoken ngrok belum terkonfigurasi. Tambahkan secara lokal; tunnel tidak dibuka.' }
    # Config syntax + credential presence are not proof the account/token works.
    # The access-controlled ngrok agent startup below remains the auth authority.
    $overlayPath = Join-Path $runRoot 'agent-preview.yml'
    $agentSettings = @("web_addr: 127.0.0.1:$NgrokApiPort", 'console_ui: false', 'log: false', 'remote_management: false', 'update_check: false', 'crl_noverify: false')
    $overlay = if ($configVersion -eq '3') { "version: 3`nagent:`n" + (($agentSettings | ForEach-Object { '  ' + $_ }) -join "`n") } else { "version: 2`n" + ($agentSettings -join "`n") }
    [IO.File]::WriteAllText($overlayPath, $overlay, [Text.UTF8Encoding]::new($false))
    $mergedConfig = if ($NgrokConfig) { "$NgrokConfig,$overlayPath" } else { $overlayPath }
    # 3.39.11 `config check --config` accepts one file, while `http --config`
    # accepts a merged list. The selected user config was validated above;
    # validate the matching-version overlay separately, then merge at startup.
    $overlayCheck = Invoke-PreviewCommand $ngrokPath @('config', 'check', "--config=$overlayPath")
    if ($overlayCheck.ExitCode -ne 0) { throw 'Overlay ngrok preview belum didukung konfigurasi ini. Periksa versi agent/config melalui panduan; tunnel tidak dibuka.' }
    $apiOrigin = "http://127.0.0.1:$ApiPort"
    $webOrigin = "http://127.0.0.1:$WebPort"
    $proxyOrigin = "http://127.0.0.1:$ProxyPort"
    Assert-PreviewApi $apiOrigin $PublicUrl
    Assert-PreviewSocket $apiOrigin $PublicUrl 'UNAUTHORIZED'
    Assert-PreviewSocket $apiOrigin 'https://queueb-unapproved.invalid' 'ORIGIN_NOT_ALLOWED'
    Write-Host 'ngrok/config tersedia; REST dan Socket.IO mempertahankan autentikasi serta origin yang persis.'
    if ($CheckOnly) { Write-Host 'Preflight selesai. Tidak memulai Flutter, proxy, atau tunnel.'; return }
    $mutexHash = [Security.Cryptography.SHA256]::Create()
    try { $mutexKey = [BitConverter]::ToString($mutexHash.ComputeHash([Text.Encoding]::UTF8.GetBytes($repoRoot))).Replace('-', '').Substring(0, 12) }
    finally { $mutexHash.Dispose() }
    $previewMutex = New-Object Threading.Mutex($false, "Local.QueueB.RemotePreview.$mutexKey")
    try { $ownsMutex = $previewMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Sesi Remote Preview workspace ini masih aktif. Gunakan terminal pemilik atau -Stop; tidak membuat proses duplikat.' }
    foreach ($port in @($WebPort, $ProxyPort, $NgrokApiPort)) {
        if (Test-PreviewPort $port) { throw "Port $port sedang dipakai. Hentikan hanya service milik Anda melalui terminal pemilik atau pilih port preview lain. Web normal tidak diambil alih sebagai Web preview." }
    }
    $webGroup = New-Object QueueBRemotePreview.ProcessGroup
    $groups = @($webGroup)
    $proxyGroup = New-Object QueueBRemotePreview.ProcessGroup
    $groups = @($proxyGroup) + $groups
    $ngrokGroup = New-Object QueueBRemotePreview.ProcessGroup
    $groups = @($ngrokGroup) + $groups
    $controller = Get-Process -Id $PID
    @{ runId = $runId; repoRoot = $repoRoot; runRoot = $runRoot; controllerPid = $PID; controllerStartedAt = $controller.StartTime.ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
    $stopPath = Join-Path $runRoot 'stop.request'
    $timeZone = Get-PreviewSetting 'SERVICE_TIME_ZONE' 'Asia/Jakarta'
    $definesPath = Join-Path $runRoot 'web.defines.json'
    @{ API_BASE_URL = '/api/v1'; QUEUEB_REMOTE_PREVIEW = 'true'; SERVICE_TIME_ZONE = $timeZone } | ConvertTo-Json | Set-Content -LiteralPath $definesPath -Encoding utf8
    $flutterArgs = @('run', '-d', 'web-server', '--profile', '--web-hostname=127.0.0.1', "--web-port=$WebPort", "--target=$(Join-Path $clientRoot 'lib/main.dart')", "--dart-define-from-file=$definesPath")
    $shell = (Get-Process -Id $PID).Path
    $commandParts = @($flutterPath) + $flutterArgs
    $command = '& ' + ((@($commandParts | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })) -join ' ') + '; exit $LASTEXITCODE'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    [void]$webGroup.Start($shell, [string[]]@('-NoProfile', '-EncodedCommand', $encoded), $clientRoot, (Join-Path $runRoot 'flutter.log'))
    Write-Host "Memulai Flutter Web preview di $webOrigin (maksimum $ReadyTimeoutSeconds detik)."
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
    $webReady = $false; $nextProgress = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if (Test-Path -LiteralPath $stopPath) { throw 'Startup preview dibatalkan oleh pemilik sesi.' }
        if (-not $webGroup.HasActiveProcesses) { throw "Flutter preview berhenti. Periksa log lokal $runRoot\flutter.log; tidak ada server pengguna yang dihentikan." }
        try {
            foreach ($listener in @(Get-NetTCPConnection -State Listen -LocalPort $WebPort -ErrorAction SilentlyContinue)) {
                if ($listener.OwningProcess -gt 0 -and -not $webGroup.ContainsProcess([int]$listener.OwningProcess)) { throw 'LISTENER_NOT_OWNED' }
            }
            $index = Get-PreviewHttp "$webOrigin/"
            $artifactPath = Join-Path $clientRoot 'build/web/main.dart.js'
            if ($index.Status -eq 200 -and $index.Body -match 'flutter_bootstrap\.js|flutter\.js' -and (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
                $before = Get-Item -LiteralPath $artifactPath
                $served = Get-PreviewHttp "$webOrigin/main.dart.js" -HashBody
                $localHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
                $after = Get-Item -LiteralPath $artifactPath
                $webReady = $served.Status -eq 200 -and $served.Sha256 -ceq $localHash -and $before.LastWriteTimeUtc -eq $after.LastWriteTimeUtc -and $before.Length -eq $after.Length
            }
        } catch { if ($_.Exception.Message -eq 'LISTENER_NOT_OWNED') { throw 'Listener Web muncul dari proses lain; preview dibatalkan tanpa menghentikan proses tersebut.' } }
        if ($webReady) { break }
        if ([DateTime]::UtcNow -ge $nextProgress) { Write-Host 'Masih menunggu kompilasi Flutter; tidak meluncurkan server kedua.'; $nextProgress = [DateTime]::UtcNow.AddSeconds(15) }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $webReady) { throw "Flutter preview belum siap setelah $ReadyTimeoutSeconds detik. Log hanya tersedia lokal di $runRoot." }
    Assert-PreviewApi $apiOrigin $PublicUrl
    $proxyChild = $proxyGroup.Start($nodePath, [string[]]@((Join-Path $PSScriptRoot 'ngrok-preview-proxy.cjs'), '--port', "$ProxyPort", '--web-port', "$WebPort", '--api-port', "$ApiPort", '--public-origin', $PublicUrl, '--instance-id', $runId), $repoRoot, (Join-Path $runRoot 'proxy.log'))
    $proxyReady = $false; $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if ($proxyChild.HasExited) { throw 'Proxy preview berhenti; lihat log lokal proxy.log.' }
        try {
            $marker = Get-PreviewHttp "$proxyOrigin/__queueb_preview/health" -InstanceId $runId
            $info = $marker.Body | ConvertFrom-Json
            $proxyReady = $marker.Status -eq 200 -and $info.service -eq 'queueb-ngrok-preview-proxy' -and $info.instanceId -ceq $runId -and $info.publicOrigin -ceq $PublicUrl
        } catch { }
        if (-not $proxyReady) { Start-Sleep -Milliseconds 400 }
    } while (-not $proxyReady -and [DateTime]::UtcNow -lt $deadline)
    if (-not $proxyReady) { throw 'Proxy loopback belum terverifikasi; tunnel tidak dibuka.' }
    $proxiedIndex = Get-PreviewHttp "$proxyOrigin/"
    if ($proxiedIndex.Status -ne 200 -or $proxiedIndex.Body -notmatch 'flutter_bootstrap\.js|flutter\.js') { throw 'Proxy belum meneruskan Flutter Web dengan benar; tunnel tidak dibuka.' }
    Assert-PreviewApi $proxyOrigin $PublicUrl
    Assert-PreviewSocket $proxyOrigin $PublicUrl 'UNAUTHORIZED'
    $ngrokChild = $ngrokGroup.Start($ngrokPath, [string[]]@('http', $proxyOrigin, "--url=$PublicUrl", "--name=queueb-preview-$runId", "--config=$mergedConfig", "--traffic-policy-file=$policyPath", '--inspect=false', '--log=false'), $repoRoot, 'NUL')
    $tunnelReady = $false; $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if ($ngrokChild.HasExited) {
            throw "ngrok menolak startup (exit $($ngrokChild.ExitCode)). Periksa authtoken/domain dan dukungan OAuth/Traffic Policy pada paket Anda. Output agent tidak disimpan untuk melindungi diagnostik kredensial. Tidak beralih ke tunnel tanpa autentikasi."
        }
        try {
            $tunnelsReply = Get-PreviewHttp "http://127.0.0.1:$NgrokApiPort/api/tunnels"
            $tunnels = $tunnelsReply.Body | ConvertFrom-Json
            $tunnelReady = @($tunnels.tunnels | Where-Object { $_.public_url -ceq $PublicUrl -and $_.proto -eq 'https' -and $_.name -eq "queueb-preview-$runId" -and $_.config.addr -in @($proxyOrigin, "127.0.0.1:$ProxyPort") }).Count -eq 1
        } catch { }
        if (-not $tunnelReady) { Start-Sleep -Milliseconds 500 }
    } while (-not $tunnelReady -and [DateTime]::UtcNow -lt $deadline)
    if (-not $tunnelReady) { throw 'Endpoint HTTPS tidak cocok dengan ngrok/proxy sesi ini; preview dihentikan.' }
    $edge = Get-PreviewHttp "$PublicUrl/"
    $redirect = $edge.Location
    $authRedirect = $edge.Status -in @(302, 303, 307) -and $null -ne $redirect -and
        (($redirect.IsAbsoluteUri -and $redirect.Scheme -eq 'https' -and $redirect.Host -in @('accounts.google.com', 'idp.ngrok.com')) -or
         (-not $redirect.IsAbsoluteUri -and $redirect.OriginalString.StartsWith('/ngrok/login')) -or
         ($redirect.IsAbsoluteUri -and $redirect.GetLeftPart([UriPartial]::Authority) -ceq $PublicUrl -and $redirect.AbsolutePath.StartsWith('/ngrok/login')))
    if (-not $authRedirect) { throw 'Request tanpa sesi belum diarahkan ke OAuth yang dikenali; tunnel ditutup, bukan dibiarkan publik.' }
    Write-Host "Remote Preview HTTPS: $PublicUrl/"
    Write-Host 'Buka URL yang sama di laptop/tablet/HP. Login Google yang diizinkan, lalu login aplikasi seperti biasa.'
    Write-Host "API: $PublicUrl/api/v1 | Socket.IO: $PublicUrl/socket.io/ (WSS)."
    Write-Host 'Ctrl+C pada terminal ini, atau .\tools\dev\start-ngrok-preview.ps1 -Stop dari root repository, menghentikan hanya proses preview milik sesi ini.'
    Write-Host 'Data perangkat fisik dan login pengguna belum diuji. Tidak ada perubahan Firewall, Wi-Fi, router, Android, atau database.'
    while (-not (Test-Path -LiteralPath $stopPath)) {
        if ($proxyChild.HasExited -or $ngrokChild.HasExited -or -not $webGroup.HasActiveProcesses) { throw 'Salah satu proses preview berhenti; sesi lainnya akan dibersihkan.' }
        Start-Sleep -Seconds 1
    }
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
} finally {
    foreach ($group in $groups) { if ($null -ne $group) { $group.Dispose() } }
    if ($groups.Count -gt 0) { Write-Host 'Proses preview milik workflow dihentikan. NestJS, database, dan proses pengguna dipertahankan.' }
    if ($ownsMutex -and $null -ne $previewMutex) { $previewMutex.ReleaseMutex() }
    if ($null -ne $previewMutex) { $previewMutex.Dispose() }
}
