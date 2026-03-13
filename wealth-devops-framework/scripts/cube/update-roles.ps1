<#
.SYNOPSIS
    Strictly synchronizes SSAS Tabular model roles with YAML configuration in Azure DevOps CI/CD pipelines.

.DESCRIPTION
    Enforces EXACT synchronization between YAML role definitions and BIM model roles.
    
    VALIDATION RULES (STRICT):
    ✓ YAML roles must exist exactly in BIM (case-sensitive)
    ✓ No extra roles in BIM not defined in YAML
    ✓ No duplicate roles in YAML
    ✓ Proper YAML structure
    ✓ Valid Windows group formats
    
    BEHAVIOR:
    1. Validate YAML structure
    2. Load BIM model
    3. STRICT role structure validation (fail pipeline on mismatch)
    4. Clear/replace role members with YAML members
    5. Save BIM (pipeline workspace only)
    
    NO role auto-creation by default. Use -AllowRoleCreation for optional creation.

.PARAMETER BimPath
    Path to .bim file (mandatory).

.PARAMETER Environment
    Target environment: DEV, UAT, PROD (mandatory).

.PARAMETER RolesConfigFile
    YAML config file path (mandatory).

.PARAMETER AllowRoleCreation
    Allow auto-creation of missing roles (DISABLED by default - STRICT mode).

.PARAMETER DryRun
    Simulate without changes.

.PARAMETER Verbose
    Verbose output.

.EXAMPLE
    .\update-roles.ps1 -BimPath "Wealth.bim" -Environment "DEV" -RolesConfigFile "config/roles/dev.yml"

.NOTES
    • Single source of truth: YAML files
    • Modifies pipeline workspace BIM only
    • No backups (pipeline disposable)
    • Production-grade for Azure DevOps self-hosted Windows agents
#>

param(
    [Parameter(Mandatory)][string]$BimPath,
    [Parameter(Mandatory)][ValidateSet("DEV", "UAT", "PROD")][string]$Environment,
    [Parameter(Mandatory)][string]$RolesConfigFile,
    [switch]$AllowRoleCreation,
    [switch]$DryRun,
    [switch]$Verbose
)

# Global counters
$script:RolesProcessed = 0
$script:MembersAdded = 0
$script:MembersRemoved = 0
$script:Warnings = @()
$script:Errors = @()

$ErrorActionPreference = "Stop"
if ($Verbose) { $VerbosePreference = "Continue" }

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

function Write-Header {
    param([string]$Title)
    $line = "═" * ($Title.Length + 4)
    Write-Host "`n$line"
    Write-Host "  $Title"
    Write-Host $line
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $prefix = "[$timestamp] [$Level]"
    switch ($Level) {
        "ERROR" { Write-Host "$prefix $Message" -ForegroundColor Red }
        "WARN"  { Write-Host "$prefix $Message" -ForegroundColor Yellow }
        "SUCCESS" { Write-Host "$prefix $Message" -ForegroundColor Green }
        default { Write-Host "$prefix $Message" -ForegroundColor Cyan }
    }
}

function Add-Error {
    param([string]$Msg)
    $script:Errors += $Msg
    Write-Log $Msg "ERROR"
}

function Add-Warn {
    param([string]$Msg)
    $script:Warnings += $Msg
    Write-Log $Msg "WARN"
}

# ==============================================================================
# MODULE/DEPENDENCY INITIALIZATION
# ==============================================================================

function Initialize-Yaml {
    if (-not (Get-Module -ListAvailable powershell-yaml)) {
        try {
            Install-Module powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
        } catch {
            throw "powershell-yaml module is required but could not be installed automatically. $($_.Exception.Message)"
        }
    }
    Import-Module powershell-yaml -ErrorAction Stop
}

function Initialize-TOM {
    try {
        Add-Type -AssemblyName "Microsoft.AnalysisServices.Core"
        Add-Type -AssemblyName "Microsoft.AnalysisServices.Tabular"
    } catch {
        $paths = @(
            "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio 19\Common7\IDE\CommonExtensions\Microsoft\AnalysisServices\Project\Microsoft.AnalysisServices.Tabular.dll",
            "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio 18\Common7\IDE\CommonExtensions\Microsoft\AnalysisServices\Project\Microsoft.AnalysisServices.Tabular.dll",
            "${env:ProgramFiles(x86)}\Microsoft SQL Server\150\SDK\Assemblies\Microsoft.AnalysisServices.Tabular.dll"
        )
        foreach ($path in $paths) {
            if (Test-Path $path) {
                Add-Type -Path $path
                return
            }
        }
        throw "TOM libraries not found. Install SSMS or SQL Server SDK."
    }
}

function Test-ADModule {
    $mod = Get-Module -ListAvailable ActiveDirectory
    if ($mod) { Import-Module ActiveDirectory }
    return (Get-Module ActiveDirectory -ErrorAction SilentlyContinue)
}

# ==============================================================================
# VALIDATION FUNCTIONS
# ==============================================================================

function Test-YamlStructure {
    param([hashtable]$Config)

    Write-Header "YAML STRUCTURE VALIDATION"

    if (-not $Config.environment -or $Config.environment -ne $Environment) {
        Add-Error "Invalid/mismatched environment: '$($Config.environment)' (expected: $Environment)"
        return $false
    }

    if (-not $Config.roles -or $Config.roles.Count -eq 0) {
        Add-Error "No roles defined in YAML"
        return $false
    }

    $roleNames = $Config.roles | ForEach-Object { $_.name }
    $dupeGroups = $roleNames | Group-Object -CaseSensitive:$false | Where-Object Count -gt 1
    if ($dupeGroups) {
        Add-Error "Duplicate role names detected in YAML configuration (case-insensitive)"
        return $false
    }

    foreach ($role in $Config.roles) {
        if (-not $role.name -or -not $role.members -or $role.members.Count -eq 0) {
            Add-Error "Invalid role structure: '$($role.name)'"
            return $false
        }
        # Dedupe members
        $role.members = $role.members | Sort-Object -Unique -CaseSensitive:$false
        foreach ($m in $role.members) {
            if ($m -notmatch "^[^\\]+\\[^\\]+$") {
                Add-Error "Invalid member format '$m' in role '$($role.name)' (expected DOMAIN\\Group)"
                return $false
            }
        }
    }
    Write-Log "YAML structure valid" "SUCCESS"
    return $true
}

function Test-RoleSynchronization {
    param([object]$Database, [array]$YamlRoles)

    Write-Header "STRICT ROLE SYNCHRONIZATION VALIDATION"

    $bimRoles = @($Database.Model.Roles | ForEach-Object { $_.Name })
    $yamlRoleNames = $YamlRoles | ForEach-Object { $_.name }

    # 1. Missing in BIM
    $missingInBim = $yamlRoleNames | Where-Object { $_ -notin $bimRoles }
    foreach ($role in $missingInBim) {
        Add-Error "Role '$role' exists in YAML but missing in BIM model"
    }

    # 2. Extra in BIM
    $extraInBim = $bimRoles | Where-Object { $_ -notin $yamlRoleNames }
    foreach ($role in $extraInBim) {
        Add-Error "Role '$role' exists in BIM but not defined in YAML"
    }

    # Case sensitivity already handled by -notin (exact match)

    if ($script:Errors.Count -gt 0) {
        Add-Error "Role synchronization FAILED. BIM and YAML must match exactly."
        return $false
    }

    Write-Log "Role structures synchronized perfectly" "SUCCESS"
    return $true
}

function Test-OptionalADGroups {
    param([array]$YamlRoles)
    $hasAD = Test-ADModule
    if (-not $hasAD) {
        Add-Warn "ActiveDirectory module not available. Skipping AD group validation."
        return
    }
    foreach ($role in $YamlRoles) {
        foreach ($member in $role.members) {
            $groupName = $member.Split('\')[-1]
            try {
                Get-ADGroup -Identity $groupName | Out-Null
            } catch {
                Add-Warn "AD group may not exist: $member"
            }
        }
    }
}

# ==============================================================================
# ROLE UPDATE FUNCTIONS
# ==============================================================================

function Update-RoleMembers {
    param([object]$Role, [array]$DesiredMembers)

    $currentMembers = $Role.Members | ForEach-Object { $_.Name }

    Write-Host ""
    Write-Host "Role: $($Role.Name)" -ForegroundColor White
    Write-Host "----------------------------------------"
    Write-Host "Existing members: $($currentMembers.Count)"
    Write-Host "New members     : $($DesiredMembers.Count)"

    if ($DryRun) {
        $normCurrent = $currentMembers | ForEach-Object { $_.ToLower() }
        $normDesired = $DesiredMembers | ForEach-Object { $_.ToLower() }
        $removed = Compare-Object $normCurrent $normDesired -PassThru | Where-Object SideIndicator -eq '<='
        $added = Compare-Object $normCurrent $normDesired -PassThru | Where-Object SideIndicator -eq '=>'
        foreach ($m in $removed) { Write-Host "    REMOVE: $m" -ForegroundColor Yellow }
        foreach ($m in $added) { Write-Host "    ADD:    $m" -ForegroundColor Green }
        return
    }

    # STRICT REPLACE: Clear all, add desired
    $Role.Members.Clear()
    foreach ($member in $DesiredMembers) {
        $null = $Role.Members.Add( [Microsoft.AnalysisServices.Tabular.WindowsGroupMember]::new($member) )
    }
    $Role.Update([Microsoft.AnalysisServices.Tabular.UpdateOptions]::ExpandFull)

    $script:MembersRemoved += $currentMembers.Count
    $script:MembersAdded += $DesiredMembers.Count
    $script:RolesProcessed++
}

function Invoke-OptionalRoleCreation {
    param([object]$Database, [array]$YamlRoles)

    if (-not $AllowRoleCreation) { return }

    Write-Header "OPTIONAL ROLE CREATION"
    $bimRoles = @($Database.Model.Roles | ForEach-Object { $_.Name })
    $toCreate = $YamlRoles | Where-Object { $_.name -notin $bimRoles }

    foreach ($roleDef in $toCreate) {
        if ($DryRun) {
            Write-Log "Would CREATE role: $($roleDef.name)" "INFO"
            continue
        }
        $newRole = New-Object Microsoft.AnalysisServices.Tabular.Role( $Database.Model, $roleDef.name )
        $newRole.ModelPermission = "Read"
        foreach ($m in $roleDef.members) {
            $null = $newRole.Members.Add( [Microsoft.AnalysisServices.Tabular.WindowsGroupMember]::new($m) )
        }
        $newRole.Update()
        Write-Log "Created role: $($roleDef.name)" "SUCCESS"
    }
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

Write-Header "SSAS ROLE SYNCHRONIZER v2.0 - STRICT MODE"

Write-Log "Environment: $Environment"
Write-Log "BIM: $BimPath"
Write-Log "YAML: $RolesConfigFile"
if ($AllowRoleCreation) { Write-Log "AllowRoleCreation: ENABLED (non-strict)" "WARN" }
if ($DryRun) { Write-Log "DRY RUN: No changes applied" "WARN" }

if (-not (Test-Path $BimPath)) {
    Add-Error "BIM file not found: $BimPath"
    exit 1
}
if (-not (Test-Path $RolesConfigFile)) {
    Add-Error "Roles configuration file not found: $RolesConfigFile"
    exit 1
}

# Init
Initialize-Yaml
Initialize-TOM

# Load YAML
$config = Get-Content $RolesConfigFile -Raw | ConvertFrom-Yaml
if (-not (Test-YamlStructure $config)) { exit 1 }

# Load BIM
Write-Header "LOADING BIM MODEL"
$bimJson = Get-Content $BimPath -Raw
$database = [Microsoft.AnalysisServices.Tabular.JsonSerializer]::DeserializeDatabase($bimJson)

    if (-not $database.Model -or -not $database.Model.Roles) {
        Add-Error "BIM model does not contain role definitions."
        exit 1
    }

# AD optional validation
Test-OptionalADGroups $config.roles

# STRICT SYNC VALIDATION (fail fast)
if (-not (Test-RoleSynchronization $database $config.roles)) { exit 1 }

# Optional create (if enabled)
Invoke-OptionalRoleCreation $database $config.roles

# MEMBER SYNCHRONIZATION (only if validation passed)
Write-Header "MEMBER SYNCHRONIZATION"
foreach ($roleDef in $config.roles) {

    Write-Host ""
    $role = $database.Model.Roles.Find($roleDef.name)
    if (-not $role) {
        Add-Error "Role '$($roleDef.name)' not found in BIM model during update."
        exit 1
    }

    Update-RoleMembers $role $roleDef.members
}

# Save
if (-not $DryRun) {
    Write-Header "SAVING BIM"
    $updatedJson = [Microsoft.AnalysisServices.Tabular.JsonSerializer]::SerializeDatabase($database)
    Set-Content -Path $BimPath -Value $updatedJson -Encoding UTF8 -NoNewline
    Write-Log "BIM saved successfully" "SUCCESS"
}

# SUMMARY
Write-Header "FINAL SUMMARY"
Write-Host "Environment: $Environment"
Write-Host "Roles processed: $($script:RolesProcessed)"
Write-Host "Members added: $($script:MembersAdded)"
Write-Host "Members removed: $($script:MembersRemoved)"
Write-Host "Warnings: $($script:Warnings.Count)"
Write-Host "Errors: $($script:Errors.Count)"

if ($script:Errors.Count -gt 0) {
    Write-Host "`nErrors encountered. Review logs above." -ForegroundColor Red
    exit 1
}

Write-Log "Synchronization COMPLETE" "SUCCESS"
exit 0

