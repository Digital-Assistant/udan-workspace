#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Windows entry point for the UDAN workspace command.

.DESCRIPTION
    Runs ./udan (the bash script) inside the Ubuntu WSL 2 distribution, where the
    stack is supported. On first use it installs the WSL toolchain (JDK 21,
    Node 22, jq) into the user's home with scripts/setup-wsl-toolchain.sh.

    The workspace lives on the Windows drive, so the path is translated to its
    /mnt/<drive>/... form before the command runs.

.EXAMPLE
    .\udan.ps1 bootstrap
    .\udan.ps1 up infra
    .\udan.ps1 doctor
    .\udan.ps1 status

.NOTES
    Requires: Windows 10/11, WSL 2 with an Ubuntu distribution, Docker Desktop
    with the WSL integration for that distribution enabled. See
    docs/windows-setup.md.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments
)

$ErrorActionPreference = 'Stop'

# Quote one value for a POSIX shell so spaces and quotes survive.
function ConvertTo-BashQuote([string] $Value) {
    return "'" + ($Value -replace "'", "'\''") + "'"
}

# D:\path\to\udan-workspace -> /mnt/d/path/to/udan-workspace
function ConvertTo-WslPath([string] $Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $rest = $Matches[2] -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    if ($full -match '^\\\\wsl(?:\.localhost|\$)\\([^\\]+)\\') {
        # A path already inside WSL (\\wsl$\Distro\...).
        $distro = $Matches[1]
        $rest = $full.Substring($full.IndexOf('\', 2) + 1) -replace '\\', '/'
        return "/$rest"
    }
    throw "Cannot map '$Path' to a WSL path. Run udan.ps1 from the workspace folder."
}

$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }

$distro = $env:UDAN_WSL_DISTRO
if ([string]::IsNullOrWhiteSpace($distro)) { $distro = 'Ubuntu' }

$wslRoot = ConvertTo-WslPath $root
$rootQ = ConvertTo-BashQuote $wslRoot
$setupQ = ConvertTo-BashQuote (ConvertTo-WslPath (Join-Path $root 'scripts/setup-wsl-toolchain.sh'))
$argLine = ($Arguments | ForEach-Object { ConvertTo-BashQuote $_ }) -join ' '

$command = @"
set -e
if [ ! -f "`$HOME/.config/udan/env.sh" ]; then
  echo '==> First run: installing the WSL toolchain (JDK 21, Node 22, jq).' >&2
  bash $setupQ
fi
. "`$HOME/.config/udan/env.sh"
cd $rootQ
exec ./udan $argLine
"@

& wsl.exe -d $distro -- bash -c $command
exit $LASTEXITCODE
