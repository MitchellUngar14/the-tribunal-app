param(
    [switch]$VerboseLog
)

Import-Module WebAdministration -ErrorAction Stop

$GlobalVarsPath = "D:\Scripts\GlobalVariables.psd1"
if (-not (Test-Path $GlobalVarsPath)) {
  Write-Host "GlobalVariables.psd1 not found at $GlobalVarsPath" -ForegroundColor Red
  exit 2
}
$GlobalVars = Import-PowerShellDataFile -Path $GlobalVarsPath


# ---- helpers ---------------------------------------------------------------

function Write-VerboseLog { param([string]$m)
    if ($VerboseLog) { Write-Host "[VERBOSE] $m" -ForegroundColor DarkGray }
}

function Add-Result {
    param([ref]$Bag, [string]$Env, [string]$Check, [bool]$Ok, [string]$Detail)
    $Bag.Value += [pscustomobject] @{
    Environment = $Env
    Check       = $Check
    Status      = if ($Ok) { 'OK' } else { 'FAIL' }
    Detail      = $Detail
    }
}

function Test-AppPoolExists { param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    Test-Path "IIS:\AppPools\$Name"
}

function Test-Folder { param([string]$Path) Test-Path -LiteralPath $Path }

function Test-SqlDatabaseExists {
    param(
    [string]$Server, [string]$DbName,
    [string]$User, [string]$Password,
    [int]$TimeoutSec = 6
    )
    if ([string]::IsNullOrWhiteSpace($DbName)) { return $true } # skip empties like Odd = ""
    try {
    $cs = "Server=$Server;Database=master;User ID=$User;Password=$Password;TrustServerCertificate=True;Connection Timeout=$TimeoutSec"
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT 1 FROM sys.databases WHERE name = @n"
    $null = $cmd.Parameters.Add(" @n",[System.Data.SqlDbType]::NVarChar,128)
    $cmd.Parameters[" @n"].Value = $DbName
    $exists = $cmd.ExecuteScalar()
    $conn.Close()
    return [bool]$exists
    } catch {
    return $false
    }
}

function Test-File { param([string]$Path)
  (Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue) -is [System.IO.FileInfo])
}
# ---- main ------------------------------------------------------------------
$envRoot = "D:\Scripts\Environments"
$files = Get-ChildItem -Path $envRoot -Filter *.psd1 -ErrorAction Stop

$results = @()

foreach ($file in $files) {
    $env = Import-PowerShellDataFile $file.FullName
    $name = $env.Name
    Write-Host "`n--- Validating $name ---" -ForegroundColor Cyan

    # Paths
    $basePath     = $env.BasePath
    $clientFolder = Join-Path $basePath "RatabasePB"
    $apiX64       = Join-Path $clientFolder "RatabaseX64"
    $apiX86       = Join-Path $clientFolder "RatabaseX86"

    # IIS checks
    $siteName     = $env.Client.HostUrl
    $sitePool     = $env.Client.AppPoolName

    Add-Result ([ref]$results) $name "IIS Site Exists"      ([bool](Get-Website -Name $siteName -ErrorAction SilentlyContinue))  "Site: $siteName"
    Add-Result ([ref]$results) $name "Site AppPool Name"    ([bool]$sitePool)                                                  "Detected: $sitePool"

    # Client app pool (from env)
    $clientPool = $env.Client.AppPoolName
    Add-Result ([ref]$results) $name "Client AppPool Exists" (Test-AppPoolExists $clientPool)                                  "Client AppPool: $clientPool"

    # API app pools
    $apiPool64 = $env.Api.AppPoolName64
    $apiPool32 = $env.Api.AppPoolName32
    Add-Result ([ref]$results) $name "API x64 AppPool Exists" (Test-AppPoolExists $apiPool64)                                  "API64 AppPool: $apiPool64"
    Add-Result ([ref]$results) $name "API x86 AppPool Exists" (Test-AppPoolExists $apiPool32)                                  "API86 AppPool: $apiPool32"

    # Optional: check site pool matches expected client pool
    $siteVsClientMatch = ($sitePool -and $clientPool -and ($sitePool -eq $clientPool))
    Add-Result ([ref]$results) $name "Site->Client AppPool Match" $siteVsClientMatch "SitePool=$sitePool, ClientPool=$clientPool"

    # Install folders
    Add-Result ([ref]$results) $name "BasePath Exists"   (Test-Folder $basePath)   $basePath
    Add-Result ([ref]$results) $name "Client Folder"     (Test-Folder $clientFolder) $clientFolder
    Add-Result ([ref]$results) $name "API x64 Folder"    (Test-Folder $apiX64)     $apiX64
    Add-Result ([ref]$results) $name "API x86 Folder"    (Test-Folder $apiX86)     $apiX86

    # ---- dataset consistency ----------------------------------------------------
    $clientDs = $env.Client.DatasetName
    $apiDs    = $env.Api.DB.Dataset

    # Individual presence checks
    Add-Result ([ref]$results) $name "Client Dataset Present" ([bool]$clientDs) "Client.DatasetName='$clientDs'"
    Add-Result ([ref]$results) $name "API Dataset Present"    ([bool]$apiDs)    "Api.DB.Dataset='$apiDs'"

    # Match check (only if both present)
    if ($clientDs -and $apiDs) {
        $match = ($clientDs -ieq $apiDs)
        Add-Result ([ref]$results) $name "Dataset Match (Client vs API)" $match "Client='$clientDs' vs API='$apiDs'"
    } else {
        Add-Result ([ref]$results) $name "Dataset Match (Client vs API)" $false "One or both datasets missing"
    }


    # SQL checks (only if DB block present)
    if ($env.Api -and $env.Api.DB) {
    $db = $env.Api.DB
    $server = $db.ServerName
    $user   = $db.Username
    $pass   = $db.Password

    foreach ($dbName in @(
        @{Label="DevDB";      Name=$db.Dev},
        @{Label="TestDB";     Name=$db.Test},
        @{Label="PersonalDB"; Name=$db.Personal},
        @{Label="ImportDB";   Name=$db.Import},
        @{Label="OutputDesignerDB"; Name=$db.Odd}
    )) {
        $ok = Test-SqlDatabaseExists -Server $server -DbName $dbName.Name -User $user -Password $pass
        Add-Result ([ref]$results) $name "SQL: $($dbName.Label)" $ok "Server=$server; DB=$($dbName.Name)"
    }
    } else {
    Add-Result ([ref]$results) $name "SQL Block Present" $false "env.Api.DB missing"
    }
}

Add-Result ([ref]$results) "GLOBAL" "Client MSI Exists" (Test-File $GlobalVars.MsiPathClient) $GlobalVars.MsiPathClient
Add-Result ([ref]$results) "GLOBAL" "API MSI Exists"    (Test-File $GlobalVars.MsiPathApi)    $GlobalVars.MsiPathApi

# ---- summary ---------------------------------------------------------------

# ---- logging setup ----
$logDir = "D:\Scripts\Logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$logFile = Join-Path $logDir ("ValidateEnvironments_{0:yyyy-MM-dd_HH-mm-ss}.log" -f (Get-Date))

# ---- summary ---------------------------------------------------------------

# Pretty summary table
$summary = $results | Group-Object Environment, Status | ForEach-Object {
    [pscustomobject] @{
        Environment = $_.Group[0].Environment
        Status      = $_.Group[0].Status
        Count       = $_.Count
    }
} | Sort-Object Environment, Status

# Output to console
Write-Host "`n=== Summary ===" -ForegroundColor Yellow
$summary | Format-Table -AutoSize

Write-Host "`n=== Detailed Results ===" -ForegroundColor Yellow
$results | Sort-Object Environment, @{e={$_.'Status'};d=$true}, Check | Format-Table -AutoSize

# Output to log file
"=== Summary ===" | Out-File -FilePath $logFile -Encoding UTF8
$summary | Out-String | Out-File -FilePath $logFile -Append -Encoding UTF8
"`n=== Detailed Results ===" | Out-File -FilePath $logFile -Append -Encoding UTF8
$results | Sort-Object Environment, @{e={$_.'Status'};d=$true}, Check | Out-String | Out-File -FilePath $logFile -Append -Encoding UTF8

Write-Host "`nLog file saved to: $logFile" -ForegroundColor Cyan

# Exit code: non-zero if any FAILs
if ($results.Status -contains 'FAIL') { exit 1 } else { exit 0 }