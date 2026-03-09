# Role Configuration Files

This directory contains role membership configurations for each environment.

## Structure

Each environment has its own YAML file:
- `dev.yml` - Development environment
- `uat.yml` - UAT environment
- `prod.yml` - Production environment

## YAML Schema

```yaml
environment: DEV

roles:
  - name: "Role Name"
    members:
      - "DOMAIN\\ADGroup1"
      - "DOMAIN\\ADGroup2"
```

## Usage

```powershell
# Deploy to DEV with DEV roles
.\update-roles.ps1 -BimPath ".\Wealth.bim" -Environment DEV -RolesConfigFile ".\config\roles\dev.yml"

# Deploy to UAT with UAT roles
.\update-roles.ps1 -BimPath ".\Wealth.bim" -Environment UAT -RolesConfigFile ".\config\roles\uat.yml"

# Deploy to PROD with PROD roles
.\update-roles.ps1 -BimPath ".\Wealth.bim" -Environment PROD -RolesConfigFile ".\config\roles\prod.yml"
```

## Update Modes

| Mode | Description |
|------|-------------|
| ReplaceMembers | Clear existing members and add YAML members (default) |
| AddMembers | Add missing members only |
| RemoveMembers | Remove members listed in YAML |
| Sync | Add missing members and remove extra members |

## Options

| Option | Description |
|--------|-------------|
| -DryRun | Preview changes without making modifications |
| -Backup | Create backup of BIM file before modifying |

## Example with Options

```powershell
# Preview changes without applying
.\update-roles.ps1 -BimPath ".\Wealth.bim" -Environment PROD -RolesConfigFile ".\config\roles\prod.yml" -DryRun

# Backup and deploy
.\update-roles.ps1 -BimPath ".\Wealth.bim" -Environment PROD -RolesConfigFile ".\config\roles\prod.yml" -Backup

# Sync members (add new, remove old)
.\update-roles.ps1 -BimPath ".\Wealth.bim" -Environment PROD -RolesConfigFile ".\config\roles\prod.yml" -Mode Sync
```

