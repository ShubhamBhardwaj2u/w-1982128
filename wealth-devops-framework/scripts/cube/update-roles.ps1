<#
.SYNOPSIS
    Updates SSAS Tabular model role memberships for environment-specific AD security groups.
.DESCRIPTION
    Manages role-based security by updating Windows AD group memberships based on 
    environment-specific YAML configuration files.
    
    This script is designed for CI/CD pipelines and supports idempotent deployments.
    
    YAML Structure:
        environment: DEV
        
        roles:
          - name: "Role Name"
            members:
              - "DOMAIN\\ADGroup1"
              - "DOMAIN\\ADGroup2"
    
.PARAMETER BimPath
    Path to the .bim file to update.
.PARAMETER Environment
    Target environment: DEV, UAT, or PROD.
.PARAMETER RolesConfigFile
    Path to YAML file with role-to-AD-group mappings.
.PARAMETER Mode
    Update mode: ReplaceMembers, AddMembers, RemoveMembers, Sync (default: ReplaceMembers).
.PARAMETER TomDllPath
    Custom path to TOM DLL.
.PARAMETER Backup
    Create backup of original bim file before modifying.
.PARAMETER DryRun
    Show what would be changed without making modifications.
.PARAMETER Verbose
    Enable verbose output.
    
.EXAMPLE
    .\update-roles.ps1 -BimPath ".\Wealth.bim" -Environment DEV -RolesConfigFile ".\config\roles\dev.yml"
    
.EXAMPLE
    .\update-roles.ps1 -BimPath ".\Wealth.bim" -Environment PROD -RolesConfigFile ".\config\roles\prod.yml" -Mode Sync -Backup

.NOTES
    Requires: powershell-yaml module
    Auto-installs powershell-yaml if not present.
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$BimPath,

    [Parameter(Mandatory=$true)]
    [ValidateSet("DEV", "UAT", "PROD")]
    [string]$Environment,

    [Parameter(Mandatory=$true)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$RolesConfigFile,

    [Parameter(Mandatory=$false)]
    [ValidateSet("ReplaceMembers", "AddMembers", "RemoveMembers", "Sync")]
    [string]$Mode = "ReplaceMembers",

    [Parameter(Mandatory=$false)]
    [string]$TomDllPath,

    [Parameter(Mandatory=$false)]
    [switch]$Backup,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [switch]$Verbose
)

# ==============================================================================
# CONFIGURATION
# ==============================================================================

$ErrorActionPreference = "Stop"
$script:ChangesMade = @()
$script:Warnings = @()
$script:Errors = @()
$script:RolesProcessed = 0
$script:MembersAdded = 0
$script:MembersRemoved = 0
$script:RolesCreated = 0

if ($Verbose) {
    $VerbosePreference = "Continue"
}

# ANSI Color Codes
$Colors = @{
    Red = [ConsoleColor]::Red
    Yellow = [ConsoleColor]::Yellow
    Green = [ConsoleColor]::Green
    Cyan = [ConsoleColor]::Cyan
    White = [ConsoleColor]::White
    DarkGray = [ConsoleColor]::DarkGray
    Magenta = [ConsoleColor]::Magenta
}

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = $White
    
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
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor $Colors.Cyan
    Write-Host "  $Title" -ForegroundColor $Colors.Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor $Colors.Cyan
}

function Write-RoleChange {
    param(
        [string]$RoleName,
        [string]$Action,
        [string]$Member,
        [string]$Type = "INFO"
    )
    
    $color = $Colors.Cyan
    if ($Type -eq "ADD")    { $color = $Colors.Green }
    if ($Type -eq "REMOVE") { $color = $Colors.Yellow }
    if ($Type -eq "ERROR")  { $color = $Colors.Red }
    
    Write-Host "  [$Action] $RoleName <- $Member" -ForegroundColor $color
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

# ==============================================================================
# TOM LIBRARY LOADING
# ==============================================================================

function Initialize-TomLibrary {
    Write-Log "Loading TOM libraries..." -Level "INFO"
    
    # Try loading from GAC
    try {
        Add-Type -AssemblyName "Microsoft.AnalysisServices.Core" -ErrorAction Stop
        Add-Type -AssemblyName "Microsoft.AnalysisServices.Tabular" -ErrorAction Stop
        Write-Log "TOM libraries loaded from GAC" -Level "SUCCESS"
        return $true
    }
    catch { }

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
        "C:\Program Files\Microsoft SQL Server\150\SDK\Assemblies\Microsoft.AnalysisServices.Tabular.dll"
    )

    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            try {
                Add-Type -Path $path
                Write-Log "TOM library loaded from: $path" -Level "SUCCESS"
                return $true
            }
            catch { continue }
        }
    }

    Add-Error "TOM libraries not found. Please install SSMS or specify -TomDllPath"
    return $false
}

# ==============================================================================
# YAML MODULE
# ==============================================================================

function Initialize-YamlModule {
    Write-Log "Checking for powershell-yaml module..." -Level "INFO"
    
    $module = Get-Module -Name powershell-yaml -ListAvailable
    
    if ($null -eq $module) {
        Write-Log "Installing powershell-yaml module..." -Level "INFO"
        
        # Set PSGallery as trusted for CI/CD environments
        try {
            $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
            if ($null -ne $repo -and $repo.InstallationPolicy -ne "Trusted") {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            }
        }
        catch { }
        
        try {
            Install-Module -Name powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
            Write-Log "powershell-yaml module installed" -Level "SUCCESS"
        }
        catch {
            Add-Error "Failed to install powershell-yaml: $($_.Exception.Message)"
            return $false
        }
    }
    
    try {
        Import-Module powershell-yaml -ErrorAction Stop
        Write-Log "powershell-yaml module loaded" -Level "SUCCESS"
        return $true
    }
    catch {
        Add-Error "Failed to import powershell-yaml: $($_.Exception.Message)"
        return $false
    }
}

# ==============================================================================
# CONFIGURATION VALIDATION
# ==============================================================================

function Test-YamlConfiguration {
    param([object]$Config)
    
    Write-Log "Validating YAML configuration..." -Level "INFO"
    
    # Check environment exists
    if (-not $Config.PSObject.Properties.Name -contains 'environment') {
        Add-Error "YAML configuration missing 'environment' property"
        return $false
    }
    
    # Check roles exists
    if (-not $Config.PSObject.Properties.Name -contains 'roles') {
        Add-Error "YAML configuration missing 'roles' property"
        return $false
    }
    
    # Validate environment matches
    if ($Config.environment -ne $Environment) {
        Add-Error "Environment mismatch: YAML has '$($Config.environment)' but parameter is '$Environment'"
        return $false
    }
    
    # Validate roles is an array
    if ($Config.roles -isnot [array]) {
        Add-Error "'roles' must be an array"
        return $false
    }
    
    # Check for duplicate role names
    $roleNames = $Config.roles | ForEach-Object { $_.name }
    if ($roleNames.Count -ne ($roleNames | Select-Object -Unique).Count) {
        Add-Error "Duplicate role names detected in YAML configuration"
        return $false
    }
    
    # Validate each role
    foreach ($role in $Config.roles) {
        if (-not $role.PSObject.Properties.Name -contains 'name') {
            Add-Error "Role missing 'name' property"
            return $false
        }
        
        if (-not $role.PSObject.Properties.Name -contains 'members') {
            Add-Error "Role '$($role.name)' missing 'members' property"
            return $false
        }
        
        if ($role.members -isnot [array]) {
            Add-Error "Role '$($role.name)' members must be an array"
            return $false
        }
        
        if ($role.members.Count -eq 0) {
            Add-Error "Role '$($role.name)' has no members"
            return $false
        }

        # Check for duplicate members in same role
        $members = $role.members
        if ($members.Count -ne ($members | Select-Object -Unique).Count) {
            Add-Error "Role '$($role.name)' has duplicate members"
            return $false
        }
    }
    
    Write-Log "YAML configuration is valid" -Level "SUCCESS"
    return $true
}

# ==============================================================================
# MEMBER VALIDATION
# ==============================================================================

function Test-MemberFormat {
    param([string]$Member)
    
    # Valid Windows group/user format: DOMAIN\GroupName or DOMAIN\UserName
    if ($Member -match '^[A-Za-z0-9_][A-Za-z0-9_\\.-]*\\[A-Za-z0-9_][A-Za-z0-9_.-]*$') {
        return $true
    }
    
    return $false
}

function Test-AllMemberFormats {
    param([object]$Roles)
    
    Write-Log "Validating member formats..." -Level "INFO"
    
    foreach ($role in $Roles) {
        foreach ($member in $role.members) {
            if (-not (Test-MemberFormat -Member $member)) {
                Add-Error "Invalid member format: '$member' (expected: DOMAIN\GroupName)"
                return $false
            }
        }
    }
    
    Write-Log "All member formats are valid" -Level "SUCCESS"
    return $true
}


function Test-AdGroupExists {
    param([string]$Group)

    try {

        if (-not (Get-Module ActiveDirectory)) {

            if (Get-Module -ListAvailable ActiveDirectory) {
                Import-Module ActiveDirectory -ErrorAction Stop
            }
            else {
                Write-Log "ActiveDirectory module not available. Skipping AD validation." -Level "WARNING"
                return $true
            }
        
        }

        $parts = $Group.Split("\")
        $name = $parts[1]

        $group = Get-ADGroup -Filter "Name -eq '$name'" -ErrorAction Stop

        return $true
    }
    catch {
        return $false
    }
}

# ==============================================================================
# ROLE PROCESSING
# ==============================================================================

function Update-RoleMembership {
    param(
        [object]$Database,
        [string]$RoleName,
        [string[]]$DesiredMembers,
        [string]$Mode
    )
    
    $script:RolesProcessed++
    $modelRoles = $Database.Model.Roles
    $existingRole = $modelRoles.Find($RoleName)
    
    # Normalize member names for case-insensitive comparison
    # Create normalized array for comparison only (do not change original values)
    $normalizedDesired = $DesiredMembers | ForEach-Object { $_.ToLower() }

    if ($null -eq $existingRole) {
        # Role doesn't exist - create it
        Write-Host "  Creating new role: $RoleName" -ForegroundColor $Colors.Green
        
        if ($DryRun) {
            Write-Log "Would CREATE role: $RoleName" -Level "INFO"
            foreach ($member in $DesiredMembers) {
                Write-RoleChange -RoleName $RoleName -Action "ADD" -Member $member -Type "ADD"
            }
            $script:ChangesMade += "Would CREATE role: $RoleName"
            return
        }
        
        $newRole = New-Object Microsoft.AnalysisServices.Tabular.ModelRole($Database.Model, $RoleName)
        $newRole.ModelPermission = [Microsoft.AnalysisServices.Tabular.ModelPermission]::Read
        
        foreach ($member in $DesiredMembers) {
            $newRole.Members.Add([Microsoft.AnalysisServices.Tabular.WindowsGroupMember]::new($member))
            Write-RoleChange -RoleName $RoleName -Action "ADD" -Member $member -Type "ADD"
        }
        
        $newRole.Update()
        $script:RolesCreated++
        $script:MembersAdded += $DesiredMembers.Count
        $script:ChangesMade += "Created role: $RoleName with $($DesiredMembers.Count) member(s)"
        Write-Log "Role created: $RoleName" -Level "SUCCESS"
    }
    else {
        # Role exists - update based on mode
        Write-Host "  Updating existing role: $RoleName" -ForegroundColor $Colors.Cyan
        
        # Get current members and normalize
        $currentMembers = @()
        foreach ($member in $existingRole.Members) {
            $currentMembers += $member.Name
        }

        # Normalize for comparison
        $normalizedCurrent = $currentMembers | ForEach-Object { $_.ToLower() }
        
        if ($Mode -eq "ReplaceMembers") {
            # Clear and add ALL desired members
            if ($DryRun) {

                Write-Host "    Current: $($currentMembers -join ', ')" -ForegroundColor $Colors.DarkGray
                Write-Host "    Desired: $($DesiredMembers -join ', ')" -ForegroundColor $Colors.DarkGray
            
                $toRemove = $currentMembers | Where-Object { $_.ToLower() -notin $normalizedDesired }
                $toAdd = $DesiredMembers | Where-Object { $_.ToLower() -notin $normalizedCurrent }
            
                foreach ($member in $toRemove) {
                    Write-RoleChange -RoleName $RoleName -Action "REMOVE" -Member $member -Type "REMOVE"
                }
            
                foreach ($member in $toAdd) {
                    Write-RoleChange -RoleName $RoleName -Action "ADD" -Member $member -Type "ADD"
                }
            }
            else {
                # Clear existing members
                $existingRole.Members.Clear()
                
                # Add ALL desired members
                foreach ($member in $DesiredMembers) {
                    $existingRole.Members.Add([Microsoft.AnalysisServices.Tabular.WindowsGroupMember]::new($member))
                    Write-RoleChange -RoleName $RoleName -Action "ADD" -Member $member -Type "ADD"
                }
                
                $existingRole.Update()
            }
            
            $script:MembersRemoved += $currentMembers.Count
            $script:MembersAdded += $DesiredMembers.Count
            $script:ChangesMade += "Replaced role: $RoleName with $($DesiredMembers.Count) member(s)"
        }
        elseif ($Mode -eq "AddMembers") {
            # Add missing members only
            $toAdd = $DesiredMembers | Where-Object { $_.ToLower() -notin $normalizedCurrent }
            
            if ($toAdd.Count -eq 0) {
                Write-Host "    No new members to add" -ForegroundColor $Colors.DarkGray
            }
            
            foreach ($member in $toAdd) {
                if ($DryRun) {
                    Write-RoleChange -RoleName $RoleName -Action "ADD" -Member $member -Type "ADD"
                }
                else {
                    $existingRole.Members.Add([Microsoft.AnalysisServices.Tabular.WindowsGroupMember]::new($member))
                    Write-RoleChange -RoleName $RoleName -Action "ADD" -Member $member -Type "ADD"
                }
                $script:MembersAdded++
            }
            
            if (-not $DryRun -and $toAdd.Count -gt 0) {
                $existingRole.Update()
                $script:ChangesMade += "Added $($toAdd.Count) member(s) to role: $RoleName"
            }
        }
        elseif ($Mode -eq "RemoveMembers") {
            # Remove specified members
            $toRemove = $currentMembers | Where-Object { $_.ToLower() -in $normalizedDesired }
            
            if ($toRemove.Count -eq 0) {
                Write-Host "    No members to remove" -ForegroundColor $Colors.DarkGray
            }
            
            foreach ($member in $toRemove) {
                if ($DryRun) {
                    Write-RoleChange -RoleName $RoleName -Action "REMOVE" -Member $member -Type "REMOVE"
                }
                else {
            
                    $existingMember = $existingRole.Members | Where-Object { $_.Name -eq $member }
                    if ($existingMember) {
                        $existingRole.Members.Remove($existingMember)
                    }
            
                    Write-RoleChange -RoleName $RoleName -Action "REMOVE" -Member $member -Type "REMOVE"
                }
            
                $script:MembersRemoved++
            }
            
            if (-not $DryRun -and $toRemove.Count -gt 0) {
                $existingRole.Update()
                $script:ChangesMade += "Removed $($toRemove.Count) member(s) from role: $RoleName"
            }
        }
        elseif ($Mode -eq "Sync") {
            # Add missing, remove extra
            $toRemove = $currentMembers | Where-Object { $_.ToLower() -notin $normalizedDesired }
            $toAdd = $DesiredMembers | Where-Object { $_.ToLower() -notin $normalizedCurrent }
            
            if ($toRemove.Count -eq 0 -and $toAdd.Count -eq 0) {
                Write-Host "    No changes required" -ForegroundColor $Colors.DarkGray
            }
            
            foreach ($member in $toRemove) {

                if ($DryRun) {
                    Write-RoleChange -RoleName $RoleName -Action "REMOVE" -Member $member -Type "REMOVE"
                }
                else {
            
                    $existingMember = $existingRole.Members | Where-Object { $_.Name -eq $member }
                    if ($existingMember) {
                        $existingRole.Members.Remove($existingMember)
                    }
            
                    Write-RoleChange -RoleName $RoleName -Action "REMOVE" -Member $member -Type "REMOVE"
                }
            
                $script:MembersRemoved++
            }
            
            foreach ($member in $toAdd) {
                if ($DryRun) {
                    Write-RoleChange -RoleName $RoleName -Action "ADD" -Member $member -Type "ADD"
                }
                else {
                    $existingRole.Members.Add([Microsoft.AnalysisServices.Tabular.WindowsGroupMember]::new($member))
                    Write-RoleChange -RoleName $RoleName -Action "ADD" -Member $member -Type "ADD"
                }
                $script:MembersAdded++
            }
            
            if (-not $DryRun -and ($toAdd.Count -gt 0 -or $toRemove.Count -gt 0)) {
                $existingRole.Update()
                $script:ChangesMade += "Synced role: $RoleName (+$($toAdd.Count) / -$($toRemove.Count))"
            }
        }
    }
}

# ==============================================================================
# BIM FILE OPERATIONS
# ==============================================================================

function Backup-BimFile {
    param([string]$Path)
    
    $backupPath = "$Path.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item -Path $Path -Destination $backupPath -Force
    Write-Log "Backup created: $backupPath" -Level "SUCCESS"
    return $backupPath
}

function Save-BimFile {
    param(
        [string]$Path,
        [object]$Model
    )
    
    $json = [Microsoft.AnalysisServices.Tabular.JsonSerializer]::SerializeDatabase($Model)
    $json | Out-File -FilePath $Path -Encoding UTF8 -Force
    Write-Log "BIM file updated: $Path" -Level "SUCCESS"
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor $Colors.Cyan
Write-Host "║       SSAS Tabular Role Update Tool v2.0                        ║" -ForegroundColor $Colors.Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor $Colors.Cyan

Write-Log "Starting role update" -Level "INFO"
Write-Log "  Environment: $Environment" -Level "INFO"
Write-Log "  Config File: $RolesConfigFile" -Level "INFO"
Write-Log "  Mode: $Mode" -Level "INFO"
Write-Log "  BIM Path: $BimPath" -Level "INFO"

if ($DryRun) {
    Write-Log "DRY RUN MODE: No changes will be made" -Level "WARNING"
}

# Step 1: Load YAML module
if (-not (Initialize-YamlModule)) {
    Write-Section "ERROR"
    exit 1
}

# Step 2: Load TOM libraries
if (-not (Initialize-TomLibrary)) {
    Write-Section "ERROR"
    exit 1
}

# Step 3: Load and validate YAML configuration
Write-Section "Loading Configuration"
try {
    $yamlContent = Get-Content $RolesConfigFile -Raw -ErrorAction Stop
    $config = ConvertFrom-Yaml -Yaml $yamlContent -ErrorAction Stop
    Write-Log "Configuration loaded from: $RolesConfigFile" -Level "SUCCESS"
}
catch {
    Add-Error "Failed to load YAML configuration: $($_.Exception.Message)"
    Write-Section "ERROR"
    exit 1
}

# Validate configuration
if (-not (Test-YamlConfiguration -Config $config)) {
    Write-Section "ERROR"
    exit 1
}

# Validate member formats
if (-not (Test-AllMemberFormats -Roles $config.roles)) {
    Write-Section "ERROR"
    exit 1
}

# Remove duplicate members from configuration
foreach ($role in $config.roles) {
    $role.members = $role.members | Select-Object -Unique
}

# Step 4: Load BIM model
Write-Section "Loading BIM Model"
try {
    if ($Backup -and -not $DryRun) {
        Backup-BimFile -Path $BimPath | Out-Null
    }
    
    $json = Get-Content $BimPath -Raw -ErrorAction Stop
    $model = [Microsoft.AnalysisServices.Tabular.JsonSerializer]::DeserializeDatabase($json)
    Write-Log "Model loaded: $($model.Name)" -Level "SUCCESS"
}
catch {
    Add-Error "Failed to load BIM file: $($_.Exception.Message)"
    Write-Section "ERROR"
    exit 1
}

# Step 5: Process roles
# Optional: Validate AD groups exist
foreach ($role in $config.roles) {

    foreach ($member in $role.members) {

        if (-not (Test-AdGroupExists $member)) {

            Add-Warning "AD group may not exist: $member"

        }

    }

}

Write-Section "Processing Roles"

foreach ($role in $config.roles) {
    Write-Host ""
    Write-Host "Role: $($role.name)" -ForegroundColor $Colors.White
    
    Update-RoleMembership `
        -Database $model `
        -RoleName $role.name `
        -DesiredMembers $role.members `
        -Mode $Mode
}

# Step 6: Save BIM file
if (-not $DryRun) {
    Write-Section "Saving BIM Model"
    try {
        Save-BimFile -Path $BimPath -Model $model
    }
    catch {
        Add-Error "Failed to save BIM file: $($_.Exception.Message)"
        Write-Section "ERROR"
        exit 1
    }
}

# ==============================================================================
# FINAL RESULTS
# ==============================================================================

Write-Section "Results"

if ($DryRun) {
    Write-Log "DRY RUN COMPLETE - No changes were made" -Level "WARNING"
}

if ($script:Errors.Count -gt 0) {
    Write-Log "FAILED with $($script:Errors.Count) error(s)" -Level "ERROR"
    Write-Host ""
    Write-Host "ERRORS:" -ForegroundColor $Colors.Red
    $script:Errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor $Colors.Red }
    exit 1
}

Write-Log "Role update completed successfully!" -Level "SUCCESS"

Write-Host ""
Write-Host "───────────────────────────────────────────────────────────────────" -ForegroundColor $Colors.Cyan
Write-Host "  Summary" -ForegroundColor $Colors.Green
Write-Host "───────────────────────────────────────────────────────────────────" -ForegroundColor $Colors.Cyan
Write-Host "  Environment     : $Environment" -ForegroundColor $Colors.White
Write-Host "  Mode           : $Mode" -ForegroundColor $Colors.White
Write-Host "  Roles Processed: $($script:RolesProcessed)" -ForegroundColor $Colors.White
Write-Host "  Roles Created  : $($script:RolesCreated)" -ForegroundColor $Colors.Green
Write-Host "  Members Added  : $($script:MembersAdded)" -ForegroundColor $Colors.Green
Write-Host "  Members Removed: $($script:MembersRemoved)" -ForegroundColor $Colors.Yellow

if ($script:ChangesMade.Count -gt 0) {
    Write-Host ""
    Write-Host "───────────────────────────────────────────────────────────────────" -ForegroundColor $Colors.Cyan
    Write-Host "  Changes Made" -ForegroundColor $Colors.Cyan
    Write-Host "───────────────────────────────────────────────────────────────────" -ForegroundColor $Colors.Cyan
    $script:ChangesMade | ForEach-Object { Write-Host "  ✓ $_" -ForegroundColor $Colors.Green }
}

if ($script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "───────────────────────────────────────────────────────────────────" -ForegroundColor $Colors.Cyan
    Write-Host "  Warnings" -ForegroundColor $Colors.Yellow
    Write-Host "───────────────────────────────────────────────────────────────────" -ForegroundColor $Colors.Cyan
    $script:Warnings | ForEach-Object { Write-Host "  ! $_" -ForegroundColor $Colors.Yellow }
}

Write-Host ""
exit 0

