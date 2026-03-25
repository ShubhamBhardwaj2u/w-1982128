# Cube.js SSAS Datasource Update Tool
`update-datasource.ps1` - Synchronizes SQL Server connection details from YAML config to SSAS BIM model.

## Purpose
Updates datasource `connectionString` (server/database) and `impersonationMode` in Tabular BIM files based on environment-specific YAML configs.

**Key Features:**
- ✅ Multi-datasource support
- ✅ Case-insensitive name matching
- ✅ Dry-run preview mode
- ✅ Strict validation modes
- ✅ YAML structure validation
- ✅ Preserves annotations/original formatting

## Prerequisites
```
PowerShell 5.1+
powershell-yaml module (auto-installs)
```

## Usage
```
cd wealth-devops-framework/scripts/cube
.\update-datasource.ps1 -BimPath \"../../../wealth-cube/src/model/Wealth.bim\" -DatasourcesConfigFile \"../../../wealth-cube/config/datasources/[ENV].yml\" -Environment [DEV|UAT|PROD] [-DryRun] [-StrictMode]
```

### Examples

**1. DEV Dry Run (Validate + Preview)**
```powershell
.\update-datasource.ps1 -BimPath "../../../wealth-cube/src/model/Wealth.bim" -DatasourcesConfigFile "../../../wealth-cube/config/datasources/dev.yml" -Environment DEV -DryRun
```

**2. DEV Live Update**
```powershell
.\update-datasource.ps1 -BimPath "../../../wealth-cube/src/model/Wealth.bim" -DatasourcesConfigFile "../../../wealth-cube/config/datasources/dev.yml" -Environment DEV -StrictMode
```

**3. UAT Example**
```powershell
.\update-datasource.ps1 -BimPath "../../../wealth-cube/src/bin/Wealth.bim" -DatasourcesConfigFile "../../../wealth-cube/config/datasources/uat.yml" -Environment UAT
```

## YAML Format
```yaml
environment: DEV  # DEV|UAT|PROD (validated)
datasources:     # 1+ datasources
  - name: EDW_WEALTH_DATAMART      # Must match BIM datasource.name
    server: dev-sql-server.wealth.local
    database: EDW_WEALTH_DATAMART_DEV
  - name: SECOND_DATAMART
    server: dev-second-server.wealth.local  
    database: SECOND_DB_DEV
```

## Workflow
```
1. Validates YAML structure/duplicates
2. Loads BIM model datasources
3. Sync validation (fail if YAML DS missing in BIM)
4. Updates matching DS:
   - Data Source= → yaml.server
   - Initial Catalog= → yaml.database  
   - impersonationMode → \"impersonateServiceAccount\"
5. Saves BIM (unless -DryRun)
```

## Behaviors
| Case | Result |
|------|--------|
| Matching DS | ✅ Updates server/DB/impersonation |
| BIM-only DS | ⚠️ Warning: \"No YAML config, skipping\" |
| YAML-only DS | ❌ **ERROR**: \"YAML datasources missing in BIM\" |
| Multi-DS | ✅ Processes all matches independently |

## Testing Status
✅ Single DS (project original)  
✅ Multi-DS (2+ datasources)  
✅ Mismatch validation  
✅ Dry-run preview  
✅ StrictMode warnings→errors

## Error Codes
- `Exit 1`: Validation failed (YAML parse/mismatch)
- `Exit 0`: Success (dry-run or updated)

**Safe for CI/CD** - validates before modifying.
