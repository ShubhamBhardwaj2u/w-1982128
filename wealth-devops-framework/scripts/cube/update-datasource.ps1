param(
    [Parameter(Mandatory=$true, HelpMessage="Path to the .bim file to update")]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$BimPath,

    [Parameter(Mandatory=$true, HelpMessage="Path to JSON config file with environment settings")]
    [string]$ConfigFile,

    [Parameter(Mandatory=$false, HelpMessage="Target SQL Server hostname")]
    [string]$SqlServer,

    [Parameter(Mandatory=$false, HelpMessage="Target SQL Server database name")]
    [string]$SqlDatabase,

    [Parameter(Mandatory=$false, HelpMessage="Impersonation mode")]
    [ValidateSet("ImpersonateServiceAccount", "ImpersonateAnonymous", "ImpersonateWindowsUser", "ImpersonateCustom")]
    [string]$ImpersonationMode = "ImpersonateServiceAccount",

    [Parameter(Mandatory=$false, HelpMessage="Custom account for ImpersonateCustom mode")]
    [string]$CustomImpersonationAccount,

    [Parameter(Mandatory=$false, HelpMessage="Create backup before modifying")]
    [switch]$Backup,

    [Parameter(Mandatory=$false, HelpMessage="Show what would be changed")]
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$script:ChangesMade = 0
$script:Warnings = @()

$Colors = @{
    Red = [ConsoleColor]::Red
    Yellow = [ConsoleColor]::Yellow
    Green = [ConsoleColor]::Green
    Cyan = [ConsoleColor]::Cyan
    White = [ConsoleColor]::White
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) { "ERROR" { $Colors.Red } "WARNING" { $Colors.Yellow } "SUCCESS" { $Colors.Green } default { $Colors.Cyan } }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor $Colors.Cyan
    Write-Host "  $Title" -ForegroundColor $Colors.Cyan
    Write-Host "============================================================" -ForegroundColor $Colors.Cyan
}

function Add-Warning {
    param([string]$Message)
    $script:Warnings += $Message
    Write-Log $Message -Level "WARNING"
}

function Initialize-Configuration {
    # Load from config file if provided
    if ($ConfigFile) {
        if (-not (Test-Path $ConfigFile)) { 
            throw "Config file not found: $ConfigFile" 
        }
        
        Write-Log "Loading configuration from: $ConfigFile" -Level "INFO"
        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        
        # Use config values if not provided via command line
        if ($config.PSObject.Properties.Name -contains "sqlServer") {
            if (-not $SqlServer -and $config.sqlServer) { 
                $script:SqlServer = $config.sqlServer 
            }
        }
        if ($config.PSObject.Properties.Name -contains "sqlDatabase") {
            if (-not $SqlDatabase -and $config.sqlDatabase) { 
                $script:SqlDatabase = $config.sqlDatabase 
            }
        }
    }
    
    # Validate required parameters
    if (-not $script:SqlServer) { 
        throw "SqlServer is required. Provide via -SqlServer parameter or in ConfigFile." 
    }
    if (-not $script:SqlDatabase) { 
        throw "SqlDatabase is required. Provide via -SqlDatabase parameter or in ConfigFile." 
    }
    
    Write-Log "Input validation passed" -Level "SUCCESS"
}

function Update-ConnectionString {
    param([string]$ConnectionString, [string]$Server, [string]$Database)
    
    if ([string]::IsNullOrWhiteSpace($ConnectionString)) { 
        return $ConnectionString 
    }
    
    $result = $ConnectionString
    
    # Handle Data Source (with optional whitespace)
    if ($result -match "(Data Source\s*=\s*)([^;]*)") { 
        $result = $result -replace "(Data Source\s*=\s*)[^;]*", "`$1$Server" 
    }
    
    # Handle Initial Catalog
    if ($result -match "(Initial Catalog\s*=\s*)([^;]*)") { 
        $result = $result -replace "(Initial Catalog\s*=\s*)[^;]*", "`$1$Database" 
    }
    
    return $result
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor $Colors.Cyan
Write-Host "  SSAS Datasource Update Tool v2.0" -ForegroundColor $Colors.Cyan
Write-Host "============================================================" -ForegroundColor $Colors.Cyan

# Initialize configuration (loads from config file if provided)
Initialize-Configuration

# Now log the values after configuration is loaded
Write-Log "Target Server: $script:SqlServer"
Write-Log "Target Database: $script:SqlDatabase"

if ($WhatIf) { Write-Log "WHATIF MODE: No changes will be made" -Level "WARNING" }

Write-Section "Loading BIM Model"

if ($Backup -and -not $WhatIf) {
    $backupPath = "$BimPath.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item -Path $BimPath -Destination $backupPath -Force
    Write-Log "Backup created: $backupPath" -Level "SUCCESS"
}

Write-Log "Loading model from: $BimPath" -Level "INFO"
$json = Get-Content $BimPath -Raw
$bim = $json | ConvertFrom-Json
Write-Log "Model loaded: $($bim.name)" -Level "SUCCESS"

Write-Section "Updating Data Sources"

if ($null -eq $bim.model.dataSources -or $bim.model.dataSources.Count -eq 0) {
    Add-Warning "No datasources found in model"
}
else {
    Write-Log "Found $($bim.model.dataSources.Count) datasource(s)" -Level "INFO"
    
    foreach ($ds in $bim.model.dataSources) {
        Write-Host "Processing datasource: $($ds.name)" -ForegroundColor $Colors.White
        
        $oldConnection = $ds.connectionString
        
        if ($WhatIf) {
            Write-Host "  [WHATIF] Would update: $($ds.name)" -ForegroundColor $Colors.Yellow
            Write-Host "    Server: $script:SqlServer" -ForegroundColor $Colors.Yellow
            Write-Host "    Database: $script:SqlDatabase" -ForegroundColor $Colors.Yellow
        }
        else {
            if ($ds.connectionString) {
                $newConnection = Update-ConnectionString -ConnectionString $ds.connectionString -Server $script:SqlServer -Database $script:SqlDatabase
                $ds.connectionString = $newConnection
            }
            $ds.impersonationMode = $ImpersonationMode
            if ($ImpersonationMode -eq "ImpersonateCustom" -and $CustomImpersonationAccount) {
                $ds.account = $CustomImpersonationAccount
            }
            $script:ChangesMade++
        }
    }
}

if (-not $WhatIf) {
    Write-Section "Saving Updated Model"
    try {
        $bim | ConvertTo-Json -Depth 10 | Out-File -FilePath $BimPath -Encoding UTF8 -Force
        Write-Log "Bim file updated: $BimPath" -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed to save bim file: $($_.Exception.Message)" -Level "ERROR"
        exit 1
    }
}

Write-Section "Update Complete"

if ($WhatIf) { Write-Log "WHATIF MODE: No actual changes were made" -Level "WARNING" }
if ($script:ChangesMade -gt 0) { Write-Log "Datasource(s) updated: $script:ChangesMade" -Level "SUCCESS" }
else { Write-Log "No changes were required" -Level "INFO" }

Write-Host ""
Write-Host "Summary:" -ForegroundColor $Colors.Green
Write-Host "  BIM Path: $BimPath" -ForegroundColor $Colors.Green
Write-Host "  SQL Server: $script:SqlServer" -ForegroundColor $Colors.Green
Write-Host "  SQL Database: $script:SqlDatabase" -ForegroundColor $Colors.Green
Write-Host "  Impersonation: $ImpersonationMode" -ForegroundColor $Colors.Green

exit 0

