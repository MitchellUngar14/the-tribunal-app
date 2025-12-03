Import-Module WebAdministration
Import-Module "D:\Scripts\DeploymentHelpers.psm1" -Force

$envFiles = Get-ChildItem -Path "D:\Scripts\Environments" -Filter *.psd1

foreach ($file in $envFiles) {
    $env = Import-PowerShellDataFile -Path $file.FullName
    Write-Host "`n--- Starting components for $($env.Name) ---" -ForegroundColor Cyan

    Start-AppComponents `
        -AppPool64 $env.Api.AppPoolName64 `
        -AppPool32 $env.Api.AppPoolName32 `
        -SiteName $env.Client.HostUrl
}