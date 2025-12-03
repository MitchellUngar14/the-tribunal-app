<#
.SYNOPSIS
  Uninstall multiple products by EXACT InstallLocation, uninstalling all APIs first, then all Clients.

.DESCRIPTION
  Searches HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall (both 64/32-bit views)
  for entries whose InstallLocation exactly matches each provided path (with or without trailing '\').
  Executes each entry's UninstallString (e.g., msiexec /x {GUID} …). Avoids Win32_Product/wmic.

.PARAMETER ApiPaths
  One or more exact InstallLocation paths that correspond to API installations.

.PARAMETER ClientPaths
  One or more exact InstallLocation paths that correspond to Client installations.

.PARAMETER Force
  Skip Y/N confirmation prompts (unattended).

.PARAMETER WhatIf
  Preview actions without executing them.

.EXAMPLES
  .\UninstallEnvironments.ps1 `
    -ApiPaths    'C:\inetpub\wwwroot\AppA\ApiX64','D:\Sites\AppB\ApiX64' `
    -ClientPaths 'C:\inetpub\wwwroot\AppA\ClientX64','D:\Sites\AppB\ClientX64'

  # Unattended:
  .\UninstallEnvironments.ps1 -ApiPaths $apiPaths -ClientPaths $clientPaths -Force
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ApiPaths,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ClientPaths,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-InstallPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path.Trim())
    $withSlash    = if ($full.EndsWith('\')) { $full } else { "$full\" }
    $withoutSlash = $full.TrimEnd('\')

    [PSCustomObject] @{
        WithSlash    = $withSlash
        WithoutSlash = $withoutSlash
        Display      = $full
    }
}

function Get-UninstallEntriesByExactInstallLocation {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$InstallPath
    )

    $norm = Normalize-InstallPath -Path $InstallPath

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $matches = @()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($sub in Get-ChildItem $root) {
            try {
                $p = Get-ItemProperty $sub.PSPath -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($p.InstallLocation)) { continue }

                # EXACT match, allowing both with and without trailing '\'
                if ($p.InstallLocation -eq $norm.WithSlash -or $p.InstallLocation -eq $norm.WithoutSlash) {
                    $matches += [PSCustomObject] @{
                        DisplayName     = $p.DisplayName
                        Publisher       = $p.Publisher
                        DisplayVersion  = $p.DisplayVersion
                        InstallLocation = $p.InstallLocation
                        UninstallString = $p.UninstallString
                        PSPath          = $sub.PSPath
                    }
                }
            } catch {
                # ignore unreadable keys
            }
        }
    }

    return @($matches)
}

function Invoke-UninstallEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Entry,
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($Entry.UninstallString)) {
        Write-Warning "No UninstallString for '$($Entry.DisplayName)' at '$($Entry.InstallLocation)'. Skipping."
        return
    }

    $cmdLine = $Entry.UninstallString.Trim()

    # Convert MSI install to uninstall if needed
    if ($cmdLine -match 'msiexec(\.exe)?\s+/I\s+\{[0-9A-Fa-f\-]{36}\}') {
        $cmdLine = $cmdLine -replace '/I', '/X'
    }

    # Split exe + args
    if ($cmdLine.StartsWith('"')) {
        $end = $cmdLine.IndexOf('"', 1)
        $exe  = $cmdLine.Substring(1, $end - 1)
        $args = $cmdLine.Substring($end + 1).Trim()
    } else {
        $sp = $cmdLine.IndexOf(' ')
        if ($sp -gt 0) {
            $exe  = $cmdLine.Substring(0, $sp)
            $args = $cmdLine.Substring($sp + 1).Trim()
        } else {
            $exe  = $cmdLine
            $args = ''
        }
    }

    $display = if ($Entry.DisplayName) { $Entry.DisplayName } else { "(unknown product)" }
    $target  = "$display $($Entry.DisplayVersion) — $($Entry.InstallLocation)"

    if ($PSCmdlet.ShouldProcess($target, "Uninstall")) {
        if (-not $Force) {
            $ans = Read-Host "Uninstall '$display'? (Y/N)"
            if ($ans -notmatch '^(Y|y)$') {
                Write-Host "Skipped '$display'."
                return
            }
        }

        Write-Host "Executing: `"$exe`" $args"
        $p = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru
        if ($p.ExitCode -eq 0) {
            Write-Host "Uninstalled '$display' successfully."
        } else {
            Write-Warning "Uninstall of '$display' returned exit code $($p.ExitCode)."
        }
    }
}

function Uninstall-SetByPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [switch]$Force
    )

    # De-dup while preserving order
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($raw in $Paths) {
        $norm = (Normalize-InstallPath $raw).Display
        if ($seen.Add($norm)) {
            $entries = @( Get-UninstallEntriesByExactInstallLocation -InstallPath $norm )
            if (-not $entries -or $entries.Count -eq 0) {
                Write-Warning "No installed product with InstallLocation EXACTLY '$norm'."
                continue
            }

            foreach ($e in $entries) {
                Write-Host "Found: $($e.DisplayName) $($e.DisplayVersion) at $($e.InstallLocation)"
                Invoke-UninstallEntry -Entry $e -Force:$Force
            }
        }
    }
}

# ---------------------- MAIN FLOW ----------------------

Write-Host "=== Uninstall by EXACT InstallLocation (APIs first, then Clients) ==="

# 1) APIs first
Write-Host "`n[1/2] APIs:"
Uninstall-SetByPaths -Paths $ApiPaths -Force:$Force

# 2) Clients second
Write-Host "`n[2/2] Clients:"
Uninstall-SetByPaths -Paths $ClientPaths -Force:$Force

Write-Host "`nAll done."
