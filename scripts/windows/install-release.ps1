# Download the public Windows x64 release and register it.
# No git and no GitHub CLI. The repository must be public.
# The zip's install.ps1, seto_tsf.dll, and Resources\ share one folder.
#
#   powershell -ExecutionPolicy Bypass -File scripts\windows\install-release.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\windows\install-release.ps1 -Tag windows-v0.1.0
#   powershell -ExecutionPolicy Bypass -File scripts\windows\install-release.ps1 -Stable
#
# The default picks the newest release that has seto-windows-x64.zip, including
# prereleases. -Stable uses releases/latest/download/seto-windows-x64.zip, which
# skips prereleases. Existing seto_tsf*.dll registrations are removed first.
# UAC may prompt once to unregister and again to register.

[CmdletBinding()]
param(
    [string]$Tag,
    [string]$Repo = 'iasandcb/seto',
    [string]$Asset = 'seto-windows-x64.zip',
    [switch]$Stable
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($Tag -and $Stable) { throw 'Pass only one of -Tag or -Stable.' }
if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Unexpected -Repo: $Repo" }
if ($Tag -and $Tag -notmatch '^[A-Za-z0-9._+-]+$') { throw "Unexpected -Tag: $Tag" }
if ($Asset -notmatch '^[A-Za-z0-9._+-]+$') { throw "Unexpected -Asset: $Asset" }

function Get-ReleaseZipUrl {
    if ($Tag) {
        return "https://github.com/$Repo/releases/download/$Tag/$Asset"
    }
    if ($Stable) {
        return "https://github.com/$Repo/releases/latest/download/$Asset"
    }
    $headers = @{
        'User-Agent' = 'seto-windows-install'
        Accept       = 'application/vnd.github+json'
    }
    $uri = "https://api.github.com/repos/$Repo/releases?per_page=20"
    $releases = @(Invoke-RestMethod -Headers $headers -Uri $uri)
    foreach ($rel in $releases) {
        if (-not $rel -or $rel.draft -or -not $rel.assets) { continue }
        foreach ($item in @($rel.assets)) {
            if ($item -and $item.name -eq $Asset -and $item.browser_download_url) {
                return [string]$item.browser_download_url
            }
        }
    }
    throw "No $Asset on https://github.com/$Repo/releases"
}

function Resolve-InstallRoot([string]$Stage) {
    $direct = Join-Path $Stage 'install.ps1'
    if (Test-Path -LiteralPath $direct) { return $Stage }
    $dirs = @(Get-ChildItem -LiteralPath $Stage -Directory -ErrorAction SilentlyContinue)
    if ($dirs.Count -eq 1) {
        $nested = Join-Path $dirs[0].FullName 'install.ps1'
        if (Test-Path -LiteralPath $nested) { return $dirs[0].FullName }
    }
    throw "install.ps1 not found in $Asset"
}

function Invoke-RegSvr([string[]]$ArgumentList) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin) {
        & regsvr32.exe @ArgumentList
        if ($LASTEXITCODE -ne 0) { throw "regsvr32 $($ArgumentList -join ' ') failed with exit code $LASTEXITCODE" }
        return
    }
    $proc = Start-Process -FilePath regsvr32.exe -ArgumentList $ArgumentList -Verb RunAs -Wait -PassThru
    if (-not $proc -or $proc.ExitCode -ne 0) {
        $code = if ($proc) { $proc.ExitCode } else { 'cancelled' }
        throw "regsvr32 was not approved or failed ($code)"
    }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}

$url = Get-ReleaseZipUrl
$stage = Join-Path $env:TEMP ("seto-release-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$zip = Join-Path $stage $Asset
Write-Host "Downloading $url"
try {
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
} catch {
    if ($Stable) {
        throw "Download failed ($($_.Exception.Message)). releases/latest skips prereleases such as windows-v0.1.0. Omit -Stable, or pass -Tag windows-v0.1.0."
    }
    throw
}

$stream = [System.IO.File]::OpenRead($zip)
try {
    $b0 = $stream.ReadByte()
    $b1 = $stream.ReadByte()
} finally {
    $stream.Dispose()
}
if ($b0 -ne 0x50 -or $b1 -ne 0x4B) { throw "Download is not a zip: $url" }

$unpack = Join-Path $stage 'unpack'
Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
$root = Resolve-InstallRoot $unpack
$dll = Join-Path $root 'seto_tsf.dll'
$dict = Join-Path (Join-Path $root 'Resources') 'korean-words.txt'
$installer = Join-Path $root 'install.ps1'
if (-not (Test-Path -LiteralPath $dll)) { throw "seto_tsf.dll is not next to install.ps1 ($url)" }
if (-not (Test-Path -LiteralPath $dict)) { throw "Resources\korean-words.txt is not next to install.ps1 ($url)" }

$destDir = Join-Path $env:LOCALAPPDATA 'Seto'
if (Test-Path -LiteralPath $destDir) {
    Get-ChildItem -LiteralPath $destDir -Filter 'seto_tsf*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Invoke-RegSvr @('/s', '/u', $_.FullName)
            Write-Host "Unregistered $($_.FullName)"
        } catch {
            Write-Warning "Unregister skipped for $($_.FullName): $($_.Exception.Message)"
        }
    }
}

& $installer
Write-Host "Installed from $url"
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
