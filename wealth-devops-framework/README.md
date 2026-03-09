# Wealth DevOps Framework - SSAS Tabular Model CI/CD Pipeline

This document provides a complete end-to-end understanding of the CI/CD pipeline for deploying SSAS Tabular models. It explains what happens at each stage, when it happens, and how the pieces fit together.

---

## Table of Contents

1. [High-Level Overview](#high-level-overview)
2. [CI/CD Pipeline Flow](#cicd-pipeline-flow)
3. [Pipeline Stages in Order](#pipeline-stages-in-order)
4. [Script Details](#script-details)
5. [Pipeline Templates](#pipeline-templates)
6. [Environment Configurations](#environment-configurations)
7. [Azure DevOps Setup](#azure-devops-setup)

---

## High-Level Overview

The CI/CD pipeline automates the deployment of SSAS Tabular models across multiple environments (DEV → UAT → PROD). Here's what happens:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           CI/CD PIPELINE TIMELINE                              │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌──────────────────────┐        ┌──────────────────────────────────────────┐ │
│  │   BUILD PIPELINE     │        │         DEPLOYMENT PIPELINE              │ │
│  │   (CI - on commit)   │        │         (CD - on trigger/manual)          │ │
│  └──────────────────────┘        └──────────────────────────────────────────┘ │
│                                                                                 │
│  1. Validate Model         ────────►  2. Download Artifact                    │
│  2. Package as Artifact    ────────►  3. Update Data Source                   │
│                                   4. Deploy to SSAS                            │
│                                   5. Update Roles                              │
│                                   6. Process Model                             │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## CI/CD Pipeline Flow

### When Does Each Pipeline Run?

| Trigger | Pipeline | What Happens |
|---------|----------|--------------|
| **Commit to feature/develop/main** | Build Pipeline (CI) | Validates model, creates artifact |
| **Pull Request to main/develop** | PR Validation | Runs strict validation checks |
| **Manual trigger / Release** | Deployment Pipeline (CD) | Deploys to target environment |

### Complete Flow Timeline

```
TIME ─────────────────────────────────────────────────────────────────────────────►

BUILD PIPELINE (CI)                              DEPLOYMENT PIPELINE (CD)
────────────────────                              ────────────────────────

┌─────────────┐
│ Code Commit │
│ (BIM file)  │
└──────┬──────┘
       │
       ▼
┌─────────────────────┐
│ 1. Validate Model  │  ◄── Runs validate-model.ps1
│ (validate-model)   │      - Checks JSON syntax
└─────────┬───────────┘      - Validates schema
          │                  - Checks compatibility level
          │                  - Verifies required objects
          ▼                  - Validates measures, relationships, roles
┌─────────────────────┐
│ 2. Build Artifact  │  ◄── Packages files
│ (cube-artifact)    │      - Wealth.bim (model)
└─────────┬───────────┘      - config/roles.json
          │                  - Publishes to pipeline
          ▼                  
┌─────────────────────┐
│ Artifact Published  │  ◄── Ready for deployment
│ (to Azure Pipelines)│
└─────────┬───────────┘
          │
          │ (Deployment Triggered)
          ▼
┌─────────────────────┐
│ 3. Download        │  ◄── Gets artifact from build
│ Artifact           │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ 4. Update Data     │  ◄── Runs update-datasource.ps1
│ Source             │      - Updates SQL Server name
│ (update-datasource)│      - Updates database name
└─────────┬───────────┘      - Sets impersonation mode
          │
          ▼
┌─────────────────────┐
│ 5. Deploy to SSAS  │  ◄── Runs deploy-cube.ps1
│ (deploy-cube)      │      - Creates/updates database
└─────────┬───────────┘      - Loads TOM libraries
          │                  - Deserializes BIM
          ▼                  - Connects to SSAS
┌─────────────────────┐
│ 6. Update Roles    │  ◄── Runs update-roles.ps1
│ (update-roles)     │      - Maps AD groups per environment
└─────────┬───────────┘      - Applies RLS if configured
          │
          ▼
┌─────────────────────┐
│ 7. Process Model    │  ◄── Data refresh
│ (Full/Default)     │      - Full: reload all data
└─────────┬───────────┘      - Default: auto-detect
          │                  - DataOnly: refresh only
          ▼                  
┌─────────────────────┐
│  DEPLOYMENT        │  ◄── Complete!
│  COMPLETE          │
└─────────────────────┘
```

---

## Pipeline Stages in Order

### Stage 1: Pull Request Validation (Optional - Runs on PR)

**When:** When a Pull Request is created/updated to main or develop

**Purpose:** Catch issues before merging into main branches

**What happens:**
1. Validates BIM structure (strict mode)
2. Checks for hardcoded datasources
3. Validates role configurations
4. Validates measure definitions
5. Basic DAX expression check
6. Security check for sensitive data
7. Generates validation report

**Pipeline Template:** `templates/cube/pr-validation.yml`

---

### Stage 2: Build Pipeline (CI)

**When:** On commit to main, develop, feature/*, or release/* branches

**Purpose:** Validate and package the model for deployment

#### Step 1: Validate Model (`validate-model.ps1`)

The validation script performs multiple checks in sequence:

```
VALIDATION STEPS (in order):
│
├── Step 1: JSON Syntax Validation
│   └── Verifies the .bim file is valid JSON
│
├── Step 2: Tabular Model Schema Validation
│   └── Checks for required properties: name, compatibilityLevel, model
│
├── Step 3: Compatibility Level Check
│   └── Validates compatibility level (1200, 1400, 1500, 1600)
│       • 1200 = SQL Server 2016+
│       • 1400 = SQL Server 2017+
│       • 1500 = SQL Server 2019+
│       • 1600 = SQL Server 2022+
│
├── Step 4: Model Size Validation
│   └── Ensures file size is within configured limit (default: 100MB)
│
├── Step 5: Required Objects Validation
│   └── Checks for tables and data sources
│
├── Step 6: Measures Validation
│   └── Counts total measures in the model
│
├── Step 7: Relationships Validation
│   └── Validates table relationships
│
├── Step 8: Datasource Validation
│   └── Verifies datasource connection strings exist
│
├── Step 9: Partition Validation
│   └── Checks that tables have partitions defined
│
└── Step 10: Role Validation
    └── Verifies security roles are properly defined
```

**Exit Codes:**
- `0` = Validation passed
- `1` = Validation failed (errors or strict mode warnings)

#### Step 2: Build Artifact

Packages the following files:

```
cube-artifact/
├── Wealth.bim           # The SSAS Tabular model (JSON format)
└── config/
    └── roles.json       # Role-to-AD-group mappings
```

**Pipeline Template:** `templates/cube/build-cube.yml`

---

### Stage 3: Deployment Pipeline (CD)

**When:** Manual trigger or as part of release process

**Purpose:** Deploy the validated model to target environment (DEV/UAT/PROD)

#### Step 3: Download Artifact

```yaml
- task: DownloadPipelineArtifact@2
  # Downloads the cube-artifact from build pipeline
```

#### Step 4: Update Data Source (`update-datasource.ps1`)

This script modifies the BIM file's connection strings to point to the correct SQL Server and database for the target environment.

**What it does:**

1. **Loads the BIM file** - Reads the JSON structure
2. **Updates connection strings:**
   - `Data Source` → target SQL Server hostname
   - `Initial Catalog` → target SQL Database name
3. **Sets impersonation mode:**
   - `ImpersonateServiceAccount` (default) - Uses service account
   - `ImpersonateWindowsUser` - Uses Windows user
   - `ImpersonateCustom` - Uses specified account
4. **Saves the modified BIM** - Writes updated JSON back to file

**Example transformation:**

```
Before (DEV):
  Data Source=dev-sql-server;Initial Catalog=Wealth_DEV

After (PROD):
  Data Source=prod-sql-server;Initial Catalog=Wealth_Prod
```

**Parameters:**

| Parameter | Description | Required |
|-----------|-------------|----------|
| `-BimPath` | Path to .bim file | Yes |
| `-ConfigFile` | JSON config with environment settings | Yes |
| `-SqlServer` | Target SQL Server hostname | Yes |
| `-SqlDatabase` | Target SQL Database name | Yes |
| `-ImpersonationMode` | Authentication mode | No |
| `-Backup` | Create backup before modifying | No |
| `-WhatIf` | Preview changes without making modifications | No |

---

#### Step 5: Deploy to SSAS (`deploy-cube.ps1`)

This is the main orchestration script that handles the actual deployment to SQL Server Analysis Services.

**What it does:**

1. **Load TOM Libraries** - Uses Microsoft.AnalysisServices.Tabular.dll
2. **Initialize Configuration** - Loads settings from parameters or config file
3. **Deserialize BIM** - Parses the JSON model
4. **Update Database Identity** - Sets the target database name
5. **Connect to SSAS** - Establishes connection to SSAS server
6. **Deploy Database:**
   - Creates new database if it doesn't exist
   - Or updates existing database with new model
7. **Update Roles** (if enabled) - Applies role memberships
8. **Process Model** - Refreshes data based on processing type

**Deployment Flow:**

```
deploy-cube.ps1 EXECUTION:
│
├── Step 1: Load TOM Libraries
│   └── Attempts GAC → Custom Path → Default Paths
│
├── Step 2: Initialize Configuration
│   └── Validates all required parameters
│
├── Step 3: Load BIM Model
│   └── Deserializes JSON to TOM Database object
│
├── Step 4: Update Datasources (if SqlServer provided)
│   └── Calls update-datasource.ps1 internally
│
├── Step 5: Connect to SSAS Server
│   └── Establishes connection using Tabular Object Model
│
├── Step 6: Deploy Database
│   └── CREATE: New database if not exists
│   └── UPDATE: Replace model in existing database
│
├── Step 7: Update Roles (if enabled)
│   └── Calls update-roles.ps1 internally
│
└── Step 8: Process Model
    └── Full: Reload all data
    └── Default: Auto-determine
    └── DataOnly: Refresh data only
    └── Calculate: Recalculate formulas only
    └── None: No processing
```

**Parameters:**

| Parameter | Description | Required |
|-----------|-------------|----------|
| `-BimPath` | Path to BIM file | Yes |
| `-SsasServer` | Target SSAS server | Yes |
| `-DatabaseName` | Target database name | Yes |
| `-SqlServer` | Source SQL Server | No |
| `-SqlDatabase` | Source SQL Database | No |
| `-ProcessType` | Processing type | No (default: None) |
| `-CreateDatabaseIfNotExists` | Create if not exists | No (default: true) |
| `-UpdateRoles` | Update role memberships | No (default: false) |
| `-RolesConfigFile` | Path to roles.json | No |
| `-BackupBeforeDeploy` | Backup existing database | No |
| `-WhatIf` | Preview changes | No |

---

#### Step 6: Update Roles (`update-roles.ps1`)

This script manages role-based security by mapping Active Directory (AD) security groups to SSAS roles based on the target environment.

**What it does:**

1. **Loads TOM Libraries** - Uses Microsoft.AnalysisServices.Tabular.dll
2. **Reads Roles Configuration** - Loads `roles.json` with role definitions and AD group mappings
3. **Deserializes BIM** - Parses the model from JSON
4. **Processes Each Role:**
   - Finds or creates the role in the model
   - Maps AD groups based on target environment (DEV/UAT/PROD)
   - Adds/removes/replaces members based on mode
5. **Serializes Back** - Saves the updated BIM file

**Role Configuration Structure:**

The `roles.json` file contains:

```json
{
  "roleDefinitions": [
    {
      "name": "Read Access",
      "category": "reporting",
      "description": "Standard read access",
      "permissions": {
        "model": ["Read"],
        "database": ["Read"]
      }
    }
  ],
  "environmentAssignments": {
    "DEV": {
      "adGroups": {
        "Read Access": ["DOMAIN\\DevTeam", "DOMAIN\\DevAdmin"]
      }
    },
    "PROD": {
      "adGroups": {
        "Read Access": ["DOMAIN\\ProdTeam", "DOMAIN\\ProdAdmin"]
      }
    }
  }
}
```

**Update Modes:**

| Mode | Description |
|------|-------------|
| `ReplaceMembers` | Remove all existing members, add new ones (default) |
| `AddMembers` | Add new members, keep existing |
| `RemoveMembers` | Remove specified members only |
| `Sync` | Synchronize membership (add missing, remove extra) |

**Parameters:**

| Parameter | Description | Required |
|-----------|-------------|----------|
| `-BimPath` | Path to .bim file | Yes |
| `-Environment` | Target environment (DEV, UAT, PROD) | Yes |
| `-RolesConfigFile` | Path to roles.json | Yes |
| `-Mode` | Update mode | No (default: ReplaceMembers) |
| `-Backup` | Create backup before modifying | No |
| `-DryRun` | Preview changes without making modifications | No |

---

## Script Details

### 1. validate-model.ps1

**Purpose:** Validates the SSAS Tabular model for errors and compliance before building

**What it checks:**
- JSON syntax validity
- Model schema (required properties)
- Compatibility level (1200/1400/1500/1600)
- Model file size
- Presence of tables and data sources
- Measures count
- Table relationships
- Datasource connection strings
- Partition definitions
- Security roles

**Usage:**
```powershell
.\validate-model.ps1 -ModelPath ".\Wealth.bim" -StrictMode -MaxSizeMB 100
```

---

### 2. update-datasource.ps1

**Purpose:** Updates connection strings in the BIM file to point to the correct SQL Server and database for the target environment

**What it does:**
- Parses BIM JSON
- Updates `Data Source` in connection string
- Updates `Initial Catalog` in connection string
- Sets impersonation mode
- Saves modified BIM

**Usage:**
```powershell
.\update-datasource.ps1 `
    -BimPath ".\Wealth.bim" `
    -ConfigFile ".\config\dev.json" `
    -SqlServer "prod-sql-server.database.com" `
    -SqlDatabase "Wealth_Prod" `
    -ImpersonationMode "ImpersonateServiceAccount"
```

---

### 3. update-roles.ps1

**Purpose:** Updates SSAS Tabular model role memberships for environment-specific AD security groups

**What it does:**
- Loads roles configuration from JSON
- Processes each role based on environment
- Maps AD groups to roles
- Supports Row-Level Security (RLS) with DAX expressions
- Creates backups before modifying

**Usage:**
```powershell
.\update-roles.ps1 `
    -BimPath ".\Wealth.bim" `
    -Environment "PROD" `
    -RolesConfigFile ".\config\roles.json" `
    -Mode "ReplaceMembers" `
    -Backup
```

---

### 4. deploy-cube.ps1

**Purpose:** Orchestrates the full deployment of the SSAS Tabular model to the target SSAS server

**What it does:**
- Loads TOM libraries
- Initializes configuration
- Deserializes BIM model
- Updates datasources (calls update-datasource.ps1)
- Connects to SSAS server
- Creates or updates database
- Updates roles (calls update-roles.ps1)
- Processes the model

**Usage:**
```powershell
.\deploy-cube.ps1 `
    -BimPath ".\Wealth.bim" `
    -SsasServer "localhost" `
    -DatabaseName "Wealth_Prod" `
    -SqlServer "prod-sql-server" `
    -SqlDatabase "Wealth_Prod" `
    -ProcessType "Full" `
    -UpdateRoles `
    -RolesConfigFile ".\config\roles.json"
```

---

## Pipeline Templates

### 1. build-cube.yml

**Purpose:** Build pipeline that validates and packages the model

**Stages:**
1. **Validate** - Runs validate-model.ps1
2. **Build** - Creates cube-artifact
3. **ReleaseBranch** - Prepares release (manual on main)

**Triggers:**
- Push to main, develop, feature/*, release/*
- Changes to src/**, scripts/**, templates/**

---

### 2. deploy-cube.yml

**Purpose:** Deploy pipeline that deploys to SSAS with environment-specific settings

**Steps:**
1. Download artifact
2. Show deployment info
3. Deploy cube (runs deploy-cube.ps1)

**Parameters:**
- environmentName (DEV/UAT/PROD)
- processType (None/Full/Default/DataOnly)
- updateRoles (true/false)
- backupBeforeDeploy (true/false)
- whatIf (true/false)

---

### 3. pr-validation.yml

**Purpose:** Validates model on every Pull Request

**Stages:**
1. **ValidateModel** - Structure and content validation
2. **SecurityCheck** - Check for sensitive data

**Checks performed:**
- BIM structure validation
- Hardcoded values detection
- Role configuration validation
- Measure definition validation
- Basic DAX expression check
- Security scan for sensitive data

---

## Environment Configurations

### Environment-Specific Settings

| Environment | SQL Server | Database | AD Groups | Processing |
|-------------|------------|----------|-----------|------------|
| **DEV** | Development SQL instance | Wealth_DEV | Development-specific groups | Full |
| **UAT** | UAT SQL instance | Wealth_UAT | UAT-specific groups | Full |
| **PROD** | Production SQL instance | Wealth_Prod | Production security groups | Full |

### Role Assignments by Environment

The roles.json file defines which AD groups have access to each role in each environment:

```json
{
  "environmentAssignments": {
    "DEV": { "adGroups": { "Read Access": ["DOMAIN\\DevTeam", ...] } },
    "UAT": { "adGroups": { "Read Access": ["DOMAIN\\UATTeam", ...] } },
    "PROD": { "adGroups": { "Read Access": ["DOMAIN\\ProdTeam", ...] } }
  }
}
```

---

## Azure DevOps Setup

### Required Variable Groups

Create variable groups in Azure DevOps Library:

1. **Wealth-Common** - Common variables across environments
2. **Wealth-DEV** - DEV environment specific variables
3. **Wealth-UAT** - UAT environment specific variables
4. **Wealth-PROD** - PROD environment specific variables

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `SsasServer` | SSAS server hostname | `localhost` or `server\instance` |
| `DatabaseName` | Target database name | `Wealth_DEV` |
| `SqlServer` | Source SQL Server | `localhost` |
| `SqlDatabase` | Source SQL Database | `Wealth_DEV` |

---

## Complete End-to-End Flow Example

### Scenario: Deploy to Production

```
1. DEVELOPER commits changes to Wealth.bim
   │
   ▼
2. BUILD PIPELINE triggers automatically
   ├── Validates model (validate-model.ps1) ✓
   ├── Packages artifact (cube-artifact) ✓
   └── Publishes to Azure Pipelines ✓
   │
   ▼
3. DEPLOYMENT to PROD is triggered (manual or release)
   ├── Downloads cube-artifact
   ├── Updates datasource:
   │   └── prod-sql-server.database.com / Wealth_Prod
   ├── Deploys to SSAS (deploy-cube.ps1)
   │   └── Creates/Updates Wealth_Prod database
   ├── Updates roles (update-roles.ps1)
   │   └── Maps PROD AD groups to roles
   └── Processes model (Full)
   │
   ▼
4. DEPLOYMENT COMPLETE
   └── Model available in PROD with correct 
       datasource and security settings
```

---

## Troubleshooting

### Common Issues

1. **TOM libraries not found**
   - Install SQL Server Management Studio (SSMS)
   - Or specify `-TomDllPath` parameter

2. **Connection failures**
   - Verify SSAS server is accessible
   - Check firewall settings
   - Verify credentials have sufficient permissions

3. **Role update failures**
   - Ensure AD groups exist and are accessible
   - Check group membership syntax (DOMAIN\GroupName)

---

## Version

Current Version: 2.1.0

Last Updated: 2024-01-15

