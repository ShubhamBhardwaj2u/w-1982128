param(
    [Parameter(Mandatory=$true)]
    [string]$SsasServer,

    [Parameter(Mandatory=$true)]
    [string]$DatabaseName,

    [Parameter(Mandatory=$true)]
    [ValidateSet("DEV", "UAT", "PROD")]
    [string]$Environment,

    [Parameter(Mandatory=$true)]
    [string]$BackupRootPath,

    [Parameter(Mandatory=$false)]
    [string]$BackupFilePrefix,

    [Parameter(Mandatory=$false)]
    [string]$TomDllPath,

    [Parameter(Mandatory=$false)]
    [int]$TimeoutSeconds = 600,

    [Parameter(Mandatory=$false)]
    [switch]$VerboseLogging,

    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

# ============================================================
# CONFIGURATION
# ============================================================

$ErrorActionPreference = "Stop"
$script:BackupStartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:BackupFilePath = $null

if ($VerboseLogging) {
    $VerbosePreference = "Continue"
}

$Colors = @{
    Red      = [ConsoleColor]::Red
    Yellow   = [ConsoleColor]::Yellow
    Green    = [ConsoleColor]::Green
    Cyan     = [ConsoleColor]::Cyan
    White    = [ConsoleColor]::White
    DarkGray = [ConsoleColor]::DarkGray
    Magenta  = [ConsoleColor]::Magenta
}

# ============================================================
# LOGGING FUNCTIONS
# ============================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = $Colors.White

    switch ($Level) {
        "ERROR"   { $color = $Colors.Red }
        "WARNING" { $color = $Colors.Yellow }
        "SUCCESS" { $color = $Colors.Green }
        "INFO"    { $color = $Colors.Cyan }
        "DEBUG"   { $color = $Colors.DarkGray }
    }

    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor $Colors.Cyan
    Write-Host "  $Title" -ForegroundColor $Colors.Cyan
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor $Colors.Cyan
}

function Write-Step {
    param(
        [string]$Step,
        [string]$Description
    )

    Write-Host ""
    Write-Host "── $Step ─────────────────────────────────────────────" -ForegroundColor $Colors.Magenta
    Write-Host "  $Description" -ForegroundColor $Colors.White
}

function Add-Error {
    param([string]$Message)
    $script:Errors += $Message
    Write-Log $Message -Level "ERROR"
}

function Add-Warning {
    param([string]$Message)
    $script:Warnings += $Message
    Write-Log $Message -Level "WARNING"
}

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Get-AnalysisServicesAssembly {
    try {
        Add-Type -AssemblyName "Microsoft.AnalysisServices.Core" -ErrorAction Stop
        Write-Log "Analysis Services core library loaded from GAC" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Assembly not available in GAC" -Level "DEBUG"
    }

    if ($TomDllPath -and (Test-Path $TomDllPath)) {
        try {
            Add-Type -Path $TomDllPath -ErrorAction Stop
            Write-Log "Analysis Services library loaded from custom path: $TomDllPath" -Level "SUCCESS"
            return $true
        }
        catch {
            Add-Error "Failed to load Analysis Services library from custom path: $TomDllPath"
            return $false
        }
    }

    $possiblePaths = @(
        "C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE\CommonExtensions\Microsoft\SSIS\160\BIShared\Microsoft.AnalysisServices.Core.dll",
        "C:\Program Files (x86)\Microsoft SQL Server Management Studio 18\Common7\IDE\CommonExtensions\Microsoft\SSIS\150\BIShared\Microsoft.AnalysisServices.Core.dll",
        "C:\Program Files\Microsoft SQL Server\150\SDK\Assemblies\Microsoft.AnalysisServices.Core.dll",
        "C:\Program Files\Microsoft SQL Server\140\SDK\Assemblies\Microsoft.AnalysisServices.Core.dll"
    )

    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            try {
                Add-Type -Path $path -ErrorAction Stop
                Write-Log "Analysis Services library loaded from: $path" -Level "SUCCESS"
                return $true
            }
            catch {
                continue
            }
        }
    }

    Add-Error "Analysis Services libraries not found. Install SSMS/SDK or provide -TomDllPath"
    return $false
}

function Initialize-Configuration {
    if ([string]::IsNullOrWhiteSpace($SsasServer)) {
        throw "SsasServer is required."
    }

    if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
        throw "DatabaseName is required."
    }

    if ([string]::IsNullOrWhiteSpace($BackupRootPath)) {
        throw "BackupRootPath is required."
    }

    if ([string]::IsNullOrWhiteSpace($BackupFilePrefix)) {
        $BackupFilePrefix = $DatabaseName
    }

    Write-Log "Configuration validated" -Level "SUCCESS"
}

function Get-BackupFolderPath {
    param(
        [string]$RootPath,
        [string]$DbName,
        [string]$Env
    )

    return (Join-Path (Join-Path $RootPath $DbName) $Env)
}

function Get-BackupFileName {
    param(
        [string]$Prefix
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    return "$Prefix" + "_" + "$timestamp.abf"
}

function Ensure-BackupFolder {
    param(
        [string]$FolderPath
    )

    if ($WhatIf) {
        Write-Host "[WHATIF] Would ensure backup folder exists: $FolderPath" -ForegroundColor $Colors.Yellow
        return
    }

    if (-not (Test-Path $FolderPath)) {
        New-Item -Path $FolderPath -ItemType Directory -Force | Out-Null
        Write-Log "Created backup folder: $FolderPath" -Level "SUCCESS"
    }
    else {
        Write-Log "Backup folder already exists: $FolderPath" -Level "INFO"
    }
}

function Connect-SsasServer {
    param(
        [string]$ServerName
    )

    $server = New-Object Microsoft.AnalysisServices.Server

    try {
        Write-Log "Connecting to SSAS server: $ServerName" -Level "INFO"
        $server.Connect($ServerName)

        if (-not $server.Connected) {
            throw "Connection established but server is not in connected state."
        }

        Write-Log "Connected to SSAS server: $ServerName" -Level "SUCCESS"
        Write-Log "Server Version: $($server.Version)" -Level "INFO"
        Write-Log "Server Edition: $($server.Edition)" -Level "INFO"

        return $server
    }
    catch {
        Add-Error "Failed to connect to SSAS server: $($_.Exception.Message)"
        throw
    }
}

function Get-ExistingDatabase {
    param(
        [Microsoft.AnalysisServices.Server]$Server,
        [string]$Name
    )

    $db = $Server.Databases.FindByName($Name)

    if ($null -eq $db) {
        throw "Database '$Name' not found on server '$SsasServer'."
    }

    Write-Log "Database found: $Name" -Level "SUCCESS"
    Write-Log "Database ID: $($db.ID)" -Level "INFO"

    return $db
}

function Invoke-DatabaseBackup {
    param(
        [Microsoft.AnalysisServices.Database]$Database,
        [string]$FilePath
    )

    if ($WhatIf) {
        Write-Host "[WHATIF] Would backup database '$($Database.Name)' to '$FilePath'" -ForegroundColor $Colors.Yellow
        $script:BackupFilePath = $FilePath
        return
    }

    try {
        Write-Log "Starting backup for database '$($Database.Name)'" -Level "INFO"
        Write-Log "Backup destination: $FilePath" -Level "INFO"

        $Database.Backup($FilePath, $true)

        if (-not (Test-Path $FilePath)) {
            throw "Backup operation completed but file not found at: $FilePath"
        }

        $file = Get-Item $FilePath
        $sizeMb = [math]::Round(($file.Length / 1MB), 2)

        Write-Log "Backup completed successfully" -Level "SUCCESS"
        Write-Log "Backup file size: $sizeMb MB" -Level "INFO"

        $script:BackupFilePath = $FilePath
    }
    catch {
        Add-Error "Backup failed: $($_.Exception.Message)"
        throw
    }
}

# ============================================================
# MAIN EXECUTION
# ============================================================

Write-Host ""
Write-Host " -------------------------------------------------------------"
Write-Host "       SSAS Tabular Backup Tool                               "
Write-Host " -------------------------------------------------------------"

Write-Log "Backup started at: $script:BackupStartTime"

if ($WhatIf) {
    Write-Log "WHATIF MODE: No actual changes will be made" -Level "WARNING"
}

# Step 1: Load required libraries
Write-Step "1" "Loading Analysis Services Libraries"
if (-not (Get-AnalysisServicesAssembly)) {
    exit 1
}

# Step 2: Initialize configuration
Write-Step "2" "Initializing Configuration"
try {
    Initialize-Configuration
}
catch {
    Write-Log "Configuration failed: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

Write-Host ""
Write-Host "Backup Configuration:" -ForegroundColor $Colors.Green
Write-Host "  SSAS Server: $SsasServer" -ForegroundColor $Colors.White
Write-Host "  Database: $DatabaseName" -ForegroundColor $Colors.White
Write-Host "  Environment: $Environment" -ForegroundColor $Colors.White
Write-Host "  Backup Root Path: $BackupRootPath" -ForegroundColor $Colors.White
Write-Host "  Backup File Prefix: $BackupFilePrefix" -ForegroundColor $Colors.White

# Step 3: Resolve backup path
Write-Step "3" "Resolving Backup Path"
$backupFolder = Get-BackupFolderPath -RootPath $BackupRootPath -DbName $DatabaseName -Env $Environment
$backupFileName = Get-BackupFileName -Prefix $BackupFilePrefix
$backupFilePath = Join-Path $backupFolder $backupFileName

Write-Log "Resolved backup folder: $backupFolder" -Level "INFO"
Write-Log "Resolved backup file: $backupFilePath" -Level "INFO"

# Step 4: Ensure folder exists
Write-Step "4" "Ensuring Backup Folder Exists"
try {
    Ensure-BackupFolder -FolderPath $backupFolder
}
catch {
    Add-Error "Failed to prepare backup folder: $($_.Exception.Message)"
    exit 1
}

# Step 5: Connect to SSAS
Write-Step "5" "Connecting to SSAS Server"
try {
    $server = Connect-SsasServer -ServerName $SsasServer
}
catch {
    exit 1
}

try {
    # Step 6: Find database
    Write-Step "6" "Validating Target Database"
    $database = Get-ExistingDatabase -Server $server -Name $DatabaseName

    # Step 7: Run backup
    Write-Step "7" "Taking Database Backup"
    Invoke-DatabaseBackup -Database $database -FilePath $backupFilePath
}
finally {
    if ($server -and $server.Connected) {
        $server.Disconnect()
        Write-Log "Disconnected from SSAS server" -Level "INFO"
    }
}

# ============================================================
# FINAL RESULTS
# ============================================================

$script:BackupEndTime = Get-Date
$duration = $script:BackupEndTime - $script:BackupStartTime

Write-Section "Backup Results"

if ($WhatIf) {
    Write-Log "WHATIF MODE: No actual backup file created" -Level "WARNING"
}

if ($script:Errors.Count -gt 0) {
    Write-Log "Backup FAILED with $($script:Errors.Count) error(s)" -Level "ERROR"

    Write-Host ""
    Write-Host "ERRORS:" -ForegroundColor $Colors.Red
    $script:Errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor $Colors.Red }

    exit 1
}

Write-Log "Backup completed successfully!" -Level "SUCCESS"

Write-Host ""
Write-Host "Summary:" -ForegroundColor $Colors.Green
Write-Host "  Server: $SsasServer" -ForegroundColor $Colors.Green
Write-Host "  Database: $DatabaseName" -ForegroundColor $Colors.Green
Write-Host "  Environment: $Environment" -ForegroundColor $Colors.Green
Write-Host "  Backup File: $script:BackupFilePath" -ForegroundColor $Colors.Green
Write-Host "  Duration: $($duration.ToString('mm\:ss'))" -ForegroundColor $Colors.Green

if ($script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnings:" -ForegroundColor $Colors.Yellow
    $script:Warnings | ForEach-Object { Write-Host "  ! $_" -ForegroundColor $Colors.Yellow }
}

Write-Host ""

if ($script:BackupFilePath) {
    Write-Host "##vso[task.setvariable variable=BackupFilePath]$($script:BackupFilePath)"
    Write-Log "Pipeline variable set: BackupFilePath" -Level "SUCCESS"
}

Write-Host "Backup finished at: $script:BackupEndTime" -ForegroundColor $Colors.Cyan

exit 0