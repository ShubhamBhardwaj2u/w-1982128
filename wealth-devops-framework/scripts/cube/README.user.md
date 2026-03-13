# SSAS Cube PowerShell Scripts - User Guide

## Overview
These scripts automate SSAS Tabular model management in Azure DevOps pipelines.

## Available Scripts

### 1. `update-roles.ps1` - Role Synchronization
**Purpose:** Synchronizes SSAS roles/members from YAML config to BIM file.

**Usage:**
```
wealth-devops-framework/scripts/cube/update-roles.ps1 `
  -BimPath "wealth-cube/src/model/Wealth.bim" `
  -Environment "DEV" `
  -RolesConfigFile "wealth-cube/config/roles/dev.yml"
```

**YAML Format (`wealth-cube/config/roles/dev.yml`):**
```yaml
environment: DEV
roles:
  - name: "Read Access"
    members:
      - "DOMAIN\\Group1"
      - "DOMAIN\\Group2"
  - name: "Admin"
    members:
      - "DOMAIN\\Admins"
```

**Key Features:**
- ✅ **Strict sync**: YAML = BIM roles exactly (fails on mismatch)
- ✅ Replaces BIM role members with YAML members
- ✅ No auto-creation (optional `-AllowRoleCreation`)
- ✅ Dry-run mode (`-DryRun`)
- ✅ Optional AD validation (warnings only)

### 2. `validate-model.ps1` - BIM Model Validation
**Purpose:** Validates SSAS BIM file structure and content.

**Usage:**
```
wealth-devops-framework/scripts/cube/validate-model.ps1 `
  -ModelPath "wealth-cube/src/model/Wealth.bim" `
  -StrictMode
```

**Validates:**
- JSON syntax
- Model schema (name, compatibilityLevel, model)
- Compatibility level (1200-1600)
- Tables, measures, relationships, datasources
- Partitions, roles

## Pipeline Integration

**PR Validation (`wealth-cube/pipelines/pr-validation.yml`):**
```
validate-model.ps1 -ModelPath Wealth.bim -StrictMode
validate-bim-roles.ps1 -BimPath Wealth.bim
```

**Build/Deploy (`wealth-cube/pipelines/cube-build.yml`):**
```
update-roles.ps1 -BimPath Wealth.bim -Environment $(Environment)
```

## Expected Behavior
- **Fails pipeline** on validation errors or role mismatches
- **Warnings** for missing tables/datasources (configurable strict mode)
- **Pipeline workspace only** - no repo changes

## Troubleshooting
```
# Test locally
cd wealth-cube/src/model
../../../../../wealth-devops-framework/scripts/cube/update-roles.ps1 -BimPath Wealth.bim -Environment DEV -RolesConfigFile ../../../../../config/roles/dev.yml -DryRun -Verbose
```

**Requires:** PowerShell 7+, SSMS/SQL Server SDK (TOM assemblies), powershell-yaml module (auto-installed).

