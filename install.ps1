<#
    AudiotrackID installer

    Install / update (no admin rights needed):
        irm https://raw.githubusercontent.com/nocturneop15/AudiotrackID/main/install.ps1 | iex

    With options:
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/nocturneop15/AudiotrackID/main/install.ps1))) -InstallDir 'D:\Tools\AudiotrackID' -Setup

    Options can also be given as environment variables for the plain "| iex" form:
        AUDIOTRACKID_DIR, AUDIOTRACKID_REF, AUDIOTRACKID_SETUP=1, AUDIOTRACKID_NOPATH=1,
        AUDIOTRACKID_NOSENDTO=1, AUDIOTRACKID_UNINSTALL=1

    -InstallDir   target folder (default %LOCALAPPDATA%\AudiotrackID)
    -Ref          branch or tag to install (default main)
    -Setup        also download all tools and models now (~1.4 GB) instead of on first run
    -NoPath       don't add the 'AudiotrackID' command to the user PATH
    -NoSendTo     don't add 'AudiotrackID' to the Explorer "Send to" menu
    -Uninstall    remove the installation, PATH entry and Send to shortcut
#>
param(
    [string]$InstallDir = $(if ($env:AUDIOTRACKID_DIR) { $env:AUDIOTRACKID_DIR } else { Join-Path $env:LOCALAPPDATA 'AudiotrackID' }),
    [string]$Ref = $(if ($env:AUDIOTRACKID_REF) { $env:AUDIOTRACKID_REF } else { 'main' }),
    [switch]$Setup = [bool]$env:AUDIOTRACKID_SETUP,
    [switch]$NoPath = [bool]$env:AUDIOTRACKID_NOPATH,
    [switch]$NoSendTo = [bool]$env:AUDIOTRACKID_NOSENDTO,
    [switch]$Uninstall = [bool]$env:AUDIOTRACKID_UNINSTALL
)

# Run in a child scope so nothing (preferences, variables) leaks into the caller's session with "| iex".
& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$Repo = 'nocturneop15/AudiotrackID'
$AppFiles = @('AudiotrackID.ps1', 'AudiotrackID.cmd', 'README.md')
$BinDir = Join-Path $InstallDir 'bin'
$SendToLink = Join-Path ([Environment]::GetFolderPath('SendTo')) 'AudiotrackID.lnk'

function Get-UserPath { $p = [Environment]::GetEnvironmentVariable('Path', 'User'); if ($p) { $p } else { '' } }
function Test-InPath([string]$Path, [string]$Dir) {
    foreach ($e in $Path.Split(';')) { if ($e.TrimEnd('\') -ieq $Dir.TrimEnd('\')) { return $true } }
    return $false
}

if ($Uninstall) {
    Write-Host "Uninstalling AudiotrackID from $InstallDir ..." -ForegroundColor Cyan
    $p = Get-UserPath
    if (Test-InPath $p $BinDir) {
        $new = ($p.Split(';') | Where-Object { $_ -and $_.TrimEnd('\') -ine $BinDir.TrimEnd('\') }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
        Write-Host '  removed from user PATH'
    }
    if (Test-Path -LiteralPath $SendToLink) { Remove-Item -LiteralPath $SendToLink -Force; Write-Host '  removed Send to shortcut' }
    if (Test-Path -LiteralPath (Join-Path $InstallDir 'AudiotrackID.ps1')) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Host "  deleted $InstallDir (including downloaded tools)"
    }
    Write-Host 'Done.' -ForegroundColor Green
    return
}

Write-Host "Installing AudiotrackID ($Ref) to $InstallDir ..." -ForegroundColor Cyan
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('atid-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    $zip = Join-Path $tmp 'src.zip'
    $kind = if ($Ref -match '^v?\d+(\.\d+)*$') { 'tags' } else { 'heads' }
    Invoke-WebRequest -UseBasicParsing "https://github.com/$Repo/archive/refs/$kind/$Ref.zip" -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
    if (-not $src -or -not (Test-Path -LiteralPath (Join-Path $src.FullName 'AudiotrackID.ps1'))) { throw 'Downloaded archive does not contain AudiotrackID.ps1' }

    # app files (an existing tools\ folder with downloaded binaries/models is kept)
    New-Item -ItemType Directory -Force $InstallDir, $BinDir | Out-Null
    foreach ($f in $AppFiles) { Copy-Item -LiteralPath (Join-Path $src.FullName $f) -Destination $InstallDir -Force }
    Get-ChildItem -LiteralPath $InstallDir -File | Unblock-File -ErrorAction SilentlyContinue

    # PATH shim: only bin\ goes on PATH, so PowerShell runs the .cmd (execution-policy safe), not the .ps1
    $shim = "@echo off`r`n""%~dp0..\AudiotrackID.cmd"" %*`r`n"
    [IO.File]::WriteAllText((Join-Path $BinDir 'AudiotrackID.cmd'), $shim, [Text.Encoding]::ASCII)
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

if (-not $NoPath) {
    $p = Get-UserPath
    if (-not (Test-InPath $p $BinDir)) {
        [Environment]::SetEnvironmentVariable('Path', (($p.TrimEnd(';') + ";$BinDir").TrimStart(';')), 'User')
        Write-Host "  added $BinDir to user PATH"
    }
    if (-not (Test-InPath $env:Path $BinDir)) { $env:Path = "$env:Path;$BinDir" }   # usable in this session right away
}

if (-not $NoSendTo) {
    try {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($SendToLink)
        $lnk.TargetPath = Join-Path $InstallDir 'AudiotrackID.cmd'
        $lnk.WorkingDirectory = $InstallDir
        $lnk.Description = 'Identify and tag audio track languages'
        $lnk.Save()
        Write-Host '  added Explorer "Send to > AudiotrackID"'
    }
    catch { Write-Warning "Could not create Send to shortcut: $($_.Exception.Message)" }
}

if ($Setup) {
    Write-Host 'Downloading tools and models (~1.4 GB) ...' -ForegroundColor Cyan
    & (Join-Path $InstallDir 'AudiotrackID.cmd') -Setup
}

Write-Host ''
Write-Host 'AudiotrackID installed.' -ForegroundColor Green
Write-Host '  AudiotrackID "D:\Movies" -DryRun     # from any terminal (open a new one if the command is not found)'
Write-Host '  Explorer: right-click a folder > Send to > AudiotrackID'
if (-not $Setup) { Write-Host '  Tools and models (~1.4 GB) are downloaded automatically on first run.' }
Write-Host '  Update: run the install command again.'
Write-Host '  Uninstall: & ([scriptblock]::Create((irm https://raw.githubusercontent.com/nocturneop15/AudiotrackID/main/install.ps1))) -Uninstall'
}
