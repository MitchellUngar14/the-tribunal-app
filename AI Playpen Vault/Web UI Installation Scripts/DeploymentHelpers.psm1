Import-Module WebAdministration

function Log-InstallParams {
    param (
        [string]$LogFile,
        [string]$InstallerType,
        [string[]]$Arguments
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "`n[$timestamp] $InstallerType Installation Parameters:"
    Add-Content -Path $LogFile -Value ($Arguments -join " `n")
}

function Log-Info {
    param (
        [string]$Information
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path "D:\Scripts\Logs\RunDeployment.log" -Value "`n[$timestamp] $Information"
}

function Install-Client {
    param (
        [string]$EnvName,
        [string]$BaseInstallPath,
        [string]$SiteName,
        [string[]]$Arguments,
        [string]$LogPath
    )

    $clientFolder = Join-Path $BaseInstallPath "RatabasePB"

    if (Test-Path $clientFolder) {
        $msg = "[{0}] Skipping Client install for {1} - folder exists at {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $EnvName, $clientFolder
        Add-Content -Path $LogPath -Value "`n$msg"
        Write-Host $msg -ForegroundColor Yellow
        return
    }

    Log-InstallParams -LogFile "$LogPath.params.txt" -InstallerType "Client" -Arguments $Arguments

    Write-Host "Installing Client for $EnvName..." -ForegroundColor Cyan
    Write-Host "Set-ItemProperty 'IIS:\Sites\$($SiteName)' -Name physicalPath -Value $($clientFolder)" -ForegroundColor Green
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $clientFolder
    Write-VerboseLog "msiexec.exe $($Arguments)"
    Start-Process msiexec.exe $Arguments -Wait
}

function Install-API {
    param (
        [string]$EnvName,
        [string]$ClientFolder,
        [string]$SiteName,
        [string[]]$Arguments,
        [string]$LogPath
    )

    $x64Path = Join-Path $ClientFolder "RatabaseX64"

    if (Test-Path $ClientFolder) {
        $msg = "[{0}] Client exists continuing install ({1})" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $ClientFolder
        Write-Host $msg -ForegroundColor Green
    } else {
        $msg = "[{0}] Skipping API install for {1} - folder exists at {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $EnvName, $ClientFolder
        Add-Content -Path $LogPath -Value "`n$msg"
        Write-Host $msg -ForegroundColor Yellow
        return
    }

    if (Test-Path $x64Path) {
        $msg = "[{0}] Skipping API install for {1} - folder exists at {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $EnvName, $x64Path
        Add-Content -Path $LogPath -Value "`n$msg"
        Write-Host $msg -ForegroundColor Yellow
        return
    }

    Log-InstallParams -LogFile "$LogPath.params.txt" -InstallerType "API" -Arguments $Arguments
    Write-Host "Set-ItemProperty 'IIS:\Sites\$($SiteName)' -Name physicalPath -Value $($ClientFolder)" -ForegroundColor Green
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $ClientFolder
    Write-VerboseLog "msiexec.exe $($Arguments)"
    Start-Process msiexec.exe $Arguments -Wait
}

function Validate-InstallFolders {
    param (
        [string[]]$Paths
    )

    foreach ($path in $Paths) {
        if (-not (Test-Path $path)) {
            Write-Host "Creating folder: $path" -ForegroundColor DarkGray
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Write-InstallSummary {
    param (
        [string]$EnvName,
        [bool]$ClientInstalled,
        [bool]$ApiInstalled
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $summary = @"
[$timestamp] Installation Summary for $EnvName
---------------------------------------------
Client Installed: $ClientInstalled
API Installed:    $ApiInstalled
"@

    $summaryLog = "D:\Scripts\Logs\InstallSummary.log"
    Add-Content -Path $summaryLog -Value $summary
    Write-Host $summary -ForegroundColor Cyan
}

function Get-NextInstanceNumber {
    param (
        [string]$RegistryPath,
        [string]$VersionPrefix,
        [int]$MinValue = 1
    )

    if (-not (Test-Path $RegistryPath)) {
        Write-Host "$RegistryPath not found, using @MinValue"
        return $MinValue
    }

    $existing = Get-ChildItem -Path $RegistryPath -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSChildName -match "$VersionPrefix`Instance(`d+)$") {
            [int]$matches[1]
        }
    }

    if (-not $existing -or $existing.Count -eq 0) {
        Write-Host "Existing: $existing returning $MinValue"
        return $MinValue
    }

    $max = ($existing | Measure-Object -Maximum).Maximum

    return [Math]::Max($max + 1, $MinValue)
}


function Get-NextSharedAPIInstanceNumber {
    param (
        [string]$VersionPrefix = "v9.4.3.0_"
    )

    $paths = @(
        "HKLM:\SOFTWARE\CGI Group, Inc.\Ratabase Product Builder API\x64",
        "HKLM:\SOFTWARE\CGI Group, Inc.\Ratabase Product Builder API\x86"
    )

    $existingInstances = @()

    foreach ($path in $paths) {
        if (Test-Path $path) {
            $existing = Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.PSChildName -match "$VersionPrefix`Instance(`d+)$") {
                    [int]$matches[1]
                }
            }
            $existingInstances += $existing
        }
    }

    if ($existingInstances.Count -eq 0) {
        return 1
    }

    return ($existingInstances | Measure-Object -Maximum).Maximum + 1
}

function Update-RuntimeConfig {
    param (
        [string]$FilePath,
        [string]$ApiUrl,
        [string]$ApiX86Url,
        [int]$SessionTimeOut,
        [int]$SessionIdleLogout
    )

    if (-not (Test-Path $FilePath)) {
        Write-Host "runtime-config.js not found at $FilePath" -ForegroundColor Red
        return
    }

    $content = Get-Content -LiteralPath $FilePath -Raw

    # Patterns mapped to replacements
    $patterns = @{
        "(?<=apiUrl:\s*')[^']*"           = $ApiUrl
        "(?<=apix86Url:\s*')[^']*"        = $ApiX86Url
        "(?<=SessionTimeOut:\s*)\d+"      = $SessionTimeOut.ToString()
        "(?<=SessionIdleLogout:\s*)\d+"   = $SessionIdleLogout.ToString()
    }

    foreach ($pat in $patterns.Keys) {
        $content = [regex]::Replace($content, $pat, { $patterns[$pat] })
    }

    Set-Content -LiteralPath $FilePath -Value $content -Encoding UTF8
    Write-Host "Updated runtime-config.js at $FilePath" -ForegroundColor Green
}


function Update-AppSettingsJson {
    param (
        [string]$FilePath,
        [string]$WebAppHost,
        [string]$MailHost,
        [string]$FromEmail,
        [string]$Product,  # e.g., "Test"
        [string]$RollingInterval = "Day",
        [int]$RetainFileCount = 30
    )

    if (-not (Test-Path $FilePath)) {
        Write-Warning "appsettings.json not found at $FilePath"
        return
    }

    $json = Get-Content -Raw -Path $FilePath | ConvertFrom-Json

    # Base folder for redirection
    $redirectBase = "D:\CGI\Ratabase${Product}PBAPI"

    # Update appsettings values
    $json.AppSettings.WebAppHost = $WebAppHost
    $json.Mailing.Host = $MailHost
    $json.Mailing.FromEmail = $FromEmail

    # File redirection updates
    $json.AppSettings.FileRedirection.DocumentFolderPath      = "$redirectBase\Documents\"
    $json.AppSettings.FileRedirection.UploadFolderPath        = "$redirectBase\FileUpload\"
    $json.AppSettings.FileRedirection.DIFileUploadFolderPath  = "$redirectBase\FileUpload\TrnFileUpload\"

    # Update log path and rotation settings
    foreach ($writeTo in $json.Serilog.WriteTo) {
        if ($writeTo.Name -eq "File" -and $writeTo.Args) {
            $writeTo.Args.rollingInterval = $RollingInterval
            $writeTo.Args.retainedFileCountLimit = $RetainFileCount
            $writeTo.Args.path = "$redirectBase\Log\.log"
        }
    }

    # Write updated JSON
    $json | ConvertTo-Json -Depth 10 | Set-Content -Path $FilePath -Encoding UTF8
    Write-Host "Updated appsettings.json at $FilePath" -ForegroundColor Green
}

function Update-WebConfig {
    param (
        [string]$TargetPath
    )

    $newContent = @"
<?xml version="1.0"?>
<configuration>
 <location path="." inheritInChildApplications="false">
  <system.webServer>
   <rewrite>
    <rules>
     <rule name="React Routes" stopProcessing="true">
     <match url=".*" />
      <conditions logicalGrouping="MatchAll">
       <add input="{REQUEST_FILENAME}" matchType="IsFile" negate="true" />
       <add input="{REQUEST_FILENAME}" matchType="IsDirectory" negate="true" />
       <add input="{REQUEST_URI}" pattern="^/(api)" negate="true" />
      </conditions>
      <action type="Rewrite" url="/" />
     </rule>
    </rules>
   </rewrite>
  </system.webServer>
 </location>
</configuration>
"@

    try {
        Set-Content -Path $TargetPath -Value $newContent -Encoding UTF8 -Force
        Write-Host "Updated web.config at $TargetPath" -ForegroundColor Green
    } catch {
        Write-Host "Failed to update web.config at $($TargetPath): $_" -ForegroundColor Red
    }
}


function Write-VerboseLog {
    param (
        [string]$Message
    )
    if ($Global:VerboseLogging) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Host "[VERBOSE $timestamp] $Message" -ForegroundColor DarkGray
    }
}

function Stop-AppComponents {
    param (
        [string]$AppPool64,
        [string]$AppPool32,
        [string]$SiteName
    )

    Write-Host "Stopping App Pools and Site..." -ForegroundColor Yellow

    if ($AppPool64 -and (Test-Path "IIS:\AppPools\$AppPool64")) {
        $status = (Get-WebAppPoolState $AppPool64).Value
        if ($status -ne "Stopped") {
            Stop-WebAppPool $AppPool64
            Write-Host "Stopped AppPool: $AppPool64"
        } else {
            Write-Host "AppPool $AppPool64 already stopped."
        }
    }

    if ($AppPool32 -and (Test-Path "IIS:\AppPools\$AppPool32")) {
        $status = (Get-WebAppPoolState $AppPool32).Value
        if ($status -ne "Stopped") {
            Stop-WebAppPool $AppPool32
            Write-Host "Stopped AppPool: $AppPool32"
        } else {
            Write-Host "AppPool $AppPool32 already stopped."
        }
    }


    if ($SiteName -and (Test-Path "IIS:\AppPools\$SiteName")) {
        $status = (Get-WebAppPoolState $SiteName).Value
        if ($status -ne "Stopped") {
            Stop-WebAppPool $SiteName
            Write-Host "Stopped AppPool: $SiteName"
        } else {
            Write-Host "AppPool $SiteName already stopped."
        }
    }

    if ($SiteName -and (Test-Path "IIS:\Sites\$SiteName")) {
        $status = (Get-WebsiteState -Name $SiteName).Value
        if ($status -ne "Stopped") {
            Stop-Website $SiteName
            Write-Host "Stopped Site: $SiteName"
        } else {
            Write-Host "Site $SiteName already stopped."
        }
    }
}

function Start-AppComponents {
    param (
        [string]$AppPool64,
        [string]$AppPool32,
        [string]$SiteName
    )

    Write-Host "Starting App Pools and Site..." -ForegroundColor Green

    if ($AppPool64 -and (Test-Path "IIS:\AppPools\$AppPool64")) {
        $status = (Get-WebAppPoolState $AppPool64).Value
        if ($status -ne "Started") {
            Start-WebAppPool $AppPool64
            Write-Host "Started AppPool: $AppPool64"
        } else {
            Write-Host "AppPool $AppPool64 already started."
        }
    }

    if ($AppPool32 -and (Test-Path "IIS:\AppPools\$AppPool32")) {
        $status = (Get-WebAppPoolState $AppPool32).Value
        if ($status -ne "Started") {
            Start-WebAppPool $AppPool32
            Write-Host "Started AppPool: $AppPool32"
        } else {
            Write-Host "AppPool $AppPool32 already started."
        }
    }

    if ($SiteName -and (Test-Path "IIS:\AppPools\$SiteName")) {
        $status = (Get-WebAppPoolState $SiteName).Value
        if ($status -ne "Started") {
            Start-WebAppPool $SiteName
            Write-Host "Started AppPool: $SiteName"
        } else {
            Write-Host "AppPool $SiteName already started."
        }
    }

    if ($SiteName -and (Test-Path "IIS:\Sites\$SiteName")) {
        $status = (Get-WebsiteState -Name $SiteName).Value
        if ($status -ne "Started") {
            Start-Website $SiteName
            Write-Host "Started Site: $SiteName"
        } else {
            Write-Host "Site $SiteName already started."
        }
    }
}
