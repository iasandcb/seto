# Download the latest successful Windows TSF build and register it.
# UAC may prompt for regsvr32. Everything else is non-interactive.
# The DLL and its dictionaries go in a new folder pair:
#   %LOCALAPPDATA%\Seto\seto_tsf-<stamp>.dll
#   %LOCALAPPDATA%\Seto\seto_tsf-<stamp>\Resources
# A running process keeps korean-valid.txt memory-mapped, so this copy never
# overwrites that file. A dictionary that cannot be copied is skipped with a
# warning. Registration still runs. Restart the app you are testing.

[CmdletBinding()]
param(
    [string]$Branch,
    [string]$Repo = 'iasandcb/seto'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$registerLib = Join-Path $here 'seto-register.ps1'
if (-not (Test-Path -LiteralPath $registerLib)) { throw "Missing $registerLib" }
. $registerLib
if (Invoke-SetoAs64Bit -ScriptPath $PSCommandPath -Bound $PSBoundParameters) { exit $script:Seto64BitExit }

function Require-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw @"
GitHub CLI (gh) is not on PATH, so this script cannot download an Actions artifact.
A public release does not need gh. From a checkout run:
  powershell -ExecutionPolicy Bypass -File scripts\windows\install-release.ps1
"@
    }
    & gh auth status 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw @"
gh is installed but not logged in, so this script cannot download an Actions artifact.
A public release does not need gh. From a checkout run:
  powershell -ExecutionPolicy Bypass -File scripts\windows\install-release.ps1
"@
    }
}

function New-SetoLayout([string]$DestDir) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $stem = "seto_tsf-$stamp"
    $dll = Join-Path $DestDir "$stem.dll"
    $suffix = 1
    while (Test-Path -LiteralPath $dll) {
        $stem = "seto_tsf-$stamp-$suffix"
        $dll = Join-Path $DestDir "$stem.dll"
        $suffix++
    }
    [pscustomobject]@{
        Dll       = $dll
        Resources = Join-Path $DestDir "$stem\Resources"
    }
}

function Copy-SetoResources([string]$SourceDir, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $SourceDir)) {
        Write-Warning "No dictionary folder at $SourceDir. Registering the DLL anyway."
        return
    }
    try {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    } catch {
        Write-Warning "Could not create ${Destination}: $($_.Exception.Message). Registering the DLL anyway."
        return
    }
    $files = @(Get-ChildItem -LiteralPath $SourceDir -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        Write-Warning "No dictionary files in $SourceDir. Registering the DLL anyway."
        return
    }
    foreach ($file in $files) {
        $target = Join-Path $Destination $file.Name
        try {
            if (Test-Path -LiteralPath $target) {
                $srcHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                $dstHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
                if ($srcHash -eq $dstHash) {
                    Write-Host "Unchanged $($file.Name)"
                    continue
                }
            }
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force -ErrorAction Stop
            Write-Host "Copied $($file.Name)"
        } catch {
            Write-Warning "Skipped $($file.Name): $($_.Exception.Message)"
        }
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

Get-ChildItem -LiteralPath $destDir -Filter 'seto_tsf*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Unregister-SetoDll -DllPath $_.FullName
        Write-Host "Unregistered $($_.FullName)"
    } catch {
        Write-Warning "Unregister skipped for $($_.FullName): $($_.Exception.Message)"
    }
}

$layout = New-SetoLayout $destDir
Copy-Item -LiteralPath $source -Destination $layout.Dll -Force
try {
    Copy-SetoResources -SourceDir (Join-Path $stage 'Resources') -Destination $layout.Resources
} catch {
    Write-Warning "Dictionary copy failed ($($_.Exception.Message)). Registering the DLL anyway."
}

Register-SetoDll -DllPath $layout.Dll
Write-Host "Registered $($layout.Dll) from $($run.headSha)"
Write-Host "Restart the app you are testing. A Windows logout is not required."
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
