param (
    [switch]$v
)

Import-Module WebAdministration
Import-Module "D:\Scripts\DeploymentHelpers.psm1" -Force

$Global:VerboseLogging = $v.IsPresent

# Load Global Variables
$GlobalVars = Import-PowerShellDataFile -Path "D:\Scripts\GlobalVariables.psd1"

# Get all environment config files
$envFiles = Get-ChildItem -Path "D:\Scripts\Environments" -Filter *.psd1

foreach ($file in $envFiles) {
    Write-Host "`n--- Processing $($file.BaseName) ---"
    $env = Import-PowerShellDataFile -Path $file.FullName

    $clientInstallPath = $env.BasePath
    $clientFolder = Join-Path $clientInstallPath $GlobalVars.WebAppName
    $api = $env.Api

    Validate-InstallFolders -Paths @(
        "D:\Scripts\Logs",
        (Split-Path $env.Client.LogPath),
        (Split-Path $api.LogPath),
        $api.LogFolder,
        $api.DocFolder,
        $api.PerFolder,
        $env.BasePath
    )

    # Stop IIS components
    Stop-AppComponents `
        -AppPool64 $api.AppPoolName64 `
        -AppPool32 $api.AppPoolName32 `
        -SiteName $env.Client.HostUrl


    $clientInstanceNumber = Get-NextInstanceNumber -RegistryPath "HKLM:\SOFTWARE\CGI Group, Inc.\Ratabase Product Builder\Product Builder" -VersionPrefix "v$($GlobalVars.Version)_" -MinValue 1
    $clientInstanceId = ":Instance$clientInstanceNumber"
    Write-VerboseLog "Client Transforms: $clientInstanceId"

    ### CLIENT INSTALL ###
    $clientArgs = @(
        "/i", "`"$($GlobalVars.MsiPathClient)`"",
        "ENDUSERLICENSEAGREEMENT=yes",
        "INSTALLLOCATIONUI=$clientInstallPath",
        "WEBSITE_NAME_UI=$($env.Client.HostUrl)",
        "WEB_APP_NAME_UI=$($GlobalVars.WebAppName)",
        "APP_POOL_NAME_UI=$($env.Client.AppPoolName)",
        "INSTALLACTION=INSTALLNEW",
        "LOCATION=$($env.BasePath)",
        "UI_DATASET=$($env.Client.DatasetName)",
        "AUTOCLOSETIME=3000",
        "CLIENTNAME=""$($env.Client.ClientName)""",
        "CLIENTEMAIL=$($env.Client.ClientEmail)",
        "ITEMSPERPAGE=10",
        "TABLEEDITORPAGINATION=100",
        "RATABASEPBHOSTURL=$($env.Client.HostUrl)",
        "GRIDLICENSEKEY=$($env.Client.GridLicense)",
        "TIMEOUT=130",
        "MSINEWINSTANCE=1",
        "TRANSFORMS=$clientInstanceId",
        "VersionSelected=$($GlobalVars.Version)",
        "/quiet", "/passive", "/l*vx", "`"$($env.Client.LogPath)`""
    )

    $clientInstalled = $false
    if (-not (Test-Path (Join-Path $clientInstallPath $GlobalVars.WebAppName))) {
        Install-Client -EnvName $env.Name -BaseInstallPath $env.BasePath -SiteName $env.Client.HostUrl -Arguments $clientArgs -LogPath $env.Client.LogPath
        $clientInstalled = $true
    }

    Write-Host "Installing API for $($env.Name)..." -ForegroundColor Cyan

    $apiInstanceNumber = Get-NextSharedAPIInstanceNumber -VersionPrefix "v$($GlobalVars.Version)_"
    $apiTransform = ":Instance$apiInstanceNumber"
    Log-Info -Information "Assigning API Instance Number $($apiInstanceNumber) to Env $($env.Name)"
    Write-VerboseLog "API Transforms: $($apiTransform)"

    ### API INSTALL ###
    $apiArgs = @(
        "/i", "`"$($GlobalVars.MsiPathApi)`"",
        "ENDUSERLICENSEAGREEMENT=yes",
        "INSTALLLOCATION=$clientFolder\RatabaseX64",
        "INSTALLOCATION32=$clientFolder\RatabaseX86",
        "WEBSITE_NAME=$($env.Client.HostUrl)",
        "WEB_APP_NAME=$($api.WebAppName64)",
        "APP_POOL_NAME=$($api.AppPoolName64)",
        "WEB_APP_NAME32=$($api.WebAppName32)",
        "APP_POOL_NAME32=$($api.AppPoolName32)",
        "INSTALLACTION=INSTALLNEW",
        "LOCATION=$clientFolder",
        "TOKEN_EXPIRY=99999",
        "LOGFOLDERDIR=$($api.LogFolder)",
        "LOG_FILE_SIZE=$($api.LogSize)",
        "DOC_UPLOAD_SIZE=2097152000",
        "DOCFOLDERDIR=$($api.DocFolder)",
        "PERFOLDERDIR=$($api.PerFolder)",
        "DATASETNAME=$($api.DB.Dataset)",
        "DBAUTHENTICATION=SqlServer",
        "DBSERVERNAME=$($api.DB.ServerName)",
        "DBUSERNAME=$($api.DB.Username)",
        "DBPASSWORD=$($api.DB.Password)",
        "DEVDBNAME=$($api.DB.Dev)",
        "TESTDBNAME=$($api.DB.Test)",
        "PERSONALDBNAME=$($api.DB.Personal)",
        "IMPORTDBNAME=$($api.DB.Import)",
        "ODDBNAME=`"`"",
        "TIMEOUT=130",
        "MSINEWINSTANCE=1",
        "TRANSFORMS=$apiTransform",
        "VersionSelected=$($GlobalVars.Version)",
        "/quiet", "/passive", "/l*vx", "`"$($api.LogPath)`""
    )

    $apiInstalled = $false
    if (-not (Test-Path (Join-Path $clientFolder "RatabaseX64"))) {
        Install-API -EnvName $env.Name -ClientFolder $clientFolder -SiteName $env.Client.HostUrl -Arguments $apiArgs -LogPath $api.LogPath
        $apiInstalled = $true
    }

    # Write summary
    Write-InstallSummary -EnvName $env.Name -ClientInstalled $clientInstalled -ApiInstalled $apiInstalled


    Write-Host "Updating Config Files For Environment" -ForegroundColor Cyan
    # Update runtime config file
    $runtimeConfigPath = Join-Path $clientFolder "runtime-config.js"
    Write-VerboseLog "Runtime Config Path: " $runtimeConfigPath
    Write-VerboseLog "Update-RuntimeConfig -FilePath $runtimeConfigPath `
                          -ApiUrl 'https://$($env.Client.HostUrl)/RatabaseX64/api' `
                          -ApiX86Url 'https://$($env.Client.HostUrl)/RatabaseX86/api' `
                          -SessionTimeOut 480 `
                          -SessionIdleLogout 240"

    Update-RuntimeConfig -FilePath $runtimeConfigPath `
                         -ApiUrl "https://$($env.Client.HostUrl)/RatabaseX64/api" `
                         -ApiX86Url "https://$($env.Client.HostUrl)/RatabaseX86/api" `
                         -SessionTimeOut 480 `
                         -SessionIdleLogout 240


    # Paths to appsettings.json
    $appSettingsX64 = Join-Path $clientFolder "RatabaseX64\appsettings.json"
    $appSettingsX86 = Join-Path $clientFolder "RatabaseX86\appsettings.json"

    # Values from environment
    $webAppHost = "https://$($env.Client.HostUrl)"
    $mailHost = "smtpin.lmig.com"
    $fromEmail = "ratingconsultants @libertymutual.com"
    $product = $env.Name  # Ex: "Test"

    Write-VerboseLog "Update-AppSettingsJson -FilePath $($appSettingsX64) `
                       -WebAppHost $($webAppHost) `
                       -MailHost $($mailHost) `
                       -FromEmail $($fromEmail) `
                       -Product $($product) `
                       -RollingInterval 'Day' `
                       -RetainFileCount 30"

    Update-AppSettingsJson -FilePath $appSettingsX64 `
                           -WebAppHost $webAppHost `
                           -MailHost $mailHost `
                           -FromEmail $fromEmail `
                           -Product $product `
                           -RollingInterval "Day" `
                           -RetainFileCount 30

    Write-VerboseLog "Update-AppSettingsJson -FilePath $($appSettingsX86) `
                       -WebAppHost $($webAppHost) `
                       -MailHost $($mailHost) `
                       -FromEmail $($fromEmail) `
                       -Product $($product) `
                       -RollingInterval 'Day' `
                       -RetainFileCount 30"

    Update-AppSettingsJson -FilePath $appSettingsX86 `
                           -WebAppHost $webAppHost `
                           -MailHost $mailHost `
                           -FromEmail $fromEmail `
                           -Product $product `
                           -RollingInterval "Day" `
                           -RetainFileCount 30

    # Update web.config
    $webConfigPath = Join-Path $clientFolder "web.config.js"

    Write-VerboseLog "Update-WebConfig -TargetPath $($webConfigPath)"
    Update-WebConfig -TargetPath $webConfigPath

    # Start IIS components again
    Write-VerboseLog "Start-AppComponents `
        -AppPool64 $($api.AppPoolName64) `
        -AppPool32 $($api.AppPoolName32) `
        -SiteName $($env.Client.HostUrl)"

    Start-AppComponents `
        -AppPool64 $api.AppPoolName64 `
        -AppPool32 $api.AppPoolName32 `
        -SiteName $env.Client.HostUrl


}