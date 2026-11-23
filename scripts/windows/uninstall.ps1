# Unregister every Seto TSF DLL copied under %LOCALAPPDATA%\Seto.
# A file the running process still has mapped is left in place with a warning.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$registerLib = Join-Path $here 'seto-register.ps1'
if (-not (Test-Path -LiteralPath $registerLib)) { throw "Missing $registerLib" }
. $registerLib
if (Invoke-SetoAs64Bit -ScriptPath $PSCommandPath -Bound $PSBoundParameters) { exit $script:Seto64BitExit }
$destDir = Join-Path $env:LOCALAPPDATA 'Seto'

if (-not (Test-Path -LiteralPath $destDir)) {
    Write-Host "No Seto folder at $destDir."
    return
}

$dlls = @(Get-ChildItem -LiteralPath $destDir -Filter 'seto_tsf*.dll' -File -ErrorAction SilentlyContinue)
if ($dlls.Count -eq 0) {
    Write-Host "No DLL under $destDir. If 세토 is still listed, it was registered from another path."
} else {
    foreach ($dll in $dlls) {
        try {
            Unregister-SetoDll -DllPath $dll.FullName
            Write-Host "Unregistered $($dll.FullName)"
        } catch {
            Write-Warning "Unregister skipped for $($dll.FullName): $($_.Exception.Message)"
        }
        try {
            Remove-Item -LiteralPath $dll.FullName -Force -ErrorAction Stop
            Write-Host "Removed $($dll.FullName)"
        } catch {
            Write-Warning "$($dll.FullName) is still in use. Sign out, then delete it."
        }
    }
}

Get-ChildItem -LiteralPath $destDir -Directory -Filter 'seto_tsf-*' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        Write-Host "Removed $($_.FullName)"
    } catch {
        Write-Warning "Left $($_.FullName) in place: $($_.Exception.Message)"
    }
}
