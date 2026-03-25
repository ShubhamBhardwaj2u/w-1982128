# Update-Datasource.ps1 Implementation Plan

## ✅ COMPLETED 12/12

All steps completed. Script fully implemented with modular functions following update-roles.ps1 pattern.

**Final Testing Commands:**
```
# Dry run (validate + preview)
.\update-datasource.ps1 -BimPath "wealth-cube/src/model/Wealth.bim" -DatasourcesConfigFile "wealth-cube/config/datasources/dev.yml" -Environment DEV -DryRun

# Strict validation + update  
.\update-datasource.ps1 -BimPath "wealth-cube/src/model/Wealth.bim" -DatasourcesConfigFile "wealth-cube/config/datasources/dev.yml" -Environment DEV -StrictMode

# UAT example
.\update-datasource.ps1 -BimPath "wealth-cube/src/model/Wealth.bim" -DatasourcesConfigFile "wealth-cube/config/datasources/uat.yml" -Environment UAT
```


✅ 11. **Add save function** - Save-Bim: ConvertTo-Json -Depth 10, write back to BimPath only if not DryRun.

✅ 10. **Add main update function** - Update-Datasources: Loop BIM datasources, find YAML match, apply updates only if not DryRun.

✅ 9. **Add connection string update function** - Update-ConnectionString: Precise regex replace Data Source=... and Initial Catalog=..., force impersonationMode = "impersonateServiceAccount".

✅ 8. **Add DryRun preview function** - Preview-Changes: For each matching datasource, show OLD server/DB/impersonation → NEW from YAML.

✅ 7. **Add partition reference validation** - Scan all tables[].partitions[].source.dataSource, collect references, validate all refs exist in BIM datasources, StrictMode: all BIM datasources referenced at least once.

✅ 6. **Add datasource sync validation** - Compare YAML datasources vs BIM: YAML missing in BIM → error, BIM extras → StrictMode error / warning.

✅ 1. **Add exact required parameters** - BimPath (mandatory), DatasourcesConfigFile (mandatory), Environment (DEV/UAT/PROD mandatory), StrictMode (switch), DryRun (switch). Remove all other parameters.

✅ 2. **Add script-scope variables** - $script:ValidationErrors = @(), $script:Colors hashtable for logging.

✅ 3. **Add core logging functions** - Write-Log (timestamped colored output), Write-Section (headers), Add-ValidationError (collects errors).

✅ 4. **Add YAML validation function** - Test-YamlStructure: Load powershell-yaml, validate environment matches parameter, datasources array exists/non-empty, unique names (case-insensitive), each has name/server/database.

✅ 5. **Add BIM loading/validation function** - Test-BimDatasources: Load JSON safely, validate dataSources array exists/non-empty.

6. **Add datasource sync validation** - Compare YAML datasources vs BIM: YAML missing in BIM → error, BIM extras → StrictMode error / warning.

7. **Add partition reference validation** - Scan all tables[].partitions[].source.dataSource, collect references, validate all refs exist in BIM datasources, StrictMode: all BIM datasources referenced at least once.

8. **Add DryRun preview function** - Preview-Changes: For each matching datasource, show OLD server/DB/impersonation → NEW from YAML.

9. **Add connection string update function** - Update-ConnectionString: Precise regex replace Data Source=... and Initial Catalog=..., force impersonationMode = "impersonateServiceAccount".

10. **Add main update function** - Update-Datasources: Loop BIM datasources, find YAML match, apply updates only if not DryRun.

11. **Add save function** - Save-Bim: ConvertTo-Json -Depth 10, write back to BimPath only if not DryRun.

12. **Implement main execution flow** - Validate files exist → Test-YamlStructure → Test-BimDatasources → Sync validation → Partition validation → DryRun? Preview : Update → Save → Exit 0 (success) or 1 (validation errors).

## Testing Commands:
```
# Dry run preview
.\update-datasource.ps1 -BimPath "wealth-cube/src/model/Wealth.bim" -DatasourcesConfigFile "wealth-cube/config/datasources/dev.yml" -Environment DEV -DryRun

# Strict mode actual update
.\update-datasource.ps1 -BimPath "wealth-cube/src/model/Wealth.bim" -DatasourcesConfigFile "wealth-cube/config/datasources/dev.yml" -Environment DEV -StrictMode
```

