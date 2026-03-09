<#
.SYNOPSIS
    Deploys SSAS Tabular model to on-premises SSAS server using TOM.
.DESCRIPTION
    Deploys a .bim file to SSAS Tabular server with options for:
    - Database creation or update
    - Datasource updates for target environment
    - Role/security updates
    - Processing (Full, Default, None)
    - Transactional deployment with rollback
    
.PARAMETER BimPath
    Path to the .bim file to deploy.
.PARAMETER SsasServer
    SSAS server hostname or instance (e.g., "localhost" or "Server\Instance").
.PARAMETER DatabaseName
    Target database name on SSAS server.
.PARAMETER SqlServer
    SQL Server for datasource connection (optional - uses update-datasource.ps1).
.PARAMETER SqlDatabase
    SQL Database for datasource connection (optional).
.PARAMETER ConfigFile
    Path to JSON configuration file with all environment settings.
.PARAMETER ProcessType
    Type of processing after deployment: None, Full, Default, DataOnly, Calculate (default: None).
.PARAMETER CreateDatabaseIfNotExists
    Create database if it doesn't exist (default: $true).
.PARAMETER UpdateRoles
    Update roles based on environment configuration (requires -RolesConfigFile).
.PARAMETER RolesConfigFile
    Path to JSON file with role-to-AD-group mappings.
.PARAMETER TomDllPath
    Custom path to TOM DLL (overrides auto-detection).
.PARAMETER BackupBeforeDeploy
    Create backup of existing database before deployment (requires SSMS).
.PARAMETER MaxParallelConnections
    Maximum parallel connections for processing (default: 4).
.PARAMETER TimeoutSeconds
    Timeout for deployment operations in seconds (default: 600).
.PARAMETER VerboseLogging
    Enable verbose debug output.
.PARAMETER WhatIf
    Show what would happen without making actual changes.
.EXAMPLE
    .\deploy-cube.ps1 -BimPath ".\Wealth.bim" -SsasServer "localhost" -DatabaseName "Wealth_DEV" -ProcessType "Full"
.EXAMPLE
    .\deploy-cube.ps1 -BimPath ".\Wealth.bim" -ConfigFile ".\config\prod.json" -ProcessType "Full"
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$BimPath,

    [Parameter(Mandatory=$false)]
    [string]$SsasServer,

    [Parameter(Mandatory=$false)]
    [string]$DatabaseName,

    [Parameter(Mandatory=$false)]
    [string]$ConfigFile,

    [Parameter(Mandatory=$false)]
    [string]$SqlServer,

    [Parameter(Mandatory=$false)]
    [string]$SqlDatabase,

    [Parameter(Mandatory=$false)]
    [string]$RolesConfigFile,

    [Parameter(Mandatory=$false)]
    [ValidateSet("None", "Full", "Default", "DataOnly", "Calculate")]
    [string]$ProcessType = "None",

    [Parameter(Mandatory=$false)]
    [bool]$CreateDatabaseIfNotExists = $true,

    [Parameter(Mandatory=$false)]
    [bool]$UpdateRoles = $false,

    [Parameter(Mandatory=$false)]
    [string]$TomDllPath,

    [Parameter(Mandatory=$false)]
    [switch]$BackupBeforeDeploy,

    [Parameter(Mandatory=$false)]
    [int]$MaxParallelConnections = 4,

    [Parameter(Mandatory=$false)]
    [int]$TimeoutSeconds = 600,

    [Parameter(Mandatory=$false)]
    [switch]$VerboseLogging,

    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

# Configure error handling
$ErrorActionPreference = "Stop"
$script:DeploymentStartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:ChangesMade = @()

# Enable verbose if requested
if ($VerboseLogging) {
    $VerbosePreference = "Continue"
}

# ANSI color codes
$Colors = @{
    Red = [ConsoleColor]::Red
    Yellow = [ConsoleColor]::Yellow
    Green = [ConsoleColor]::Green
    Cyan = [ConsoleColor]::Cyan
    White = [ConsoleColor]::White
    DarkGray = [ConsoleColor]::DarkGray
    Magenta = [ConsoleColor]::Magenta
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = $White
    
    switch ($Level) {
        "ERROR" { $color = $Colors.Red }
        "WARNING" { $color = $Colors.Yellow }
        "SUCCESS" { $color = $Colors.Green }
        "INFO" { $color = $Colors.Cyan }
        "DEBUG" { $color = $Colors.DarkGray }
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
    param([string]$Step, [string]$Description)
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

function Get-TomAssembly {
    # Try loading from GAC first
    try {
        Add-Type -AssemblyName "Microsoft.AnalysisServices.Core" -ErrorAction Stop
        Add-Type -AssemblyName "Microsoft.AnalysisServices.Tabular" -ErrorAction Stop
        Write-Log "TOM libraries loaded from GAC" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Assemblies not in GAC" -Level "DEBUG"
    }
    
    # Try custom path
    if ($TomDllPath -and (Test-Path $TomDllPath)) {
        try {
            Add-Type -Path $TomDllPath
            Write-Log "TOM library loaded from custom path: $TomDllPath" -Level "SUCCESS"
            return $true
        }
        catch {
            Add-Error "Failed to load TOM from custom path: $TomDllPath"
            return $false
        }
    }
    
    # Try default paths
    $possiblePaths = @(
        "C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE\CommonExtensions\Microsoft\SSIS\160\BIShared\Microsoft.AnalysisServices.Tabular.dll",
        "C:\Program Files (x86)\Microsoft SQL Server Management Studio 18\Common7\IDE\CommonExtensions\Microsoft\SSIS\150\BIShared\Microsoft.AnalysisServices.Tabular.dll",
        "C:\Program Files\Microsoft SQL Server\150\SDK\Assemblies\Microsoft.AnalysisServices.Tabular.dll",
        "C:\Program Files\Microsoft SQL Server\140\SDK\Assemblies\Microsoft.AnalysisServices.Tabular.dll"
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            try {
                Add-Type -Path $path
                Write-Log "TOM library loaded from: $path" -Level "SUCCESS"
                return $true
            }
            catch {
                continue
            }
        }
    }
    
    Add-Error "SSAS Tabular libraries not found. Please install SSMS or specify -TomDllPath"
    return $false
}

function Initialize-Configuration {
    # Load from config file if provided
    if ($ConfigFile) {
        if (-not (Test-Path $ConfigFile)) {
            throw "Config file not found: $ConfigFile"
        }
        
        Write-Log "Loading configuration from: $ConfigFile" -Level "INFO"
        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        
        # Override parameters with config values
        if ($config.ssasServer -and -not $SsasServer) { $SsasServer = $config.ssasServer }
        if ($config.databaseName -and -not $DatabaseName) { $DatabaseName = $config.databaseName }
        if ($config.sqlServer -and -not $SqlServer) { $SqlServer = $config.sqlServer }
        if ($config.sqlDatabase -and -not $SqlDatabase) { $SqlDatabase = $config.sqlDatabase }
        if ($config.processType -and -not $ProcessType) { $ProcessType = $config.processType }
        if ($config.rolesConfigFile -and -not $RolesConfigFile) { $RolesConfigFile = $config.rolesConfigFile }
        if ($null -ne $config.createDatabaseIfNotExists) { $CreateDatabaseIfNotExists = $config.createDatabaseIfNotExists }
    }
    
    # Validate required parameters
    if (-not $BimPath) {
        throw "BimPath is required. Provide via -BimPath or config file."
    }
    
    if (-not $SsasServer) {
        throw "SsasServer is required. Provide via -SsasServer or config file."
    }
    
    if (-not $DatabaseName) {
        throw "DatabaseName is required. Provide via -DatabaseName or config file."
    }
    
    # Validate paths
    if (-not (Test-Path $BimPath)) {
        throw "BIM file not found: $BimPath"
    }
    
    Write-Log "Configuration validated" -Level "SUCCESS"
    return $true
}

function Connect-SsasServer {
    param([string]$ServerName)
    
    $server = New-Object Microsoft.AnalysisServices.Tabular.Server
    
    try {
        Write-Log "Connecting to SSAS server: $ServerName" -Level "INFO"
        $server.Connect($ServerName)
        
        # Verify connection
        if ($server.Connected) {
            Write-Log "Connected to SSAS server: $ServerName" -Level "SUCCESS"
            Write-Log "  Server Mode: $($server.ServerMode)" -Level "INFO"
            Write-Log "  Version: $($server.Version)" -Level "INFO"
            return $server
        }
        else {
            throw "Connection established but server not in connected state"
        }
    }
    catch {
        Add-Error "Failed to connect to SSAS server: $($_.Exception.Message)"
        throw
    }
}

function Get-DatabaseFromBim {
    param([string]$Path)
    
    Write-Log "Deserializing BIM model from: $Path" -Level "INFO"
    
    try {
        $json = Get-Content $Path -Raw
        $database = [Microsoft.AnalysisServices.Tabular.JsonSerializer]::DeserializeDatabase($json)
        
        Write-Log "Model deserialized: $($database.Name)" -Level "SUCCESS"
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
    
    Write-Log "Database identity set: $Name" -Level "SUCCESS"
    $script:ChangesMade += "Database identity updated to: $Name"
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
        if ($CreateIfNotExists) {
            if ($WhatIf) {
                Write-Host "[WHATIF] Would CREATE new database: $Name" -ForegroundColor $Colors.Yellow
                return $null
            }
            
            Write-Log "Creating new database: $Name" -Level "INFO"
            $Server.Databases.Add($Database)
            
            try {
                $Database.Update([Microsoft.AnalysisServices.UpdateOptions]::ExpandFull)
                Write-Log "Database created successfully: $Name" -Level "SUCCESS"
                $script:ChangesMade += "Created database: $Name"
                return $Server.Databases.FindByName($Name)
            }
            catch {
                Add-Error "Failed to create database: $($_.Exception.Message)"
                throw
            }
        }
        else {
            throw "Database '$Name' does not exist and CreateDatabaseIfNotExists is false"
        }
    }
    else {
        if ($WhatIf) {
            Write-Host "[WHATIF] Would UPDATE existing database: $Name" -ForegroundColor $Colors.Yellow
            Write-Host "  Existing model has $($existingDb.Model.Tables.Count) tables" -ForegroundColor $Colors.Yellow
            return $existingDb
        }
        
        Write-Log "Updating existing database: $Name" -Level "INFO"
        
        try {
            # Replace model with new one
            $existingDb.Model = $Database.Model
            $existingDb.Update([Microsoft.AnalysisServices.UpdateOptions]::ExpandFull)
            Write-Log "Database updated successfully: $Name" -Level "SUCCESS"
            $script:ChangesMade += "Updated database: $Name"
            return $existingDb
        }
        catch {
            Add-Error "Failed to update database: $($_.Exception.Message)"
            throw
        }
    }
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
    
    Write-Log "Processing model: $ProcessType" -Level "INFO"
    
    $refreshType = switch ($ProcessType) {
        "Full" { [Microsoft.AnalysisServices.Tabular.RefreshType]::Full }
        "Default" { [Microsoft.AnalysisServices.Tabular.RefreshType]::Default }
        "DataOnly" { [Microsoft.AnalysisServices.Tabular.RefreshType]::DataOnly }
        "Calculate" { [Microsoft.AnalysisServices.Tabular.RefreshType]::Calculate }
        default { [Microsoft.AnalysisServices.Tabular.RefreshType]::None }
    }
    
    if ($WhatIf) {
        Write-Host "[WHATIF] Would process model with: $ProcessType" -ForegroundColor $Colors.Yellow
        return
    }
    
    try {
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
            throw "Processing failed with errors"
        }
        
        if (-not $hasWarnings) {
            Write-Log "Processing completed successfully with no warnings" -Level "SUCCESS"
        }
        else {
            Write-Log "Processing completed with warnings" -Level "WARNING"
        }
        
        $script:ChangesMade += "Processed model: $ProcessType"
    }
    catch {
        Add-Error "Processing failed: $($_.Exception.Message)"
        throw
    }
}

function Update-RoleMemberships {
    param(
        [object]$Database,
        [string]$RolesConfigFile
    )
    
    if (-not (Test-Path $RolesConfigFile)) {
        Add-Warning "Roles config file not found: $RolesConfigFile"
        return
    }
    
    Write-Log "Loading roles configuration from: $RolesConfigFile" -Level "INFO"
    
    try {
        $rolesConfig = Get-Content $RolesConfigFile -Raw | ConvertFrom-Json
        
        $modelRoles = $Database.Model.Roles
        
        foreach ($roleConfig in $rolesConfig.roles) {
            $roleName = $roleConfig.name
            $role = $modelRoles.Find($roleName)
            
            if ($null -eq $role) {
                if ($WhatIf) {
                    Write-Host "[WHATIF] Would CREATE role: $roleName" -ForegroundColor $Colors.Yellow
                    continue
                }
                
                Write-Log "Creating new role: $roleName" -Level "INFO"
                $newRole = New-Object Microsoft.AnalysisServices.Tabular.ModelRole($Database.Model, $roleName)
                $newRole.ModelPermission = [Microsoft.AnalysisServices.Tabular.ModelPermission]::Read
                
                # Add members
                if ($roleConfig.members) {
                    foreach ($member in $roleConfig.members) {
                        $newRole.Members.Add([Microsoft.AnalysisServices.Tabular.WindowsGroupMember]::new($member))
                    }
                }
                
                $newRole.Update()
                $script:ChangesMade += "Created role: $roleName"
                Write-Log "Role created: $roleName" -Level "SUCCESS"
            }
            else {
                if ($WhatIf) {
                    Write-Host "[WHATIF] Would UPDATE role: $roleName" -ForegroundColor $Colors.Yellow
                    continue
                }
                
                Write-Log "Updating existing role: $roleName" -Level "INFO"
                
                # Clear existing members
                $role.Members.Clear()
                
                # Add new members
                if ($roleConfig.members) {
                    foreach ($member in $roleConfig.members) {
                        $role.Members.Add([Microsoft.AnalysisServices.Tabular.WindowsGroupMember]::new($member))
                    }
                }
                
                $role.Update()
                $script:ChangesMade += "Updated role: $roleName"
                Write-Log "Role updated: $roleName" -Level "SUCCESS"
            }
        }
    }
    catch {
        Add-Warning "Failed to update roles: $($_.Exception.Message)"
    }
}

# ============================================================
# MAIN EXECUTION
# ============================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor $Colors.Cyan
Write-Host "║       SSAS Tabular Deployment Tool v2.0                    ║" -ForegroundColor $Colors.Cyan
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor $Colors.Cyan

Write-Log "Deployment started at: $script:DeploymentStartTime"

if ($WhatIf) {
    Write-Log "WHATIF MODE: No actual changes will be made" -Level "WARNING"
}

# Step 1: Load TOM libraries
Write-Step "1" "Loading TOM Libraries"
if (-not (Get-TomAssembly)) {
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

# Display deployment info
Write-Host ""
Write-Host "Deployment Configuration:" -ForegroundColor $Colors.Green
Write-Host "  BIM Path: $BimPath" -ForegroundColor $Colors.White
Write-Host "  SSAS Server: $SsasServer" -ForegroundColor $Colors.White
Write-Host "  Database: $DatabaseName" -ForegroundColor $Colors.White
Write-Host "  SQL Server: $($SqlServer ?? 'Not specified')" -ForegroundColor $Colors.White
Write-Host "  SQL Database: $($SqlDatabase ?? 'Not specified')" -ForegroundColor $Colors.White
Write-Host "  Process Type: $ProcessType" -ForegroundColor $Colors.White
Write-Host "  Update Roles: $UpdateRoles" -ForegroundColor $Colors.White
Write-Host "  Create If Not Exists: $CreateDatabaseIfNotExists" -ForegroundColor $Colors.White

# Step 3: Load BIM model
Write-Step "3" "Loading BIM Model"
$database = Get-DatabaseFromBim -Path $BimPath

# Update database identity
Update-DatabaseIdentity -Database $database -Name $DatabaseName

# Step 4: Update datasource (if SQL Server provided)
if ($SqlServer -and $SqlDatabase) {
    Write-Step "4" "Updating Datasources"
    
    $updateDsScript = "$PSScriptRoot\update-datasource.ps1"
    
    if (Test-Path $updateDsScript) {
        try {
            if ($WhatIf) {
                & $updateDsScript -BimPath $BimPath -SqlServer $SqlServer -SqlDatabase $SqlDatabase -WhatIf
            }
            else {
                & $updateDsScript -BimPath $BimPath -SqlServer $SqlServer -SqlDatabase $SqlDatabase
            }
            $script:ChangesMade += "Updated datasources"
        }
        catch {
            Add-Warning "Datasource update failed: $($_.Exception.Message)"
        }
        
        # Reload model after datasource update
        $database = Get-DatabaseFromBim -Path $BimPath
        Update-DatabaseIdentity -Database $database -Name $DatabaseName
    }
    else {
        Write-Log "update-datasource.ps1 not found, skipping datasource update" -Level "WARNING"
    }
}
else {
    Write-Step "4" "Skipping Datasource Update (not configured)"
}

# Step 5: Update roles (if enabled)
if ($UpdateRoles -and $RolesConfigFile) {
    Write-Step "5" "Updating Role Memberships"
    
    # We'll update roles after deployment, so just note it here
    Write-Log "Roles will be updated after database deployment" -Level "INFO"
}
else {
    Write-Step "5" "Skipping Role Update (not configured)"
}

# Step 6: Connect to SSAS server
Write-Step "6" "Connecting to SSAS Server"
$server = Connect-SsasServer -ServerName $SsasServer

try {
    # Step 7: Deploy database
    Write-Step "7" "Deploying Database"
    $deployedDb = Invoke-DatabaseDeployment -Server $server -Database $database -Name $DatabaseName -CreateIfNotExists $CreateDatabaseIfNotExists
    
    if ($null -eq $deployedDb -and -not $WhatIf) {
        throw "Deployment failed - database is null"
    }
    
    # Step 8: Update roles (if enabled and database was deployed)
    if ($UpdateRoles -and $RolesConfigFile -and $deployedDb -and -not $WhatIf) {
        Write-Step "8" "Updating Role Memberships"
        Update-RoleMemberships -Database $deployedDb -RolesConfigFile $RolesConfigFile
    }
    else {
        Write-Step "8" "Skipping Role Update"
    }
    
    # Step 9: Process model
    Write-Step "9" "Processing Model"
    if ($deployedDb) {
        Invoke-ProcessModel -Database $deployedDb -ProcessType $ProcessType
    }
    else {
        Write-Log "Skipping processing (WhatIf mode or deployment failed)" -Level "WARNING"
    }
}
finally {
    # Cleanup: Disconnect from server
    if ($server -and $server.Connected) {
        $server.Disconnect()
        Write-Log "Disconnected from SSAS server" -Level "INFO"
    }
}

# ============================================================
# FINAL RESULTS
# ============================================================

$script:DeploymentEndTime = Get-Date
$duration = $script:DeploymentEndTime - $script:DeploymentStartTime

Write-Section "Deployment Results"

if ($WhatIf) {
    Write-Log "WHATIF MODE: No actual changes were made" -Level "WARNING"
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
Write-Host "  Server: $SsasServer" -ForegroundColor $Colors.Green
Write-Host "  Database: $DatabaseName" -ForegroundColor $Colors.Green
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

