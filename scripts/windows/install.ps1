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

function Copy-Dictionaries([string]$Destination) {
    $candidates = @()
    if ($Resources) { $candidates += $Resources }
    $candidates += (Join-Path $here 'Resources')
    $candidates += (Join-Path $here '..\..\Resources')
    foreach ($dir in $candidates) {
        $words = Join-Path $dir 'korean-words.txt'
        if (Test-Path -LiteralPath $words) {
            New-Item -ItemType Directory -Force -Path $Destination | Out-Null
            Copy-Item -Path (Join-Path $dir '*.txt') -Destination $Destination -Force
            Write-Host "Dictionaries: $Destination"
            return
        }
    }
    Write-Warning "No Resources\korean-words.txt next to the script. Hangul still composes; auto-switch needs the dictionaries."
}

$source = Find-Dll
$destDir = Join-Path $env:LOCALAPPDATA 'Seto'
New-Item -ItemType Directory -Force -Path $destDir | Out-Null
$dest = Join-Path $destDir 'seto_tsf.dll'
Copy-Item -LiteralPath $source -Destination $dest -Force
Copy-Dictionaries (Join-Path $destDir 'Resources')

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
