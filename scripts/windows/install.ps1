# Register the Seto TSF text service (x64). Copies the DLL to %LOCALAPPDATA%\Seto
# and runs regsvr32. Registration writes HKCR, so an elevated regsvr32 is started
# when the current session is not already elevated. The DLL path stays in the
# invoking user's profile.

[CmdletBinding()]
param(
    [string]$DllPath,
    [string]$Resources
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Resolve-Existing([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        return (Resolve-Path -LiteralPath $Path).Path
    }
    return $null
}

function Find-Dll {
    if ($DllPath) {
        $resolved = Resolve-Existing $DllPath
        if (-not $resolved) { throw "DLL not found: $DllPath" }
        return $resolved
    }
    foreach ($candidate in @(
            (Join-Path $here 'seto_tsf.dll'),
            (Join-Path $here '..\..\core-rs\target\x86_64-pc-windows-msvc\release\seto_tsf.dll'),
            (Join-Path $here '..\..\core-rs\target\release\seto_tsf.dll')
        )) {
        $resolved = Resolve-Existing $candidate
        if ($resolved) { return $resolved }
    }
    throw "seto_tsf.dll not found. Build it or pass -DllPath."
}

function Find-ResourceDir {
    $candidates = @()
    if ($Resources) { $candidates += $Resources }
    $candidates += (Join-Path $here 'Resources')
    $candidates += (Join-Path $here '..\..\Resources')
    foreach ($dir in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $dir 'korean-words.txt')) {
            return (Resolve-Path -LiteralPath $dir).Path
        }
    }
    return $null
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
    if (-not $SourceDir) {
        Write-Warning "No Resources\korean-words.txt next to the script. Hangul still composes; auto-switch needs the dictionaries."
        return
    }
    try {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    } catch {
        Write-Warning "Could not create ${Destination}: $($_.Exception.Message). Registering the DLL anyway."
        return
    }
    $files = @(Get-ChildItem -LiteralPath $SourceDir -File -ErrorAction SilentlyContinue)
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
    Write-Host "Dictionaries: $Destination"
}

$source = Find-Dll
$destDir = Join-Path $env:LOCALAPPDATA 'Seto'
New-Item -ItemType Directory -Force -Path $destDir | Out-Null
$layout = New-SetoLayout $destDir
Copy-Item -LiteralPath $source -Destination $layout.Dll -Force
try {
    Copy-SetoResources -SourceDir (Find-ResourceDir) -Destination $layout.Resources
} catch {
    Write-Warning "Dictionary copy failed ($($_.Exception.Message)). Registering the DLL anyway."
}
$dest = $layout.Dll

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
$admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($admin) {
    & regsvr32.exe /s $dest
    if ($LASTEXITCODE -ne 0) { throw "regsvr32 failed with exit code $LASTEXITCODE" }
} else {
    $proc = Start-Process -FilePath regsvr32.exe -ArgumentList @('/s', $dest) -Verb RunAs -Wait -PassThru
    if (-not $proc -or $proc.ExitCode -ne 0) {
        $code = if ($proc) { $proc.ExitCode } else { 'cancelled' }
        throw "regsvr32 was not approved or failed ($code)"
    }
}

Write-Host "Registered 세토: $dest"
Write-Host "Sign out once if the keyboard does not appear, then add 세토 under Settings > Time & language > Language & region > Korean > Options > Keyboards."
