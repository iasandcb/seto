# Fail the Windows build if seto_tsf.dll still imports the VC++ redistributable.
param(
    [Parameter(Mandatory = $true)][string]$Dll
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Dll)) { throw "DLL not found: $Dll" }

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw "vswhere not found: $vswhere" }
$dumpbin = @(
    & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe'
) | Select-Object -First 1
if (-not $dumpbin) { throw 'dumpbin.exe not found' }
Write-Host "dumpbin: $dumpbin"

$out = @(& $dumpbin /nologo /dependents $Dll)
$out | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "dumpbin failed with exit code $LASTEXITCODE" }

$banned = @(
    'VCRUNTIME140.dll',
    'VCRUNTIME140_1.dll',
    'MSVCP140.dll',
    'MSVCP140_1.dll',
    'MSVCP140_2.dll'
)
foreach ($name in $banned) {
    $pattern = '(?i)\b' + [regex]::Escape($name) + '\b'
    foreach ($line in $out) {
        if ($line -match $pattern) { throw "static CRT build still imports $name" }
    }
}
Write-Host 'No VC++ redistributable imports.'
