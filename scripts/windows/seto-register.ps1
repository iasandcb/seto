# Shared regsvr32 helper for the x64 Seto TSF DLL. Dot-source this file.
#
# Start-Process -Verb RunAs -Wait -PassThru does not fill ExitCode. Windows
# PowerShell launches RunAs through ShellExecute, and $null -ne 0 is true, so
# a successful UAC approval was reported as "regsvr32 was not approved or
# failed". The elevated command writes the real exit code to a file. Success
# is the 64-bit CLSID and TIP profile pointing at this DLL, not the exit code
# by itself.
#
# The DLL is copied into the invoking user's %LOCALAPPDATA%\Seto before
# elevation. regsvr32 receives that absolute path, so an elevated token does
# not re-resolve LOCALAPPDATA (which would be a different profile if the
# consent dialog used another administrator).

$script:SetoClsid = '{8F3C1E90-390B-4A6E-B7D2-5E70A11E0001}'
$script:SetoProfile = '{8F3C1E90-390B-4A6E-B7D2-5E70A11E0002}'
$script:SetoLangKey = '0x00000412'

function Test-SetoAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SetoNativeExe([string]$Name) {
    # 32-bit PowerShell redirects System32 to SysWOW64. Sysnative is the
    # 64-bit System32 and exists only for a 32-bit process on 64-bit Windows.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $candidate = Join-Path $env:SystemRoot (Join-Path 'Sysnative' $Name)
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return Join-Path $env:SystemRoot (Join-Path 'System32' $Name)
}

function Get-SetoRegSvr64 {
    # Literal path for a 64-bit cmd.exe. Sysnative is invisible to that cmd.
    return Join-Path $env:SystemRoot 'System32\regsvr32.exe'
}

function Test-SetoPeX64([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { return $false }
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($pe -lt 0 -or ($pe + 6) -gt $bytes.Length) { return $false }
    if ($bytes[$pe] -ne 0x50 -or $bytes[$pe + 1] -ne 0x45 -or $bytes[$pe + 2] -ne 0 -or $bytes[$pe + 3] -ne 0) {
        return $false
    }
    return ([BitConverter]::ToUInt16($bytes, $pe + 4) -eq 0x8664)
}

function ConvertTo-SetoWinPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return $Path.Trim().Trim('"').TrimEnd('\').ToLowerInvariant()
}

function Format-SetoElevatedRegSvrArg {
    param(
        [Parameter(Mandatory = $true)][string]$RegSvr,
        [Parameter(Mandatory = $true)][string]$DllPath,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [switch]$Unregister
    )
    $flag = '/s'
    if ($Unregister) { $flag = '/s /u' }
    # Leading redirect so an exit code of 1 is not parsed as "1>".
    $run = "`"$RegSvr`" $flag `"$DllPath`" & > `"$OutFile`" echo !ERRORLEVEL!"
    return "/v:on /c `"$run`""
}

function Get-SetoRegistration {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $inprocKey = "SOFTWARE\Classes\CLSID\$script:SetoClsid\InprocServer32"
        $profileKeys = @(
            "SOFTWARE\Microsoft\CTF\TIP\$script:SetoClsid\LanguageProfile\$script:SetoLangKey\$script:SetoProfile",
            "SOFTWARE\Microsoft\CTF\TIP\$script:SetoClsid\LanguageProfile\00000412\$script:SetoProfile"
        )
        $inproc = $null
        $key = $base.OpenSubKey($inprocKey)
        if ($key) {
            try { $inproc = [string]$key.GetValue('') } finally { $key.Close() }
        }
        $profileKey = $profileKeys[0]
        $profile = $false
        foreach ($candidate in $profileKeys) {
            $tip = $base.OpenSubKey($candidate)
            if ($tip) {
                $profile = $true
                $profileKey = $candidate
                $tip.Close()
                break
            }
        }
        return [pscustomobject]@{
            Inproc         = $inproc
            ProfilePresent = [bool]$profile
            InprocKey      = "HKLM\$inprocKey"
            ProfileKey     = "HKLM\$profileKey"
        }
    } finally {
        $base.Close()
    }
}

function Test-SetoPointsAt($State, [string]$DllPath) {
    if (-not $State -or -not $State.ProfilePresent) { return $false }
    $registered = ConvertTo-SetoWinPath $State.Inproc
    $expected = ConvertTo-SetoWinPath $DllPath
    return [bool]($registered -and $expected -and ($registered -eq $expected))
}

function Format-SetoRegSvrError {
    param(
        $Code,
        $State,
        [string]$DllPath,
        [string]$Action
    )
    $shown = if ($null -eq $Code) { 'unavailable' } else { [string]$Code }
    $names = @{
        0 = 'SUCCESS'
        1 = 'FAIL_ARGS'
        2 = 'FAIL_OLE'
        3 = 'FAIL_LOAD'
        4 = 'FAIL_ENTRY'
        5 = 'FAIL_REG'
    }
    $name = ''
    if ($null -ne $Code -and $names.ContainsKey([int]$Code)) { $name = $names[[int]$Code] }
    $suffix = ''
    if ($name) { $suffix = " ($name)" }
    $inproc = if ($State -and $State.Inproc) { $State.Inproc } else { '(missing)' }
    $profileText = 'missing'
    $profileKey = ''
    if ($State) {
        $profileKey = $State.ProfileKey
        if ($State.ProfilePresent) { $profileText = 'present' }
    }
    $lines = @(
        "regsvr32 $Action failed. Exit code: $shown$suffix.",
        "DLL: $DllPath",
        "InprocServer32: $inproc",
        "Expected: $DllPath",
        "TIP profile ${profileKey}: $profileText"
    )
    if ($Code -eq 3) {
        $runtimeText = 'not checked'
        if ($env:SystemRoot) {
            $runtime = Get-SetoNativeExe 'vcruntime140.dll'
            $found = Test-Path -LiteralPath $runtime
            $runtimeText = if ($found) { "found at $runtime" } else { "MISSING at $runtime" }
            if (-not $found) {
                $lines += 'Install the x64 Visual C++ 2015-2022 redistributable: https://aka.ms/vs/17/release/vc_redist.x64.exe'
            }
        }
        $lines += "LoadLibrary failed. 64-bit VCRUNTIME140.dll is $runtimeText."
        $regsvr = if ($env:SystemRoot) { Get-SetoRegSvr64 } else { 'C:\Windows\System32\regsvr32.exe' }
        $lines += "This DLL is x64. A 32-bit regsvr32 under SysWOW64 cannot load it. The script runs $regsvr."
    }
    if ($Code -eq 5) {
        $lines += 'DllRegisterServer returned a failure HRESULT. See the log below.'
    }
    if ($env:LOCALAPPDATA) {
        $log = Join-Path (Join-Path $env:LOCALAPPDATA 'Seto') 'seto-tsf.log'
        if (Test-Path -LiteralPath $log) {
            $tail = @(Get-Content -LiteralPath $log -Tail 8 -ErrorAction SilentlyContinue)
            if ($tail.Count -gt 0) {
                $lines += "Last log lines ($log):"
                $lines += $tail
            }
        }
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-UacCancelled($ErrorRecord) {
    $ex = $ErrorRecord.Exception
    while ($ex) {
        $win32 = $ex -as [System.ComponentModel.Win32Exception]
        if ($win32 -and $win32.NativeErrorCode -eq 1223) { return $true }
        if ($ex.Message -match 'canceled by the user' -or $ex.Message -match 'cancelled by the user') { return $true }
        $ex = $ex.InnerException
    }
    return $false
}

function Invoke-SetoRegSvr {
    param(
        [Parameter(Mandatory = $true)][string]$DllPath,
        [switch]$Unregister
    )
    if (-not (Test-Path -LiteralPath $DllPath)) { throw "DLL not found: $DllPath" }
    $DllPath = (Resolve-Path -LiteralPath $DllPath).Path
    if (-not $Unregister -and -not (Test-SetoPeX64 $DllPath)) {
        throw "seto_tsf.dll is not an x64 image. Refusing to register it: $DllPath"
    }
    if (-not $Unregister) {
        $runtime = Get-SetoNativeExe 'vcruntime140.dll'
        if (-not (Test-Path -LiteralPath $runtime)) {
            Write-Warning "64-bit VCRUNTIME140.dll is not at $runtime. regsvr32 may fail to load the DLL (exit 3). Install https://aka.ms/vs/17/release/vc_redist.x64.exe"
        }
    }

    if (Test-SetoAdmin) {
        $regsvr = Get-SetoNativeExe 'regsvr32.exe'
        if ($Unregister) {
            & $regsvr /s /u $DllPath
        } else {
            & $regsvr /s $DllPath
        }
        if ($null -eq $LASTEXITCODE) { return $null }
        return [int]$LASTEXITCODE
    }

    $cmd = Get-SetoNativeExe 'cmd.exe'
    $regsvr = Get-SetoRegSvr64
    $out = Join-Path $env:TEMP ("seto-regsvr32-" + [guid]::NewGuid().ToString('N') + '.txt')
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    $arg = Format-SetoElevatedRegSvrArg -RegSvr $regsvr -DllPath $DllPath -OutFile $out -Unregister:$Unregister
    try {
        $proc = Start-Process -FilePath $cmd -ArgumentList $arg -Verb RunAs -Wait -PassThru
    } catch {
        if (Test-UacCancelled $_) {
            throw 'UAC was cancelled. regsvr32 did not run.'
        }
        throw "Could not start elevated regsvr32: $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $out)) {
        $outer = $null
        if ($proc) { $outer = $proc.ExitCode }
        $outerText = if ($null -eq $outer) { 'unavailable' } else { [string]$outer }
        throw "Elevated regsvr32 did not write an exit code. Start-Process ExitCode: $outerText."
    }
    $text = (Get-Content -LiteralPath $out -Raw).Trim()
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    if ($text -notmatch '^\d+$') {
        throw "regsvr32 wrote an unreadable exit code: '$text'"
    }
    return [int]$text
}

function Register-SetoDll([string]$DllPath) {
    $code = Invoke-SetoRegSvr -DllPath $DllPath
    $state = Get-SetoRegistration
    $shown = if ($null -eq $code) { 'unavailable' } else { [string]$code }
    Write-Host "regsvr32 exit code: $shown"
    if ($state.Inproc) {
        Write-Host "InprocServer32: $($state.Inproc)"
    } else {
        Write-Host "InprocServer32: (missing) $($state.InprocKey)"
    }
    if ($state.ProfilePresent) {
        Write-Host "TIP profile: $($state.ProfileKey)"
    } else {
        Write-Host "TIP profile: missing $($state.ProfileKey)"
    }
    if (-not (Test-SetoPointsAt $state $DllPath)) {
        throw (Format-SetoRegSvrError -Code $code -State $state -DllPath $DllPath -Action 'register')
    }
    if ($null -ne $code -and $code -ne 0) {
        Write-Warning "regsvr32 exit code was $code, but the CLSID and TIP profile point at this DLL."
    }
    return $code
}

function Unregister-SetoDll([string]$DllPath) {
    $code = Invoke-SetoRegSvr -DllPath $DllPath -Unregister
    $state = Get-SetoRegistration
    $shown = if ($null -eq $code) { 'unavailable' } else { [string]$code }
    Write-Host "regsvr32 /u exit code: $shown"
    if (Test-SetoPointsAt $state $DllPath) {
        throw (Format-SetoRegSvrError -Code $code -State $state -DllPath $DllPath -Action 'unregister')
    }
    return $code
}
