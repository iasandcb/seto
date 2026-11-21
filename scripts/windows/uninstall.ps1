# Unregister the Seto TSF text service and delete the DLL copied by install.ps1.
# Dictionary files under %LOCALAPPDATA%\Seto\Resources are left in place.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:LOCALAPPDATA 'Seto\seto_tsf.dll'

if (Test-Path -LiteralPath $dest) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin) {
        & regsvr32.exe /s /u $dest
        if ($LASTEXITCODE -ne 0) { throw "regsvr32 /u failed with exit code $LASTEXITCODE" }
    } else {
        $proc = Start-Process -FilePath regsvr32.exe -ArgumentList @('/s', '/u', $dest) -Verb RunAs -Wait -PassThru
        if (-not $proc -or $proc.ExitCode -ne 0) {
            $code = if ($proc) { $proc.ExitCode } else { 'cancelled' }
            throw "regsvr32 /u was not approved or failed ($code)"
        }
    }
    Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $dest) {
        Write-Warning "Unregister succeeded but $dest is still in use. Sign out, then delete it."
    } else {
        Write-Host "Removed $dest"
    }
} else {
    Write-Host "No DLL at $dest. If 세토 is still listed, it was registered from another path."
}
