param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$ModelPath,

    [Parameter(Mandatory=$false)]
    [switch]$StrictMode,

    [Parameter(Mandatory=$false)]
    [int]$MaxSizeMB = 100
)

$ErrorActionPreference = "Stop"
$script:ValidationErrors = @()
$script:ValidationWarnings = @()

$Colors = @{
    Red = [ConsoleColor]::Red
    Yellow = [ConsoleColor]::Yellow
    Green = [ConsoleColor]::Green
    Cyan = [ConsoleColor]::Cyan
    White = [ConsoleColor]::White
    DarkGray = [ConsoleColor]::DarkGray
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = $Colors.White
    
    switch ($Level) {
        "ERROR" { $color = $Colors.Red }
        "WARNING" { $color = $Colors.Yellow }
        "SUCCESS" { $color = $Colors.Green }
        "INFO" { $color = $Colors.Cyan }
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor $Colors.Cyan
    Write-Host "  $Title" -ForegroundColor $Colors.Cyan
    Write-Host "============================================================" -ForegroundColor $Colors.Cyan
}

function Add-ValidationError {
    param([string]$Message)
    $script:ValidationErrors += $Message
    Write-Log "ERROR: $Message" -Level "ERROR"
}

function Add-ValidationWarning {
    param([string]$Message)
    $script:ValidationWarnings += $Message
    Write-Log "WARNING: $Message" -Level "WARNING"
}

function Test-JsonSyntax {
    param([string]$Path)
    
    Write-Section "Step 1: JSON Syntax Validation"
    
    try {
        $content = Get-Content $Path -Raw -ErrorAction Stop
        $null = $content | ConvertFrom-Json -ErrorAction Stop
        Write-Log "JSON syntax is valid" -Level "SUCCESS"
        return $true
    }
    catch {
        Add-ValidationError "Invalid JSON syntax: $($_.Exception.Message)"
        return $false
    }
}

function Test-ModelSchema {
    param([hashtable]$Model)
    
    Write-Section "Step 2: Tabular Model Schema Validation"
    
    $requiredRootProperties = @(
        "name",
        "compatibilityLevel",
        "model"
    )
    
    $missingRootProperties = @()
    
    foreach ($prop in $requiredRootProperties) {
        if (-not $Model.ContainsKey($prop)) {
            $missingRootProperties += $prop
        }
    }
    
    if ($missingRootProperties.Count -gt 0) {
        Add-ValidationError "Missing required root properties: $($missingRootProperties -join ', ')"
        return $false
    }
    
    $modelObj = $Model["model"]
    if ($null -eq $modelObj) {
        Add-ValidationError "Model object is null"
        return $false
    }
    
    if ([string]::IsNullOrWhiteSpace($Model["name"])) {
        Add-ValidationError "Model name cannot be empty"
        return $false
    }

    Write-Log "Root-level properties validated" -Level "SUCCESS"
    Write-Log "Model object present" -Level "SUCCESS"
    return $true
}

function Test-CompatibilityLevel {
    param([int]$Level)
    
    Write-Section "Step 3: Compatibility Level Check"
    
    $validLevels = @(1200, 1400, 1500, 1600)
    
    if ($Level -notin $validLevels) {
        Add-ValidationError "Invalid compatibility level: $Level. Valid levels: $($validLevels -join ', ')"
        return $false
    }
    
    $levelDescription = switch ($Level) {
        1200 { "SQL Server 2016+" }
        1400 { "SQL Server 2017+" }
        1500 { "SQL Server 2019+" }
        1600 { "SQL Server 2022+" }
        default { "Unknown" }
    }
    
    Write-Log "Compatibility Level: $Level ($levelDescription)" -Level "SUCCESS"
    return $true
}

function Test-ModelSize {
    param([string]$Path, [int]$MaxMB)
    
    Write-Section "Step 4: Model Size Validation"
    
    $fileInfo = Get-Item $Path
    $sizeBytes = $fileInfo.Length
    $sizeMB = [math]::Round($sizeBytes / 1MB, 2)
    $maxBytes = $MaxMB * 1MB
    
    Write-Log "File size: $sizeMB MB (Max: $MaxMB MB)"
    
    if ($sizeBytes -gt $maxBytes) {
        Add-ValidationError "Model file exceeds maximum size limit: $sizeMB MB > $MaxMB MB"
        return $false
    }
    
    Write-Log "Model size is within acceptable limits" -Level "SUCCESS"
    return $true
}

function Test-RequiredObjects {
    param([hashtable]$Model)
    
    Write-Section "Step 5: Required Objects Validation"
    
    $modelObj = $Model["model"]
    
    if ($null -eq $modelObj.tables -or $modelObj.tables.Count -eq 0) {
        Add-ValidationWarning "Model has no tables defined"
        if ($StrictMode) {
            Add-ValidationError "Strict mode: Model must have at least one table"
            return $false
        }
    }
    else {
        Write-Log "Tables found: $($modelObj.tables.Count)" -Level "SUCCESS"
    }
    
    # if ($null -eq $modelObj.dataSources -or $modelObj.dataSources.Count -eq 0) {
    #     Add-ValidationWarning "Model has no data sources defined"
    #     if ($StrictMode) {
    #         Add-ValidationError "Strict mode: Model must have at least one data source"
    #         return $false
    #     }
    # }
    # else {
    #     Write-Log "Data sources found: $($modelObj.dataSources.Count)" -ForegroundColor $Colors.Green
    # }
    
    return $true
}

function Test-DataSources {
    param([hashtable]$Model)

    Write-Section "Step 8: Datasource Validation"

    $modelObj = $Model["model"]

    if ($null -eq $modelObj.dataSources) {
        Add-ValidationWarning "No datasources defined"
        return $true
    }

    foreach ($ds in $modelObj.dataSources) {

        if (-not $ds.name) {
            Add-ValidationError "Datasource missing name"
            return $false
        }

        if (-not $ds.connectionString) {
            Add-ValidationError "Datasource '$($ds.name)' missing connection string"
            return $false
        }

        Write-Log "Datasource validated: $($ds.name)" -Level "SUCCESS"
    }

    return $true
}

function Test-Partitions {
    param([hashtable]$Model)

    Write-Section "Step 9: Partition Validation"

    $modelObj = $Model["model"]

    if ($null -eq $modelObj.tables) {
        return $true
    }

    foreach ($table in $modelObj.tables) {

        if ($null -eq $table.partitions -or $table.partitions.Count -eq 0) {
            Add-ValidationWarning "Table '$($table.name)' has no partitions"
        }
        else {
            Write-Log "Table '$($table.name)' partitions: $($table.partitions.Count)" -Level "SUCCESS"
        }
    }

    return $true
}

function Test-Roles {
    param([hashtable]$Model)

    Write-Section "Step 10: Role Validation"

    $modelObj = $Model["model"]

    if ($null -eq $modelObj.roles) {
        Add-ValidationWarning "No security roles defined"
        return $true
    }

    Write-Log "Roles found: $($modelObj.roles.Count)" -Level "SUCCESS"

    foreach ($role in $modelObj.roles) {

        if (-not $role.name) {
            Add-ValidationError "Role without name detected"
            return $false
        }

        Write-Log "Role validated: $($role.name)"
    }

    return $true
}

function Test-Measures {
    param([hashtable]$Model)
    
    Write-Section "Step 6: Measures Validation"
    
    $totalMeasures = 0
    $modelObj = $Model["model"]
    
    if ($null -ne $modelObj.tables) {
        foreach ($table in $modelObj.tables) {
            if ($null -ne $table.measures) {
                $totalMeasures += $table.measures.Count
            }
        }
    }
    

    Write-Log "Total measures defined: $totalMeasures"
    
    if ($totalMeasures -eq 0) {
        Add-ValidationWarning "Model has no measures defined"
    }
    else {
        Write-Log "Measure validation passed" -Level "SUCCESS"
    }
    
    return $true
}

function Test-Relationships {
    param([hashtable]$Model)
    
    Write-Section "Step 7: Relationships Validation"
    
    $modelObj = $Model["model"]
    $relationships = $modelObj.relationships
    
    if ($null -eq $relationships -or $relationships.Count -eq 0) {
        Add-ValidationWarning "Model has no relationships defined"
    }
    else {
        Write-Log "Relationships found: $($relationships.Count)" -Level "SUCCESS"
        
        foreach ($rel in $relationships) {
            if (-not $rel.fromTable -or -not $rel.toTable) {
                Add-ValidationError "Invalid relationship: missing table reference"
                return $false
            }
        }
    }
    
    return $true
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor $Colors.Cyan
Write-Host "  SSAS Tabular Model Validation Tool v2.0" -ForegroundColor $Colors.Cyan
Write-Host "============================================================" -ForegroundColor $Colors.Cyan
Write-Log "Starting validation for: $ModelPath"
Write-Log "Strict Mode: $StrictMode"
Write-Log "Max Size: $MaxSizeMB MB"

if (-not (Test-Path $ModelPath)) {
    Write-Log "Model file not found: $ModelPath" -Level "ERROR"
    exit 1
}

$allPassed = $true

if (-not (Test-JsonSyntax -Path $ModelPath)) {
    $allPassed = $false
}

try {
    $modelJson = Get-Content $ModelPath -Raw | ConvertFrom-Json
    $modelHash = @{}
    $modelJson.PSObject.Properties | ForEach-Object { $modelHash[$_.Name] = $_.Value }
}
catch {
    Add-ValidationError "Failed to parse JSON: $($_.Exception.Message)"
    $allPassed = $false
}

if ($allPassed) {
    if (-not (Test-ModelSchema -Model $modelHash)) {
        $allPassed = $false
    }
    
    if (-not (Test-CompatibilityLevel -Level $modelJson.compatibilityLevel)) {
        $allPassed = $false
    }
    
    if (-not (Test-ModelSize -Path $ModelPath -MaxMB $MaxSizeMB)) {
        $allPassed = $false
    }
    
    if (-not (Test-RequiredObjects -Model $modelHash)) {
        $allPassed = $false
    }
    
    if (-not (Test-Measures -Model $modelHash)) {
        $allPassed = $false
    }
    
    if (-not (Test-Relationships -Model $modelHash)) {
        $allPassed = $false
    }

    if (-not (Test-DataSources -Model $modelHash)) {
        $allPassed = $false
    }

    if (-not (Test-Partitions -Model $modelHash)) {
        $allPassed = $false
    }

    if (-not (Test-Roles -Model $modelHash)) {
        $allPassed = $false
    }
}

Write-Section "Validation Results"

if ($script:ValidationErrors.Count -gt 0) {
    Write-Log "Validation FAILED with $($script:ValidationErrors.Count) error(s)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "ERRORS:" -ForegroundColor $Colors.Red
    $script:ValidationErrors | ForEach-Object { Write-Host "  - $_" -ForegroundColor $Colors.Red }
    
    exit 1
}

if ($script:ValidationWarnings.Count -gt 0 -and $StrictMode) {
    Write-Log "Validation FAILED due to strict mode (warnings treated as errors)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "WARNINGS (treated as errors in strict mode):" -ForegroundColor $Colors.Yellow
    $script:ValidationWarnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor $Colors.Yellow }
    
    exit 1
}

if ($script:ValidationWarnings.Count -gt 0) {
    Write-Log "Validation PASSED with $($script:ValidationWarnings.Count) warning(s)" -Level "WARNING"
    
    Write-Host ""
    Write-Host "WARNINGS:" -ForegroundColor $Colors.Yellow
    $script:ValidationWarnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor $Colors.Yellow }
}
else {
    Write-Log "Validation PASSED - No errors or warnings" -Level "SUCCESS"
}

Write-Host ""
Write-Host "Model: $($modelJson.name)" -ForegroundColor $Colors.Green
Write-Host "Compatibility Level: $($modelJson.compatibilityLevel)" -ForegroundColor $Colors.Green

if ($null -ne $modelJson.model.tables) {
    Write-Host "Tables: $($modelJson.model.tables.Count)" -ForegroundColor $Colors.Green
}

exit 0

