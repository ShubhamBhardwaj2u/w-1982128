param(
    [Parameter(Mandatory=$true)]
    [string]$BimPath,

    [Parameter(Mandatory=$true)]
    [string]$DatasourcesConfigFile,

    [Parameter(Mandatory=$true)]
    [ValidateSet("DEV", "UAT", "PROD")]
    [string]$Environment,

    [switch]$StrictMode,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$script:ValidationErrors = @()
$script:Warnings = @()
$script:ChangesMade = 0
$script:PreviewChanges = 0
$script:YamlDatasources = @()

$script:Colors = @{
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
        "ERROR" { $script:Colors.Red } 
        "WARNING" { $script:Colors.Yellow } 
        "SUCCESS" { $script:Colors.Green } 
        default { $script:Colors.Cyan } 
    }

    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}


function Add-ValidationError {
    param([string]$Message)
    $script:ValidationErrors += $Message
    Write-Log $Message "ERROR"
}

function Initialize-YamlModule {
    Write-Section "YAML Module Initialization"

    try {
        if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
            Install-Module -Name powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
            Write-Log "Installed powershell-yaml module" "SUCCESS"
        }

        Import-Module -Name powershell-yaml -Force -ErrorAction Stop
        Write-Log "Loaded powershell-yaml module" "SUCCESS"
    }
    catch {
        Add-ValidationError "Failed to initialize powershell-yaml module: $($_.Exception.Message)"
        exit 1
    }
}

function Test-YamlStructure {
    param([string]$Path, [string]$ExpectedEnv = $null)
    
    Write-Section "YAML Configuration Validation"
    
    try {
        
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
        
        $dsNamesLower = $datasources | ForEach-Object { $_.name.Trim().ToLower() }
        $duplicates = $dsNamesLower | Group-Object | Where-Object Count -gt 1
        if ($duplicates) {
            Add-ValidationError "Duplicate datasource names (case-insensitive): $($duplicates.name -join ', ')"
            return $false
        }
        
        foreach ($ds in $datasources) {
            if ([string]::IsNullOrWhiteSpace($ds.name) -or
                [string]::IsNullOrWhiteSpace($ds.server) -or
                [string]::IsNullOrWhiteSpace($ds.database)) {
                Add-ValidationError "Invalid datasource '$($ds.name)': missing name/server/database"
                return $false
            }
        }

        if ($script:ValidationErrors.Count -gt 0) {
            return $false
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
    Write-Log $Message "WARNING"
}

function Initialize-Configuration {
    Write-Section "Configuration Loading"
    
    # Auto-locate config if Environment specified
    if (-not (Test-Path $DatasourcesConfigFile)) {
        Add-ValidationError "Datasources config file not found: $DatasourcesConfigFile"
    }
    if (-not (Test-Path $BimPath)) {
        Add-ValidationError "BIM file not found: $BimPath"
    }
    if ($script:ValidationErrors.Count -gt 0) {
        exit 1
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
    
    if ($result -match "(?i)(Data Source\s*=\s*)([^;]*)") { 
        $result = $result -replace "(?i)(Data Source\s*=\s*)[^;]*", "`$1$Server" 
    }
    
    if ($result -match "(?i)(Initial Catalog\s*=\s*)([^;]*)") { 
        $result = $result -replace "(?i)(Initial Catalog\s*=\s*)[^;]*", "`$1$Database" 
    }
    
    return $result
}

function Update-Datasources {
    param(
        [object]$BimModel,
        [array]$YamlDatasources,
        [switch]$DryRun
    )

    Write-Section "Datasource Update"

    foreach ($ds in $BimModel.model.dataSources) {
        Write-Host ""
        Write-Host "Datasource: $($ds.name)" -ForegroundColor $script:Colors.White
        Write-Host "------------------------------------------------------------"

        $yamlDs = $YamlDatasources | Where-Object { $_.name.Trim().ToLower() -eq $ds.name.Trim().ToLower() } | Select-Object -First 1

        if (-not $yamlDs) {
            Add-Warning "No YAML configuration found for datasource '$($ds.name)'. Skipping."
            continue
        }

        $targetServer = $yamlDs.server
        $targetDatabase = $yamlDs.database
        $targetImpersonation = "impersonateServiceAccount"

        $oldConn = $ds.connectionString
        $oldImpersonation = $ds.impersonationMode
        $newConn = Update-ConnectionString -ConnectionString $oldConn -Server $targetServer -Database $targetDatabase

        if (-not [string]::IsNullOrWhiteSpace($oldConn) -and $newConn -eq $oldConn) {
            Add-Warning "Connection string for datasource '$($ds.name)' was not modified. Verify it contains datasource and database properties in expected SQL connection string format."
        }

        if ($DryRun) {
            Write-Host "Old Connection String:" -ForegroundColor Yellow
            Write-Host "  $oldConn" -ForegroundColor Yellow
            Write-Host "New Connection String:" -ForegroundColor Green
            Write-Host "  $newConn" -ForegroundColor Green
            Write-Host "Impersonation: $oldImpersonation -> $targetImpersonation" -ForegroundColor Cyan
        
            if ($newConn -ne $oldConn -or $oldImpersonation -ne $targetImpersonation) {
                $script:PreviewChanges++
            }
        
            continue
        }

        $changed = $false

        if ($newConn -ne $oldConn) {
            $ds.connectionString = $newConn
            $changed = $true
            Write-Log "Updated connection string for datasource '$($ds.name)'" "SUCCESS"
        }

        if ($ds.impersonationMode -ne $targetImpersonation) {
            $ds.impersonationMode = $targetImpersonation
            $changed = $true
            Write-Log "Updated impersonation mode for datasource '$($ds.name)' to impersonateServiceAccount" "SUCCESS"
        }

        if ($changed) {
            $script:ChangesMade++
        }
        else {
            Write-Log "No change required for datasource '$($ds.name)'" "INFO"
        }
    }
}

function Save-Bim {
    param(
        [object]$BimModel,
        [string]$BimPath
    )

    Write-Section "Saving Updated BIM"

    try {
        $BimModel | ConvertTo-Json -Depth 200 | Set-Content -Path $BimPath -Encoding UTF8 -NoNewline
        Write-Log "BIM file updated successfully: $BimPath" "SUCCESS"
    }
    catch {
        Add-ValidationError "Failed to save BIM file: $($_.Exception.Message)"
        exit 1
    }
}


Write-Host ""
Write-Host "============================================================" -ForegroundColor $script:Colors.Cyan
Write-Host "  SSAS Datasource Update Tool v3.0" -ForegroundColor $script:Colors.Cyan
Write-Host "============================================================" -ForegroundColor $script:Colors.Cyan

#initialize YAML Module
Initialize-YamlModule

# Initialize configuration (loads from config file if provided)
Initialize-Configuration

Write-Section "Loading BIM Model"

Write-Log "Loading model from: $BimPath" "INFO"
try {
    $json = Get-Content $BimPath -Raw
    $bim = $json | ConvertFrom-Json
    Write-Log "Model loaded: $($bim.name)" "SUCCESS"
}
catch {
    Add-ValidationError "Failed to load BIM JSON: $($_.Exception.Message)"
    exit 1
}

if (-not $bim.model -or -not $bim.model.dataSources -or $bim.model.dataSources.Count -eq 0) {
    Add-ValidationError "BIM model has no datasources defined."
    exit 1
}

Write-Section "Datasource Sync Validation & Update"

Write-Log "Found $($bim.model.dataSources.Count) datasource(s) in BIM" "INFO"

# Validate BIM datasources against YAML config (if provided)
$bimDsNames = @($bim.model.dataSources | ForEach-Object { $_.name.Trim() })
Write-Section "Datasource Sync Validation"

if (-not $script:YamlDatasources) {
    Add-ValidationError "No YAML datasources loaded"
    exit 1
}

if ($script:ValidationErrors.Count -gt 0) { exit 1 }

$yamlDsNames = @($script:YamlDatasources | ForEach-Object { $_.name.Trim() })
$bimDsNames  = @($bim.model.dataSources | ForEach-Object { $_.name.Trim() })

$yamlDsNamesLower = @($yamlDsNames | ForEach-Object { $_.ToLower() })
$bimDsNamesLower  = @($bimDsNames  | ForEach-Object { $_.ToLower() })

$missingInBim = $yamlDsNames | Where-Object { $_.ToLower() -notin $bimDsNamesLower }
if ($missingInBim) {
    Add-ValidationError "YAML datasources missing in BIM: $($missingInBim -join ', ')"
}

$extraInBim = $bimDsNames | Where-Object { $_.ToLower() -notin $yamlDsNamesLower }
if ($extraInBim) {
    $msg = "Extra datasources in BIM: $($extraInBim -join ', ')"
    if ($StrictMode) {
        Add-ValidationError $msg
    } else {
        Add-Warning $msg
    }
}

if ($script:ValidationErrors.Count -gt 0) { exit 1 }

Write-Log "Datasources sync validated" "SUCCESS"

Update-Datasources -BimModel $bim -YamlDatasources $script:YamlDatasources -DryRun:$DryRun


if (-not $DryRun) {
    Save-Bim -BimModel $bim -BimPath $BimPath
}

Write-Section "Update Complete"

if ($DryRun) { Write-Log "DRY RUN: No actual changes were made" -Level "WARNING" }
if ($script:ChangesMade -gt 0) { Write-Log "Datasource(s) updated: $script:ChangesMade" -Level "SUCCESS" }
else { Write-Log "No changes were required" -Level "INFO" }

Write-Host ""
Write-Host "Summary:" -ForegroundColor $script:Colors.Green
Write-Host "  BIM Path: $BimPath" -ForegroundColor $script:Colors.Green
Write-Host "  Config File: $DatasourcesConfigFile" -ForegroundColor $script:Colors.Green
Write-Host "  Environment: $Environment" -ForegroundColor $script:Colors.Green
Write-Host "  Datasources Updated: $script:ChangesMade" -ForegroundColor $script:Colors.Green
Write-Host "  Preview Changes: $script:PreviewChanges" -ForegroundColor $script:Colors.Green
Write-Host "  Warnings: $($script:Warnings.Count)" -ForegroundColor $script:Colors.Green
Write-Host "  Impersonation Mode: impersonateServiceAccount" -ForegroundColor $script:Colors.Green


if ($script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnings:" -ForegroundColor $script:Colors.Yellow
    foreach ($warning in $script:Warnings) {
        Write-Host "  - $warning" -ForegroundColor $script:Colors.Yellow
    }
}


exit 0

