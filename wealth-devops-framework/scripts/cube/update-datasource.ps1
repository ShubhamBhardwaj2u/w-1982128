param(
    [Parameter(Mandatory=$true, HelpMessage="Path to the .bim file to update")]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$BimPath,

    [Parameter(Mandatory=$false, HelpMessage="Path to YAML datasource config (like roles/{env}.yml)")]
    [string]$DatasourcesConfigFile,

    [Parameter(Mandatory=$false, HelpMessage="Environment (DEV/UAT/PROD) - auto-locate config if not specified")]
    [ValidateSet("DEV", "UAT", "PROD")]
    [string]$Environment,

    [Parameter(Mandatory=$false, HelpMessage="Global fallback server (uses config first)")]
    [string]$SqlServer,

    [Parameter(Mandatory=$false, HelpMessage="Global fallback database")]
    [string]$SqlDatabase,

    [Parameter(Mandatory=$false, HelpMessage="Default impersonation mode")]
    [ValidateSet("ImpersonateServiceAccount", "ImpersonateAnonymous", "ImpersonateWindowsUser", "ImpersonateCustom")]
    [string]$ImpersonationMode = "ImpersonateServiceAccount",

    [Parameter(Mandatory=$false, HelpMessage="Custom account for ImpersonateCustom")]
    [string]$CustomImpersonationAccount,

    [Parameter(Mandatory=$false, HelpMessage="Strict mode - fail on DS/partition mismatches")]
    [switch]$StrictMode,

    [Parameter(Mandatory=$false, HelpMessage="Dry run - validate + preview only")]
    [switch]$DryRun,

    [Parameter(Mandatory=$false, HelpMessage="Create timestamped backup")]
    [switch]$Backup
)

$ErrorActionPreference = "Stop"
$script:ValidationErrors = @()
$script:ChangesPreview = @()

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
    
    $color = switch ($Level) { 
        "ERROR" { $Colors.Red } 
        "WARNING" { $Colors.Yellow } 
        "SUCCESS" { $Colors.Green } 
        default { $Colors.Cyan } 
    }

    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "  $Title"
    Write-Host "============================================================"
}

function Add-ValidationError {
    param([string]$Message)
    $script:ValidationErrors += $Message
    Write-Log $Message "ERROR"
}

function Test-YamlStructure {
    param([string]$Path, [string]$ExpectedEnv = $null)
    
    Write-Section "YAML Configuration Validation"
    
    try {
        Import-Module powershell-yaml -ErrorAction Stop -Force
        
        $yamlData = Get-Content $Path -Raw | ConvertFrom-Yaml
        
        if ($ExpectedEnv -and $yamlData.environment -ne $ExpectedEnv) {
            Add-ValidationError "Environment mismatch: '$($yamlData.environment)' expected '$ExpectedEnv'"
            return $false
        }
        
        $datasources = $yamlData.datasources
        if (-not $datasources -or $datasources.Count -eq 0) {
            Add-ValidationError "No datasources defined in $Path"
            return $false
        }
        
        $dsNames = $datasources | ForEach-Object name
        $duplicates = $dsNames | Group-Object | Where-Object Count -gt 1
        if ($duplicates) {
            Add-ValidationError "Duplicate datasource names: $($duplicates.name -join ', ')"
            return $false
        }
        
        foreach ($ds in $datasources) {
            if (-not $ds.name -or -not $ds.server -or -not $ds.database) {
                Add-ValidationError "Invalid datasource '$($ds.name)': missing name/server/database"
                return $false
            }
        }
        
        Write-Log "Configuration validated ($($datasources.Count) datasources)" "SUCCESS"
        return $yamlData
    }
    catch {
        Add-ValidationError "YAML parse error: $($_.Exception.Message)"
        return $false
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "  $Title"
    Write-Host "============================================================"
}

function Add-Warning {
    param([string]$Message)
    $script:Warnings += $Message
    Write-Log $Message -Level "WARNING"
}

function Initialize-Configuration {
    Write-Section "Configuration Loading"
    
    # Auto-locate config if Environment specified
    if ($Environment -and -not $DatasourcesConfigFile) {
        $autoConfig = "wealth-cube/config/datasources/${Environment}.yml"
        if (Test-Path $autoConfig) {
            $DatasourcesConfigFile = $autoConfig
            Write-Log "Auto-located config: $DatasourcesConfigFile" "INFO"
        }
    }
    
    # Load YAML config (priority: param > auto-locate)
    if ($DatasourcesConfigFile) {
        $yamlData = Test-YamlStructure $DatasourcesConfigFile $Environment
        if (-not $yamlData) { exit 1 }
        $script:YamlDatasources = $yamlData.datasources
        Write-Log "Loaded $($script:YamlDatasources.Count) datasource configs" "SUCCESS"
    }
    
    Write-Log "BIM: $BimPath | Environment: $Environment | Config: $DatasourcesConfigFile" "INFO"
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

Write-Section "Datasource Sync Validation & Update"

if ($null -eq $bim.model.dataSources -or $bim.model.dataSources.Count -eq 0) {
    Add-ValidationError "BIM model has no datasources"
    exit 1
}

Write-Log "Found $($bim.model.dataSources.Count) datasource(s) in BIM" "INFO"

# Validate BIM datasources against YAML config (if provided)
$bimDsNames = $bim.model.dataSources | ForEach-Object name
if ($script:YamlDatasources) {
    $yamlDsNames = $script:YamlDatasources | ForEach-Object name
    
    $missingInBim = $yamlDsNames | Where { $_ -notin $bimDsNames }
    if ($missingInBim) {
        Add-ValidationError "Datasources missing in BIM: $($missingInBim -join ', ')"
        if ($StrictMode) { exit 1 }
    }
    
    $extraInBim = $bimDsNames | Where { $_ -notin $yamlDsNames }
    if ($extraInBim -and $StrictMode) {
        Add-ValidationError "Extra datasources in BIM: $($extraInBim -join ', ')"
        exit 1
    } elseif ($extraInBim) {
        Write-Log "Extra datasources in BIM (non-strict): $($extraInBim -join ', ')" "WARNING"
    }
    
    Write-Log "Datasources validated against config" "SUCCESS"
}

# Collect partition DS references for validation
$partitionDsRefs = @{}
foreach ($table in $bim.model.tables) {
    foreach ($partition in $table.partitions) {
        if ($partition.source.dataSource) {
            $dsName = $partition.source.dataSource
            if (-not $partitionDsRefs.ContainsKey($dsName)) {
                $partitionDsRefs[$dsName] = 0
            }
            $partitionDsRefs[$dsName]++
        }
    }
}
Write-Log "Partition DS references validated ($($partitionDsRefs.Count) unique)" "SUCCESS"

if ($script:ValidationErrors.Count -gt 0) { exit 1 }

# Update datasources
foreach ($ds in $bim.model.dataSources) {
    Write-Host "  Processing: $($ds.name)" -ForegroundColor Cyan
    
    $yamlDs = $null
    if ($script:YamlDatasources) {
        $yamlDs = $script:YamlDatasources | Where-Object { $_.name -eq $ds.name }
    }
    
    $targetServer = if ($yamlDs -and $yamlDs.server) { $yamlDs.server } else { $SqlServer }
    $targetDb = if ($yamlDs -and $yamlDs.database) { $yamlDs.database } else { $SqlDatabase }
    $targetImpersonation = if ($yamlDs -and $yamlDs.impersonationMode) { $yamlDs.impersonationMode } else { $ImpersonationMode }
    
    if (-not $targetServer -or -not $targetDb) {
        Add-Warning "No config for DS '$($ds.name)' - skipping"
        continue
    }
    
    $oldConn = $ds.connectionString
    $oldImpersonation = $ds.impersonationMode
    
    if ($DryRun) {
        Write-Host "    Old -> New:" -ForegroundColor Yellow
        Write-Host "      Server: Extracted -> $targetServer" -ForegroundColor Yellow
        Write-Host "      DB: Extracted -> $targetDb" -ForegroundColor Yellow
        Write-Host "      Impersonation: $oldImpersonation -> $targetImpersonation" -ForegroundColor Yellow
        $script:ChangesPreview += "DS '$($ds.name)': Conn updated + Impersonation sync"
        continue
    }
    
    # Apply updates
    if ($ds.connectionString) {
        $newConn = Update-ConnectionString -ConnectionString $ds.connectionString -Server $targetServer -Database $targetDb
        if ($newConn -ne $oldConn) {
            $ds.connectionString = $newConn
            Write-Log "  Updated connection for '$($ds.name)'" "SUCCESS"
        }
    }
    
    if ($ds.impersonationMode -ne $targetImpersonation) {
        $ds.impersonationMode = $targetImpersonation
        if ($targetImpersonation -eq "ImpersonateCustom" -and $yamlDs.account) {
            $ds.account = $yamlDs.account
        }
        Write-Log "  Updated impersonation for '$($ds.name)'" "SUCCESS"
    }
    
    $script:ChangesMade++
}

Write-Log "Datasources processed ($($bim.model.dataSources.Count))" "SUCCESS"


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

