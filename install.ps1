#Requires -Version 5.1
<#
.SYNOPSIS
    Installs ctx.ps1 for PowerShell.

.DESCRIPTION
    Copies ctx.ps1 to $HOME\.config\ctx\ctx.ps1 and idempotently adds a
    dot-source line to your PowerShell profile ($PROFILE) if not already
    present.

.EXAMPLE
    .\install.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $scriptDir 'ctx.ps1'
$destDir = Join-Path $HOME '.config\ctx'
$dest = Join-Path $destDir 'ctx.ps1'

if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
    Write-Error "install.ps1: error: could not find ctx.ps1 next to this script ($src)"
    exit 1
}

New-Item -ItemType Directory -Path $destDir -Force | Out-Null
Copy-Item -LiteralPath $src -Destination $dest -Force

Write-Host "Installed ctx.ps1 to $dest"

$sourceLine = ". `"$dest`""

if (-not (Test-Path -LiteralPath $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$profileContent = Get-Content -LiteralPath $PROFILE -Raw -ErrorAction SilentlyContinue
if ($profileContent -and $profileContent.Contains($dest)) {
    Write-Host "$PROFILE already sources ctx.ps1, skipping."
} else {
    Add-Content -LiteralPath $PROFILE -Value "`n# Load ctx - portable AI context switcher`n$sourceLine"
    Write-Host "Added ctx.ps1 sourcing to $PROFILE"
}

Write-Host ""
Write-Host "Installation complete."
Write-Host ""
Write-Host "Restart PowerShell, or run:"
Write-Host "    . `"$dest`""
Write-Host ""
Write-Host "Then try:"
Write-Host "    ctx --help"
Write-Host "    ctx review dotnet"
Write-Host "    ctx current"
Write-Host "    ctx clear"
Write-Host ""
Write-Host 'Set $env:AI_CTX_PROFILES_CONFIG_ROOT if your ai-config directory is not at $HOME\work\ai-config:'
Write-Host '    $env:AI_CTX_PROFILES_CONFIG_ROOT = "C:\path\to\ai-config"'
Write-Host ""
Write-Host "To show the active context in your Oh My Posh prompt, add a segment"
Write-Host "reading `$env:AI_CTX_PROFILES to your Oh My Posh theme (see README.md)."
