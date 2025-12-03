<#
.SYNOPSIS
  Build API and Client uninstall paths from Environments\*.psd1 and call UninstallEnvironments.ps1

.DESCRIPTION
  - API paths (default):  Api.InstallLocation64 + "\" + Api.WebAppName64  (EXCLUDES x86)
    * You can force-include x86 via -IncludeX86 (Api.InstallLocation32 + "\" + Api.WebAppName32)
  - Client paths: BasePath + "\RatabasePB"
  - De-duplicates paths, preserves first-seen order
  - Filters by env Name via -OnlyEnvs if provided
  - Calls sibling UninstallEnvironments.ps1 (APIs first, then Clients)

.PARAMETER OnlyEnvs
  Optional list of environment Name values to include (matches the 'Name' field in the psd1).

.PARAMETER EnvsFolder
  Path to the Environments folder. Defaults to ".\Environments" relative to this script.

.PARAMETER IncludeX86
  Include 32-bit API paths (RatabaseX86). Default is to EXCLUDE them.

.PARAMETER Force
  Pass-through to UninstallEnvironments.ps1 to skip interactive prompts.

.PARAMETER WhatIf
  Preview actions (pass-through to UninstallEnvironments.ps1).
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string[]]$OnlyEnvs,
    [string]$EnvsFolder = (Join-Path -Path $PSScriptRoot -ChildPath 'Environments'),
    [switch]$IncludeX86,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-EnvPsd1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Environment file not found: $Path" }
    try { return Import-PowerShellDataFile -Path $Path }
    catch { throw "Failed to import '$Path' as a PowerShell data file. $_" }
}

function Add-IfPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Seen,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ArrayList]$Bag,
        [Parameter(Mandatory)][string]$PathCandidate
    )
    $full = [System.IO.Path]::GetFullPath($PathCandidate.Trim())
    if ($Seen.Add($full)) { [void]$Bag.Add($full) }
}

# Collect environment files
if (-not (Test-Path -LiteralPath $EnvsFolder)) { throw "Environments folder not found: $EnvsFolder" }
$envFiles = Get-ChildItem -LiteralPath $EnvsFolder -Filter '*.psd1' -File | Sort-Object Name
if ($envFiles.Count -eq 0) { throw "No *.psd1 files found in: $EnvsFolder" }

$apiPaths    = New-Object System.Collections.ArrayList
$clientPaths = New-Object System.Collections.ArrayList
$seenApi     = New-Object 'System.Collections.Generic.HashSet[string]'
$seenClient  = New-Object 'System.Collections.Generic.HashSet[string]'

Write-Host "Scanning environment files in: $EnvsFolder"

foreach ($file in $envFiles) {
    $envData = Import-EnvPsd1 -Path $file.FullName

    # Optional filter by Name
    if ($OnlyEnvs -and $envData.ContainsKey('Name')) {
        if ($OnlyEnvs -notcontains $envData.Name) { continue }
    } elseif ($OnlyEnvs) { continue }

    if (-not $envData.ContainsKey('BasePath') -or -not $envData.ContainsKey('Api')) {
        Write-Warning "Skipping '$($file.Name)': missing BasePath or Api section."
        continue
    }

    $basePath = [string]$envData.BasePath
    $api      = $envData.Api

    # Client path: BasePath\RatabasePB
    $clientRoot = Join-Path -Path $basePath -ChildPath 'RatabasePB'
    Add-IfPresent -Seen $seenClient -Bag $clientPaths -PathCandidate $clientRoot

    # --- API x64 (always included)
    if ($api.ContainsKey('InstallLocation64') -and $api.ContainsKey('WebAppName64')) {
        $api64 = Join-Path -Path ([string]$api.InstallLocation64) -ChildPath ([string]$api.WebAppName64)
        Add-IfPresent -Seen $seenApi -Bag $apiPaths -PathCandidate $api64
    } else {
        Write-Warning "Env '$($envData.Name)': missing InstallLocation64/WebAppName64."
    }

    # --- API x86 (OPTIONAL): include only if -IncludeX86 was passed
    if ($IncludeX86) {
        if ($api.ContainsKey('InstallLocation32') -and $api.ContainsKey('WebAppName32')) {
            $api32 = Join-Path -Path ([string]$api.InstallLocation32) -ChildPath ([string]$api.WebAppName32)
            Add-IfPresent -Seen $seenApi -Bag $apiPaths -PathCandidate $api32
        } elseif ($api.ContainsKey('InstallLocation32') -or $api.ContainsKey('WebAppName32')) {
            Write-Warning "Env '$($envData.Name)': incomplete x86 config (InstallLocation32/WebAppName32); x86 not added."
        }
    }
}

# Final safety filter: if someone mistakenly injected an x86 path, drop it unless -IncludeX86
if (-not $IncludeX86 -and $apiPaths.Count -gt 0) {
    $kept = New-Object System.Collections.ArrayList
    $seenKeep = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in $apiPaths) {
        # Exclude obvious x86 folder names
        if ($p -match '\RatabaseX86(\)?$' -or $p -match '\x86(\)?$') { continue }
        if ($seenKeep.Add($p)) { [void]$kept.Add($p) }
    }
    $apiPaths = $kept
}

Write-Host ""
Write-Host "Discovered API paths (x86 excluded by default):"
if ($apiPaths.Count -eq 0) { Write-Host "  (none)" } else { $apiPaths | ForEach-Object { Write-Host "  - $_" } }
Write-Host ""
Write-Host "Discovered Client paths:"
if ($clientPaths.Count -eq 0) { Write-Host "  (none)" } else { $clientPaths | ForEach-Object { Write-Host "  - $_" } }
Write-Host ""

$uninstaller = Join-Path -Path $PSScriptRoot -ChildPath 'UninstallEnvironments.ps1'
if (-not (Test-Path -LiteralPath $uninstaller)) {
    throw "Cannot find UninstallEnvironments.ps1 next to this script: $uninstaller"
}

$bind = @{
    ApiPaths    = @($apiPaths)
    ClientPaths = @($clientPaths)
    Force       = $Force
}

Write-Host "Invoking: $uninstaller"
if ($PSCmdlet.ShouldProcess("Uninstall operations", "Execute")) {
    if ($PSBoundParameters.ContainsKey('WhatIf')) {
        & $uninstaller @bind -WhatIf
    } else {
        & $uninstaller @bind
    }
}
