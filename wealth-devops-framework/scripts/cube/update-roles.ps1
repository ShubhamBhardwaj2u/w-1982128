<#
.SYNOPSIS
    Strictly synchronizes SSAS Tabular model roles with YAML configuration using JSON parsing (TOM-independent).
.DESCRIPTION
    Replaces BIM role members with YAML definitions. Strict validation.
.PARAMETER BimPath
    Path to .bim file.
.PARAMETER Environment
    DEV/UAT/PROD.
.PARAMETER RolesConfigFile
    YAML config path.
.PARAMETER DryRun
    Preview changes.
#>

param(
    [Parameter(Mandatory)][string]$BimPath,
    [Parameter(Mandatory)][ValidateSet('DEV', 'UAT', 'PROD')][string]$Environment,
    [Parameter(Mandatory)][string]$RolesConfigFile,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Header([string]$Title) {
    $line = '═' * ($Title.Length + 4)
    Write-Host "`n$line"
    Write-Host "  $Title" 
    Write-Host $line
}

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $prefix = "[$timestamp] [$Level]"
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'SUCCESS' { 'Green' }
        default { 'Cyan' }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

# Load modules
if (-not (Get-Module powershell-yaml -ListAvailable)) {
    Install-Module powershell-yaml -Scope CurrentUser -Force
}
Import-Module powershell-yaml

# Validate files
if (-not (Test-Path $BimPath)) { Write-Log 'BIM missing' 'ERROR'; exit 1 }
if (-not (Test-Path $RolesConfigFile)) { Write-Log 'YAML missing' 'ERROR'; exit 1 }

Write-Header 'SSAS ROLE SYNCHRONIZER v3.0 - JSON MODE'
Write-Log "BIM: $BimPath | YAML: $RolesConfigFile | Env: $Environment"
if ($DryRun) { Write-Log 'DRY RUN' 'WARN' }

# Load YAML
$config = Get-Content $RolesConfigFile -Raw | ConvertFrom-Yaml

Write-Header 'YAML VALIDATION'
if ($config.environment -ne $Environment) { Write-Log 'Env mismatch' 'ERROR'; exit 1 }
$yamlRoles = $config.roles
if (-not $yamlRoles -or $yamlRoles.Count -eq 0) { Write-Log 'No roles in YAML' 'ERROR'; exit 1 }

$yamlRoleNames = $yamlRoles | ForEach-Object name
$dupes = $yamlRoleNames | Group-Object | Where Count -gt 1
if ($dupes) { Write-Log 'Role duplicates' 'ERROR'; exit 1 }

foreach ($role in $yamlRoles) {
    if (-not $role.name -or -not $role.members) { Write-Log "Bad role: $($role.name)" 'ERROR'; exit 1 }
    foreach ($m in $role.members) {
        if ($m -notmatch '^[^\\]+\\[^\\]+$') { Write-Log "Bad member '$m'" 'ERROR'; exit 1 }
    }
}
Write-Log 'YAML OK' 'SUCCESS'

# Load BIM
Write-Header 'BIM LOADING'
$bimRaw = Get-Content $BimPath -Raw -Encoding UTF8 | ConvertFrom-Json
$bim = $bimRaw.model

if (-not $bim.roles) { Write-Log 'No roles in BIM' 'ERROR'; exit 1 }
Write-Log "BIM roles found: $($bim.roles.Count)" 'SUCCESS'

# Role sync validation
Write-Header 'ROLE SYNC CHECK'
$bimRoleNames = $bim.roles | ForEach-Object name
$missing = $yamlRoleNames | Where { $_ -notin $bimRoleNames }
$extra = $bimRoleNames | Where { $_ -notin $yamlRoleNames }
if ($missing) { Write-Log "YAML missing in BIM: $missing" 'ERROR'; exit 1 }
if ($extra) { Write-Log "BIM extra: $extra" 'ERROR'; exit 1 }
Write-Log 'Roles sync perfect' 'SUCCESS'

# Update roles
Write-Header 'MEMBER UPDATE'
foreach ($roleDef in $yamlRoles) {
    $role = $bim.roles | Where name -eq $roleDef.name
    $currentCount = $role.members.Count
    
    if ($DryRun) {
        Write-Host "`n$($roleDef.name):"
        Write-Host "  Current: $currentCount members"
        Write-Host "  New: $($roleDef.members.Count)"
        Write-Host "  Would set: $($roleDef.members -join ', ')"
        continue
    }

    # Replace members
    $role.members = $roleDef.members | ForEach-Object {
        @{ memberName = $_ }
    }
    Write-Log "Updated $($roleDef.name)" 'SUCCESS'
}

if (-not $DryRun) {
    Write-Header 'SAVE BIM'
    $bimRaw | ConvertTo-Json -Depth 20 | Set-Content $BimPath -NoNewline -Encoding UTF8
    Write-Log 'BIM saved' 'SUCCESS'
}

Write-Header 'COMPLETE'
Write-Log 'Role sync successful' 'SUCCESS'
exit 0

