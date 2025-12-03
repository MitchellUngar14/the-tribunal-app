param(
    [string]$EnvFolder   = "D:\Scripts\Environments",        # folder containing *.psd1 env files
    [string]$OrderFile   = "D:\Scripts\Sql\SqlScriptOrder\SqlScriptOrder.psd1",
    [string]$ScriptsRoot = "D:\Scripts\Sql\SqlScripts",
    [string]$AdminCreds  = "D:\Scripts\AdminCredentials.psd1",
    [string]$LogDir      = "D:\Scripts\Logs\SQL_LOGS",
    [string[]]$OnlyEnvs,                                     # optional filter: env.Name values
    [string[]]$OnlyFolders,                                  # optional filter: e.g. Development,Test
    [switch]$WhatIf,
    [switch]$VerboseLog,
    [switch]$ContinueOnError,                                 # continue after errors (all folders)
    [string[]]$ContinueOnErrorFolders                         # or only for these folders
)

$ErrorActionPreference = 'Stop'

# ---------- helpers ----------
function Write-VerboseLog { param([string]$m)
if ($VerboseLog) { Write-Host "[VERBOSE] $m" -ForegroundColor DarkGray }
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$runStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile  = Join-Path $LogDir "RunSqlMigrations_$runStamp.log"

function Log { param([string]$m)
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$line = "[$ts] $m"
$line | Tee-Object -FilePath $logFile -Append
}

function Ensure-SqlCmd {
    $cmd = Get-Command -Name "sqlcmd.exe" -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "sqlcmd.exe not found. Install the SQL Server command-line utilities (SQLCMD) or add it to PATH."
    }
}
Ensure-SqlCmd

# Folder name -> DB name from env.Api.DB (null-safe)
function Get-DbNameForFolder {
    param([hashtable]$Db, [string]$FolderName)

    if ([string]::IsNullOrWhiteSpace($FolderName)) {
        throw "Get-DbNameForFolder: FolderName is null or empty"
    }
    $f = $FolderName.Trim().ToLowerInvariant()
    switch ($f) {
        'development' { return $Db.Dev }
        'test'        { return $Db.Test }
        'import'      { return $Db.Import }
        'personal'    { return $Db.Personal }
        'healthcheck' { return $Db.Dev }  # Healthcheck uses Dev DB
        default       { return $null }
    }
}

# Build sqlcmd args based on auth mode
function Build-SqlcmdArgs {
    param(
        [string]$Server, [string]$Database,
        [string]$Auth,   # "Integrated" or "Sql"
        [string]$User, [string]$Password,
        [string]$ScriptPath,
        [int]$LoginTimeoutSec = 15,
        [int]$QueryTimeoutSec = 1000
    )
    $args = @(
        "-S", $Server,
        "-d", $Database,
        "-b",              # fail on error
        "-r", "1",         # sev >= 11 -> stderr
        "-l", $LoginTimeoutSec,
        "-t", $QueryTimeoutSec,
        "-W",              # trim spaces
        "-w", "4000",      # wide output
        "-i", "`"$ScriptPath`""
    )
    if ($Auth -ieq "Integrated") { $args += "-E" } else { $args += @("-U", $User, "-P", $Password) }
    return $args
}

# ISE-safe sqlcmd runner with raw stdout/stderr capture and hard timeout
# Helper: never return $null when reading a file
function Get-ContentSafe {
    param(
        [Parameter(Mandatory)][string]$Path
    )
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $txt = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
        if ($null -eq $txt) { return '' }
        return $txt
    } catch { return '' }
}

# ISE-safe sqlcmd runner with raw stdout/stderr capture and hard timeout
function Invoke-SqlScript {
    param(
        [string]$Server, [string]$Database,
        [string]$Auth,   # "Integrated" or "Sql"
        [string]$User, [string]$Password,
        [string]$ScriptPath,
        [int]$LoginTimeoutSec = 15,
        [int]$QueryTimeoutSec = 600,
        [int]$HardTimeoutSec  = 1800   # wall-clock cap (seconds)
    )

    if ($WhatIf) { Log "[WHATIF] sqlcmd $Server.$Database <= $ScriptPath (Auth=$Auth)"; return }
    if (-not (Test-Path $ScriptPath)) { throw "Script not found: $ScriptPath" }

    $args = Build-SqlcmdArgs -Server $Server -Database $Database -Auth $Auth -User $User -Password $Password -ScriptPath $ScriptPath `
                           -LoginTimeoutSec $LoginTimeoutSec -QueryTimeoutSec $QueryTimeoutSec

    # Raw logs under $LogDir\raw, include DB name in file
    $rawDir = Join-Path $LogDir "raw"
    if (-not (Test-Path $rawDir)) { New-Item -ItemType Directory -Path $rawDir | Out-Null }
    $dbSafe   = $Database -replace '[^A-Za-z0-9._-]', '_'
    $baseName = [IO.Path]::GetFileNameWithoutExtension($ScriptPath) -replace '[^A-Za-z0-9._-]', '_'
    $stamp    = Get-Date -Format "yyyyMMdd_HHmmss"
    $outFile  = Join-Path $rawDir "${dbSafe}_${baseName}.${stamp}.results.log"
    $errFile  = Join-Path $rawDir "${dbSafe}_${baseName}.${stamp}.messages.log"

    Log "Executing on [$Database]: sqlcmd $($args -join ' ')"
    Log "(stdout -> $outFile, stderr -> $errFile)"

    # Use a background job to get reliable $LASTEXITCODE + hard timeout
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $job = Start-Job -ScriptBlock {
        param($exe, $argv, $outP, $errP)
        & $exe @argv 1> $outP 2> $errP
        return $LASTEXITCODE
    } -ArgumentList @("sqlcmd.exe", $args, $outFile, $errFile)

    if (-not (Wait-Job -Id $job.Id -Timeout $HardTimeoutSec)) {
        try { Stop-Job -Id $job.Id -Force -ErrorAction SilentlyContinue } catch {}
        $sw.Stop()
        Log "-----" "SQLCMD TIMEOUT (${HardTimeoutSec}s, actual ~$([int]$sw.Elapsed.TotalSeconds)s) ($([IO.Path]::GetFileName($ScriptPath)))" "-----"
        # Dump whatever was captured so far (safely)
        $outNow = Get-ContentSafe -Path $outFile
        if ($outNow) { $outNow -split "`r?`n" | ForEach-Object { Log $_ } }
        $errNow = Get-ContentSafe -Path $errFile
        if ($errNow) { $errNow -split "`r?`n" | ForEach-Object { Log $_ } }
        throw "sqlcmd exceeded hard timeout of ${HardTimeoutSec}s for $ScriptPath"
    }

    # Collect exit code (guard against $null)
    $exit = Receive-Job -Id $job.Id -ErrorAction SilentlyContinue
    Remove-Job -Id $job.Id -Force -ErrorAction SilentlyContinue
    $sw.Stop()
    if ($null -eq $exit) { $exit = 0 }  # or 1 if you prefer strict fail-closed

    # ----- STDOUT -----
    Log "-----" "SQLCMD STDOUT BEGIN ($([IO.Path]::GetFileName($ScriptPath)))" "-----"
    $out = Get-ContentSafe -Path $outFile
    $out = $out.TrimEnd()
    if ($out) {
        $out -split "`r?`n" | ForEach-Object { Log $_ }
    } else {
        Log "(no stdout)"
    }
    Log "-----" "SQLCMD STDOUT END -----"

    # ----- STDERR -----
    $err = Get-ContentSafe -Path $errFile
    $err = $err.TrimEnd()
    if ($err) {
        Log "-----" "SQLCMD STDERR BEGIN ($([IO.Path]::GetFileName($ScriptPath)))" "-----"
        $err -split "`r?`n" | ForEach-Object { Log $_ }
        Log "-----" "SQLCMD STDERR END -----"
    }

    Log "sqlcmd elapsed: $([int]$sw.Elapsed.TotalSeconds)s, exit=$exit"
    if ($exit -ne 0) { throw "sqlcmd exited with code $exit for $ScriptPath" }
}

# Return only scripts listed in SqlScriptOrder.psd1, ignore all others
function Get-OrderedScripts {
    param(
        [string]$FolderPath,
        [string[]]$DeclaredOrder
    )

    $ordered = New-Object System.Collections.Generic.List[string]

    foreach ($name in $DeclaredOrder) {
        $path = Join-Path $FolderPath $name
        if (Test-Path $path) {
            $ordered.Add((Resolve-Path $path).Path)
        }
        else {
            Log "Declared script not found in folder: $name"
        }
    }

    return ,$ordered
}

# ---------- load order & admin creds ----------
if (-not (Test-Path $OrderFile)) { throw "Order file not found: $OrderFile" }
$order = Import-PowerShellDataFile -Path $OrderFile

# Normalize Order keys (trim whitespace)
$normalized = [ordered] @{}
foreach ($k in $order.Keys) {
    $nk = ([string]$k).Trim()
    $normalized[$nk] = $order[$k]
}
$order = $normalized
Log "Order keys: " + (($order.Keys | ForEach-Object { '[' + $_ + ']' }) -join ', ')

$useAdmin = $false
$admin = $null
if (Test-Path $AdminCreds) {
    $admin = Import-PowerShellDataFile -Path $AdminCreds
    # Option A: prefer Integrated if enabled
    if ($admin.Enabled -and ($admin.Auth -ieq "Integrated")) { $useAdmin = $true }
    Write-VerboseLog "AdminCreds detected. Enabled=$($admin.Enabled) Auth=$($admin.Auth) UseAdmin=$useAdmin Server=$($admin.Server)"
}

# Normalize OnlyFolders (trim) if provided
if ($OnlyFolders) {
    # Trim each entry; drop null/empty ones
    $OnlyFolders = @(
    $OnlyFolders |
            ForEach-Object {
                if ($_ -ne $null) {
                    $_.ToString().Trim()
                }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($OnlyFolders.Count -eq 0) { $OnlyFolders = $null }  # keep behavior consistent
    Log "OnlyFolders (normalized): " + ($(if ($OnlyFolders) { $OnlyFolders -join ', ' } else { '(none)' }))
}


# ---------- find envs ----------
if (-not (Test-Path $EnvFolder)) { throw "EnvFolder not found: $EnvFolder" }
$envFiles = Get-ChildItem -Path $EnvFolder -Filter *.psd1
if ($envFiles.Count -eq 0) { throw "No environment files found in $EnvFolder" }

# ---------- run ----------
Log "=== Run-SqlMigrations start ==="
Log "EnvFolder: $EnvFolder"
Log "OrderFile: $OrderFile"
Log "ScriptsRoot: $ScriptsRoot"
Log "AdminCreds: $(if ($useAdmin) {'Using ADMIN Integrated auth (-E)'} else {'Using ENV SQL auth (-U/-P)'})"
Log "OnlyEnvs: $(if ($OnlyEnvs) { $OnlyEnvs -join ', ' } else { '(all)' })"
Log "OnlyFolders: $(if ($OnlyFolders) { $OnlyFolders -join ', ' } else { '(all from SqlScriptOrder.psd1)' })"
Log "WhatIf: $WhatIf"
if ($ContinueOnError) { Log "ContinueOnError: (all folders)" }
if ($ContinueOnErrorFolders) { Log "ContinueOnErrorFolders: $($ContinueOnErrorFolders -join ', ')" }

foreach ($file in $envFiles) {
    $env = Import-PowerShellDataFile -Path $file.FullName
    $name = $env.Name

    if ($OnlyEnvs -and ($OnlyEnvs -notcontains $name)) {
        Write-VerboseLog "Skipping env $name (filtered)"
        continue
    }

    Log ""
    Log "--- Environment: $name ---"

    $db = $env.Api.DB
    if (-not $db) { Log "No DB block in env file. Skipping $name."; continue }

    # Resolve server + auth
    $server   = if ($useAdmin -and $admin.Server) { $admin.Server } else { $db.ServerName }
    $auth     = if ($useAdmin) { "Integrated" } else { "Sql" }
    $username = if ($useAdmin) { "" } else { $db.Username }   # not used for Integrated
    $password = if ($useAdmin) { "" } else { $db.Password }   # not used for Integrated

    foreach ($folderNameRaw in $order.Keys) {
        $folderName = ([string]$folderNameRaw).Trim()

        if ($OnlyFolders -and ($OnlyFolders -notcontains $folderName)) {
            Write-VerboseLog "Skipping folder $folderName (filtered)"
            continue
        }

        # Map to DB name (with clear diagnostics)
        try {
            $targetDb = Get-DbNameForFolder -Db $db -FolderName $folderName
        } catch {
            Log "Folder '$folderName' mapping error: $($_.Exception.Message)"
            continue
        }

        if ([string]::IsNullOrWhiteSpace($targetDb)) {
            Log "No target DB mapped for folder '$folderName' in env '$name'. (Dev='$($db.Dev)', Test='$($db.Test)', Import='$($db.Import)', Personal='$($db.Personal)')"
            continue
        }

        $folderPath = Join-Path $ScriptsRoot $folderName
        if (-not (Test-Path $folderPath)) {
            Log "Scripts folder not found: $folderPath (skipping)"
            continue
        }

        $declared = @()
        if ($order.Keys -contains $folderName -and $order[$folderName]) {
            $declared = @($order[$folderName])
        }

        $scripts = Get-OrderedScripts -FolderPath $folderPath -DeclaredOrder $declared
        Log "Found $($scripts.Count) script(s) in '$folderName': " +
        (($scripts | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')

        if ($scripts.Count -eq 0) {
            Log "   (no scripts to run)"
            continue
        }

        $envHadError = $false
        $continueThisFolder = $ContinueOnError -or ($ContinueOnErrorFolders -and ($ContinueOnErrorFolders -contains $folderName))

        foreach ($script in $scripts) {
            try {
                Log "Running: $(Split-Path $script -Leaf) on DB '$targetDb' (folder '$folderName')"
                if ([string]::IsNullOrWhiteSpace($targetDb)) { throw "Target DB resolved to empty for folder '$folderName'" }
                Invoke-SqlScript -Server $server -Database $targetDb -Auth $auth -User $username -Password $password -ScriptPath $script
                Log "Success"
            }
            catch {
                Log "Failed: $($_.Exception.Message)"
                if ($continueThisFolder) {
                    Log "Continuing after error (folder '$folderName')."
                } else {
                    Log "Aborting environment '$name' due to error in folder '$folderName'."
                    $envHadError = $true
                    break
                }
            }
        }
        if ($envHadError) { break }
    }
}

Log ""
Log "=== Run-SqlMigrations complete ==="
Write-Host "`nLog saved to: $logFile" -ForegroundColor Cyan
