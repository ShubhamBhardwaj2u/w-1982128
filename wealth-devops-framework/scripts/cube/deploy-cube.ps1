param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$BimPath,

    [Parameter(Mandatory=$true)]
    [ValidateSet("DEV", "UAT", "PROD")]
    [string]$Environment,

    [Parameter(Mandatory=$true)]
    [string]$SsasServer,

    [Parameter(Mandatory=$true)]
    [string]$DatabaseName,

    [Parameter(Mandatory=$true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$DatasourcesConfigFile,

    [Parameter(Mandatory=$true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$RolesConfigFile,

    [Parameter(Mandatory=$false)]
    [ValidateSet("None", "Full", "Default", "DataOnly", "Calculate")]
    [string]$ProcessType = "Full",

    [Parameter(Mandatory=$false)]
    [bool]$CreateDatabaseIfNotExists = $true,

    [Parameter(Mandatory=$false)]
    [string]$WorkingFolder = "",

    [Parameter(Mandatory=$false)]
    [switch]$VerboseLogging,

    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$script:DeploymentStartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:ChangesMade = @()
$script:WorkingBimPath = $null

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

function Initialize-AnalysisServicesLibraries {
    $possiblePaths = @(
        "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Microsoft.AnalysisServices.Core.dll",
        "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Microsoft.AnalysisServices.Tabular.dll",
        "C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE\CommonExtensions\Microsoft\SSIS\160\BIShared\Microsoft.AnalysisServices.Core.dll",
        "C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE\CommonExtensions\Microsoft\SSIS\160\BIShared\Microsoft.AnalysisServices.Tabular.dll"
    )

    $loadedCount = 0

    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            try {
                Add-Type -Path $path -ErrorAction Stop
                Write-Log "Loaded library: $path" -Level "SUCCESS"
                $loadedCount++
            }
            catch {
                Add-Warning "Failed to load library: $path"
            }
        }
    }

    if ($loadedCount -lt 2) {
        Add-Error "Required Analysis Services libraries could not be loaded."
        return $false
    }

    return $true
}

function Initialize-Configuration {
    if ([string]::IsNullOrWhiteSpace($WorkingFolder)) {
        $WorkingFolder = Join-Path ([System.IO.Path]::GetDirectoryName($BimPath)) "_deployment_work"
    }

    if (-not (Test-Path $WorkingFolder)) {
        New-Item -Path $WorkingFolder -ItemType Directory -Force | Out-Null
        Write-Log "Created working folder: $WorkingFolder" -Level "SUCCESS"
    }
    else {
        Write-Log "Using existing working folder: $WorkingFolder" -Level "INFO"
    }

    $script:WorkingBimPath = Join-Path $WorkingFolder ([System.IO.Path]::GetFileName($BimPath))

    Write-Log "Configuration validated" -Level "SUCCESS"
}

function Copy-WorkingBim {
    if ($WhatIf) {
        Write-Host "[WHATIF] Would copy BIM to working location: $script:WorkingBimPath" -ForegroundColor $Colors.Yellow
        return
    }

    Copy-Item -Path $BimPath -Destination $script:WorkingBimPath -Force
    Write-Log "Working BIM created: $script:WorkingBimPath" -Level "SUCCESS"
}

function Invoke-ScriptFile {
    param(
        [string]$ScriptPath,
        [string[]]$ArgumentsList
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Script not found: $ScriptPath"
    }

    Write-Log "Executing script: $ScriptPath" -Level "INFO"
    Write-Log "Arguments: $($ArgumentsList -join ' ')" -Level "DEBUG"

    & $ScriptPath @ArgumentsList

    if ($LASTEXITCODE -ne 0) {
        throw "Script failed with exit code $LASTEXITCODE : $ScriptPath"
    }
}

function Get-DatabaseFromBim {
    param([string]$Path)

    Write-Log "Deserializing BIM model from: $Path" -Level "INFO"

    try {
        $json = Get-Content $Path -Raw -Encoding UTF8
        $database = [Microsoft.AnalysisServices.Tabular.JsonSerializer]::DeserializeDatabase($json)
        Write-Log "Model deserialized successfully: $($database.Name)" -Level "SUCCESS"
        return $database
    }
    catch {
        Add-Error "Failed to deserialize BIM file: $($_.Exception.Message)"
        throw
    }
}

function Update-DatabaseIdentity {
    param(
        [object]$Database,
        [string]$Name
    )

    $Database.Name = $Name
    $Database.ID = $Name

    Write-Log "Database identity set to: $Name" -Level "SUCCESS"
    $script:ChangesMade += "Database identity updated to: $Name"
}

function Connect-SsasServer {
    param([string]$ServerName)

    $server = New-Object Microsoft.AnalysisServices.Tabular.Server

    try {
        Write-Log "Connecting to SSAS server: $ServerName" -Level "INFO"
        $server.Connect($ServerName)

        if (-not $server.Connected) {
            throw "Connection established but server not in connected state."
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

function Invoke-DatabaseDeployment {
    param(
        [object]$Server,
        [object]$Database,
        [string]$Name,
        [bool]$CreateIfNotExists
    )

    $existingDb = $Server.Databases.FindByName($Name)

    if ($null -eq $existingDb) {
        if (-not $CreateIfNotExists) {
            throw "Database '$Name' does not exist and CreateDatabaseIfNotExists is false."
        }

        if ($WhatIf) {
            Write-Host "[WHATIF] Would create database: $Name" -ForegroundColor $Colors.Yellow
            return $null
        }

        Write-Log "Creating new database: $Name" -Level "INFO"
        $Server.Databases.Add($Database)
        $Database.Update([Microsoft.AnalysisServices.UpdateOptions]::ExpandFull)

        Write-Log "Database created successfully: $Name" -Level "SUCCESS"
        $script:ChangesMade += "Created database: $Name"

        return $Server.Databases.FindByName($Name)
    }

    if ($WhatIf) {
        Write-Host "[WHATIF] Would update existing database: $Name" -ForegroundColor $Colors.Yellow
        return $existingDb
    }

    Write-Log "Updating existing database: $Name" -Level "INFO"
    $existingDb.Model = $Database.Model
    $existingDb.Update([Microsoft.AnalysisServices.UpdateOptions]::ExpandFull)

    Write-Log "Database updated successfully: $Name" -Level "SUCCESS"
    $script:ChangesMade += "Updated database: $Name"

    return $Server.Databases.FindByName($Name)
}

function Invoke-ProcessModel {
    param(
        [object]$Database,
        [string]$ProcessType
    )

    if ($ProcessType -eq "None") {
        Write-Log "Processing skipped (ProcessType = None)" -Level "INFO"
        return
    }

    $refreshType = switch ($ProcessType) {
        "Full"      { [Microsoft.AnalysisServices.Tabular.RefreshType]::Full }
        "Default"   { [Microsoft.AnalysisServices.Tabular.RefreshType]::Default }
        "DataOnly"  { [Microsoft.AnalysisServices.Tabular.RefreshType]::DataOnly }
        "Calculate" { [Microsoft.AnalysisServices.Tabular.RefreshType]::Calculate }
        default     { [Microsoft.AnalysisServices.Tabular.RefreshType]::None }
    }

    if ($WhatIf) {
        Write-Host "[WHATIF] Would process model with: $ProcessType" -ForegroundColor $Colors.Yellow
        return
    }

    try {
        Write-Log "Processing database using: $ProcessType" -Level "INFO"

        $Database.Model.RequestRefresh($refreshType)
        $saveResult = $Database.Model.SaveChanges()

        $hasErrors = $false
        $hasWarnings = $false

        foreach ($xmlaResult in $saveResult.XmlaResults) {
            foreach ($msg in $xmlaResult.Messages) {
                if ($msg.GetType().Name -eq "XmlaError") {
                    Write-Log "ERROR: $($msg.Description)" -Level "ERROR"
                    $hasErrors = $true
                }
                else {
                    Write-Log "WARNING: $($msg.Description)" -Level "WARNING"
                    $hasWarnings = $true
                }
            }
        }

        if ($hasErrors) {
            throw "Processing failed with errors."
        }

        if ($hasWarnings) {
            Write-Log "Processing completed with warnings." -Level "WARNING"
        }
        else {
            Write-Log "Processing completed successfully." -Level "SUCCESS"
        }

        $script:ChangesMade += "Processed database using: $ProcessType"
    }
    catch {
        Add-Error "Processing failed: $($_.Exception.Message)"
        throw
    }
}

Write-Host ""
Write-Host " -------------------------------------------------------------"
Write-Host "       SSAS Tabular Deployment Tool                           "
Write-Host " -------------------------------------------------------------"

Write-Log "Deployment started at: $script:DeploymentStartTime"

if ($WhatIf) {
    Write-Log "WHATIF MODE: No actual changes will be made" -Level "WARNING"
}

Write-Step "1" "Loading Analysis Services Libraries"
if (-not (Initialize-AnalysisServicesLibraries)) {
    exit 1
}

Write-Step "2" "Initializing Configuration"
try {
    Initialize-Configuration
}
catch {
    Write-Log "Configuration failed: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

Write-Host ""
Write-Host "Deployment Configuration:" -ForegroundColor $Colors.Green
Write-Host "  BIM Path: $BimPath" -ForegroundColor $Colors.White
Write-Host "  Working BIM Path: $script:WorkingBimPath" -ForegroundColor $Colors.White
Write-Host "  Environment: $Environment" -ForegroundColor $Colors.White
Write-Host "  SSAS Server: $SsasServer" -ForegroundColor $Colors.White
Write-Host "  Database: $DatabaseName" -ForegroundColor $Colors.White
Write-Host "  Datasource Config: $DatasourcesConfigFile" -ForegroundColor $Colors.White
Write-Host "  Roles Config: $RolesConfigFile" -ForegroundColor $Colors.White
Write-Host "  Process Type: $ProcessType" -ForegroundColor $Colors.White
Write-Host "  Create If Not Exists: $CreateDatabaseIfNotExists" -ForegroundColor $Colors.White

Write-Step "3" "Creating Working BIM Copy"
try {
    Copy-WorkingBim
}
catch {
    Write-Log "Failed to create working BIM: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

$scriptRoot = $PSScriptRoot
$updateDatasourceScript = Join-Path $scriptRoot "update-datasource.ps1"
$updateRolesScript = Join-Path $scriptRoot "update-roles.ps1"

Write-Step "4" "Applying Datasource Configuration"
try {
    $args = @(
        "-BimPath", $script:WorkingBimPath,
        "-Environment", $Environment,
        "-DatasourcesConfigFile", $DatasourcesConfigFile
    )

    if ($WhatIf) { $args += "-DryRun" }

    Invoke-ScriptFile -ScriptPath $updateDatasourceScript -ArgumentsList $args
    $script:ChangesMade += "Datasource configuration applied"
}
catch {
    Write-Log "Datasource update failed: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

Write-Step "5" "Applying Roles Configuration"
try {
    $args = @(
        "-BimPath", $script:WorkingBimPath,
        "-Environment", $Environment,
        "-RolesConfigFile", $RolesConfigFile
    )

    if ($WhatIf) { $args += "-DryRun" }

    Invoke-ScriptFile -ScriptPath $updateRolesScript -ArgumentsList $args
    $script:ChangesMade += "Role configuration applied"
}
catch {
    Write-Log "Role update failed: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

Write-Step "6" "Loading Updated BIM Model"
try {
    $database = Get-DatabaseFromBim -Path $script:WorkingBimPath
    Update-DatabaseIdentity -Database $database -Name $DatabaseName
}
catch {
    exit 1
}

Write-Step "7" "Connecting to SSAS Server"
try {
    $server = Connect-SsasServer -ServerName $SsasServer
}
catch {
    exit 1
}

try {
    Write-Step "8" "Deploying Database"
    $deployedDb = Invoke-DatabaseDeployment -Server $server -Database $database -Name $DatabaseName -CreateIfNotExists $CreateDatabaseIfNotExists

    Write-Step "9" "Processing Database"
    if ($deployedDb) {
        Invoke-ProcessModel -Database $deployedDb -ProcessType $ProcessType
    }
    else {
        Write-Log "Skipping processing in WHATIF mode." -Level "WARNING"
    }
}
finally {
    if ($server -and $server.Connected) {
        $server.Disconnect()
        Write-Log "Disconnected from SSAS server" -Level "INFO"
    }
}

$script:DeploymentEndTime = Get-Date
$duration = $script:DeploymentEndTime - $script:DeploymentStartTime

Write-Section "Deployment Results"

if ($WhatIf) {
    Write-Log "WHATIF MODE: No actual deployment changes were made" -Level "WARNING"
}

if ($script:Errors.Count -gt 0) {
    Write-Log "Deployment FAILED with $($script:Errors.Count) error(s)" -Level "ERROR"

    Write-Host ""
    Write-Host "ERRORS:" -ForegroundColor $Colors.Red
    $script:Errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor $Colors.Red }

    exit 1
}

Write-Log "Deployment completed successfully!" -Level "SUCCESS"

Write-Host ""
Write-Host "Summary:" -ForegroundColor $Colors.Green
Write-Host "  Environment: $Environment" -ForegroundColor $Colors.Green
Write-Host "  Server: $SsasServer" -ForegroundColor $Colors.Green
Write-Host "  Database: $DatabaseName" -ForegroundColor $Colors.Green
Write-Host "  Working BIM: $script:WorkingBimPath" -ForegroundColor $Colors.Green
Write-Host "  Process Type: $ProcessType" -ForegroundColor $Colors.Green
Write-Host "  Duration: $($duration.ToString('mm\:ss'))" -ForegroundColor $Colors.Green

if ($script:ChangesMade.Count -gt 0) {
    Write-Host ""
    Write-Host "Changes Made:" -ForegroundColor $Colors.Cyan
    $script:ChangesMade | ForEach-Object { Write-Host "  ✓ $_" -ForegroundColor $Colors.Green }
}

if ($script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnings:" -ForegroundColor $Colors.Yellow
    $script:Warnings | ForEach-Object { Write-Host "  ! $_" -ForegroundColor $Colors.Yellow }
}

Write-Host ""
Write-Host "Deployment finished at: $script:DeploymentEndTime" -ForegroundColor $Colors.Cyan

exit 0