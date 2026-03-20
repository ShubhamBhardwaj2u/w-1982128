param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateScript({Test-Path $_})]
    [string]$BimPath,

    [Parameter(Mandatory=$true, Position=1)]
    [ValidateSet("DEV", "UAT", "PROD")]
    [string]$Environment = "DEV",

    [Parameter(Mandatory=$true, Position=2)]
    [string]$RolesConfigFile,

    [switch]$StrictMode,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$Colors = @{
    Red = [ConsoleColor]::Red
    Yellow = [ConsoleColor]::Yellow
    Green = [ConsoleColor]::Green
    Cyan = [ConsoleColor]::Cyan
    White = [ConsoleColor]::White
}

$script:ValidationErrors = @()

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
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
    Write-Host "============================================================"
    Write-Host "  $Title"
    Write-Host "============================================================"
}

function Add-ValidationError {
    param([string]$Message)
    $script:ValidationErrors += $Message
    Write-Log $Message "ERROR"
}

# Load YAML
try {
    Import-Module powershell-yaml -ErrorAction Stop
} catch {
    Install-Module powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
    Import-Module powershell-yaml
}

function Test-YamlStructure {
    param([string]$Path, [string]$ExpectedEnv)
    
    Write-Section "YAML Structure Validation"
    
    try {
        $config = Get-Content $Path -Raw | ConvertFrom-Yaml
        
        if ($config.environment -ne $ExpectedEnv) {
            Add-ValidationError "Environment mismatch: '$($config.environment)' expected '$ExpectedEnv'"
            return $false
        }
        
        $roles = $config.roles
        if (-not $roles -or $roles.Count -eq 0) {
            Add-ValidationError "No roles defined, please add at least one role to the environment configuration file."
            return $false
        }
        
        $roleNames = $roles | ForEach-Object name
        $duplicates = $roleNames | Group-Object | Where-Object Count -gt 1
        if ($duplicates) {
            Add-ValidationError "Duplicates: $($duplicates.name -join ', ')"
            return $false
        }
        
        foreach ($role in $roles) {
            if (-not $role.name -or -not $role.members -or $role.members.Count -eq 0) {
                Add-ValidationError "Invalid role: '$($role.name)'"
                return $false
            }
            foreach ($member in $role.members) {
                if ($member -notmatch "^[^\\]+\\[^\\]+$") {
                    Add-ValidationError "Invalid member '$member' in role '$($role.name)'"
                    return $false
                }
            }
        }
        
        Write-Log "Configuration file validated ($($roles.Count) roles)" "SUCCESS"
        return @{ config = $config; roles = $roles }
    }
    catch {
        Add-ValidationError "YAML error: $($_.Exception.Message)"
        Write-Log "Error occurred while validating YAML configuration" "ERROR"
        return $false
    }
}

function Test-BimRoleSync {
    param($BimModel, [array]$YamlRoles)
    
    Write-Section "Role Sync Validation"
    
    if (-not $bimModel.roles) {
        Add-ValidationError "BIM has no roles"
        exit 1
    }

    $bimNames = $BimModel.roles | ForEach-Object name
    $yamlNames = $YamlRoles | ForEach-Object name
    
    $missing = $yamlNames | Where { $_ -notin $bimNames }
    $extra = $bimNames | Where { $_ -notin $yamlNames }
    
    if ($missing) {
        Add-ValidationError "Roles Missing in BIM: $($missing -join ', ')"
        return $false
    }
    
    if ($StrictMode -and $extra) {
        Add-ValidationError "Extra Roles in BIM: $($extra -join ', ')"
        return $false
    } elseif ($extra) {
        Write-Log "Extra Roles in BIM: $($extra -join ', ')" "WARNING"
    }
    
    Write-Log "Roles are in sync" "SUCCESS"
    return $true
}

function Sync-RoleMembers {
    param($BimModel, [array]$YamlRoles, [switch]$DryRun)
    
    Write-Section "Member Synchronization"
    
    foreach ($yamlRole in $YamlRoles) {
        $role = $BimModel.roles | Where-Object { $_.name -eq $yamlRole.name }
        
        if (-not $role.members) {
            $role.members = @()
        } elseif ($role.members -isnot [System.Collections.IEnumerable] -or $role.members -is [String]) {
            $role.members = @($role.members)
        }

        $oldCount = $role.members.Count
        
        if ($DryRun) {
            Write-Host "  $($yamlRole.name): $oldCount (old) --> $($yamlRole.members.Count) (New)"
            continue
        }
        
        $role.members = @($yamlRole.members | ForEach-Object { @{ memberName = $_ } })
        Write-Host "  $($yamlRole.name): $oldCount (old) --> $($yamlRole.members.Count) (New)" -ForegroundColor Cyan
        # Write-Log "Members Synced '$($yamlRole.name)'" "SUCCESS"
    }
    
    Write-Log "Members synchronized" "SUCCESS"
}

# MAIN
#-----------------------------------------------------
Write-Section "SSAS Tabular Role Synchronizer"

if (-not $RolesConfigFile) {
    Write-Host "No roles config file specified. "
    Write-Host "Please provide a path to the YAML roles config file using -RolesConfigFile parameter."
    exit 1
}

Write-Log "BIM: $BimPath"
Write-Log "YAML: $RolesConfigFile"
Write-Log "Strict: $StrictMode"

if ($DryRun) {
    Write-Log "*** DRY RUN MODE ***" "WARNING"
}

# 1. YAML
$yamlData = Test-YamlStructure $RolesConfigFile $Environment
if (-not $yamlData) { exit 1 }
$config = $yamlData.config
$yamlRoles = $yamlData.roles

# 2. BIM
$bimRaw = Get-Content $BimPath -Raw -Encoding UTF8 | ConvertFrom-Json
$bimModel = $bimRaw.model

Write-Log "BIM file Validated ($($bimModel.roles.Count) roles)" "SUCCESS"

# 3. Sync check
if (-not (Test-BimRoleSync $bimModel $yamlRoles)) { exit 1 }


# 4. Update
Sync-RoleMembers $bimModel $yamlRoles -DryRun:$DryRun

# 5. Save
if (-not $DryRun) {
    Write-Section "Saving BIM"
    $bimRaw | ConvertTo-Json -Depth 20 | Set-Content $BimPath -Encoding UTF8 -NoNewline
    Write-Log "Saved successfully" "SUCCESS"
}

Write-Section "COMPLETE"
Write-Log "Roles validation and sync finished" "SUCCESS"
exit 0

