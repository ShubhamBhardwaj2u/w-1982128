param(
    [Parameter(Mandatory=$true)]
    [string]$SsasServer,

    [Parameter(Mandatory=$true)]
    [string]$DatabaseName,

    [Parameter(Mandatory=$true)]
    [ValidateSet("DEV", "UAT", "PROD")]
    [string]$Environment,

    [Parameter(Mandatory=$true)]
    [string]$BackupRootPath,

    [Parameter(Mandatory=$false)]
    [string]$BackupFilePrefix,

    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,

    [Parameter(Mandatory=$false)]
    [switch]$Verbose
)

# Production SSAS Cube Backup - SqlServer Module Only
$ErrorActionPreference = 'Stop'

# Validate SqlServer module
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Error "SqlServer PowerShell module required. Install with: Install-Module SqlServer -Force"
    exit 1
}

Import-Module SqlServer -Force
Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] SqlServer module loaded"

# Default values
if (-not $BackupFilePrefix) { $BackupFilePrefix = $DatabaseName }
$backupFolder = Join-Path (Join-Path $BackupRootPath $DatabaseName) $Environment
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$backupFile = Join-Path $backupFolder "$BackupFilePrefix`_$timestamp.abf"

Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] Backup configuration:"
Write-Host "  Server: $SsasServer"
Write-Host "  Database: $DatabaseName" 
Write-Host "  Environment: $Environment"
Write-Host "  Backup file: $backupFile"

if ($WhatIf) {
    Write-Host "[WHATIF] Would backup $DatabaseName to $backupFile"
    Write-Host "##vso[task.setvariable variable=BackupFilePath]$backupFile"
    exit 0
}

# Create backup folder
if (-not (Test-Path $backupFolder)) {
    New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] Created folder: $backupFolder"
}

# Production backup
try {
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] Starting backup..."
    Backup-ASDatabase -Server $SsasServer -Database $DatabaseName -BackupFile $backupFile -Overwrite
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [SUCCESS] Backup complete: $backupFile"
    
    $fileSizeMB = [math]::Round((Get-Item $backupFile).Length / 1MB, 2)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] Size: ${fileSizeMB}MB"
    
    Write-Host "##vso[task.setvariable variable=BackupFilePath]$backupFile"
}
catch {
    Write-Error "Backup failed: $($_.Exception.Message)"
    exit 1
}

Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [SUCCESS] Cube backup finished"
exit 0

