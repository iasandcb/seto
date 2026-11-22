# Unregister every Seto TSF DLL copied under %LOCALAPPDATA%\Seto.
# A file the running process still has mapped is left in place with a warning.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$destDir = Join-Path $env:LOCALAPPDATA 'Seto'

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
            Invoke-RegSvr @('/s', '/u', $dll.FullName)
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
