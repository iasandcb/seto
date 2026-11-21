# Download the latest successful Windows TSF build and register it.
# UAC may prompt for regsvr32. Everything else is non-interactive.
# If the installed DLL is loaded, it is renamed to seto_tsf.dll.old-<timestamp>
# and the new file is registered at a free path so a Windows logout is not required.
# Restart the app you are testing; processes that already loaded the old DLL keep it.

[CmdletBinding()]
param(
    [string]$Branch,
    [string]$Repo = 'iasandcb/seto'
)

$ErrorActionPreference = 'Stop'

function Require-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw @"
GitHub CLI (gh) is not on PATH.
Install it from https://cli.github.com/ and then run:
  gh auth login
"@
    }
    & gh auth status 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw @"
gh is installed but not logged in. Run:
  gh auth login
Then rerun this script.
"@
    }
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

Require-Gh

if (-not $Branch) {
    $Branch = & gh pr view --repo $Repo --json headRefName --jq .headRefName 2>$null
    if (-not $Branch) {
        $Branch = git rev-parse --abbrev-ref HEAD 2>$null
    }
    if (-not $Branch) { throw "Pass -Branch. Could not tell which PR branch to update." }
}

$runJson = & gh run list --repo $Repo --workflow windows-tsf.yml --branch $Branch --status success --limit 1 --json databaseId,headSha,url,conclusion
if ($LASTEXITCODE -ne 0 -or -not $runJson) { throw "Could not list Windows TSF runs for $Branch" }
$run = $runJson | ConvertFrom-Json
if (-not $run) { throw "No successful Windows TSF run for branch $Branch" }
if ($run -is [System.Array]) { $run = $run[0] }
Write-Host "Using $($run.headSha) ($($run.url))"

$stage = Join-Path $env:TEMP ("seto-update-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
& gh run download $run.databaseId --repo $Repo --name seto-windows-x64 --dir $stage
if ($LASTEXITCODE -ne 0) { throw "gh run download failed" }
$source = Join-Path $stage 'seto_tsf.dll'
if (-not (Test-Path -LiteralPath $source)) { throw "Artifact has no seto_tsf.dll" }

$destDir = Join-Path $env:LOCALAPPDATA 'Seto'
New-Item -ItemType Directory -Force -Path $destDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$installed = Join-Path $destDir 'seto_tsf.dll'

Get-ChildItem -LiteralPath $destDir -Filter 'seto_tsf*.dll' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Invoke-RegSvr @('/s', '/u', $_.FullName)
        Write-Host "Unregistered $($_.FullName)"
    } catch {
        Write-Warning "Unregister skipped for $($_.FullName): $($_.Exception.Message)"
    }
}

if (Test-Path -LiteralPath $installed) {
    try {
        Remove-Item -LiteralPath $installed -Force -ErrorAction Stop
    } catch {
        $old = Join-Path $destDir "seto_tsf.dll.old-$stamp"
        Rename-Item -LiteralPath $installed -NewName (Split-Path -Leaf $old) -ErrorAction Stop
        Write-Host "Locked DLL renamed to $old"
    }
}

$dest = Join-Path $destDir 'seto_tsf.dll'
if (Test-Path -LiteralPath $dest) {
    $dest = Join-Path $destDir "seto_tsf-$stamp.dll"
}
Copy-Item -LiteralPath $source -Destination $dest -Force
$resources = Join-Path $stage 'Resources'
if (Test-Path -LiteralPath $resources) {
    $resourceDest = Join-Path $destDir 'Resources'
    New-Item -ItemType Directory -Force -Path $resourceDest | Out-Null
    Copy-Item -Path (Join-Path $resources '*') -Destination $resourceDest -Force
}

Invoke-RegSvr @('/s', $dest)
Write-Host "Registered $dest from $($run.headSha)"
Write-Host "Restart the app you are testing. A Windows logout is not required."
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
