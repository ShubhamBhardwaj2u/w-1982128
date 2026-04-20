# Cube Backup Production Cleanup TODO

**Status:** Production Ready ✅

**Changes Applied:**
- [x] Removed all colors (`$Colors` hashtable, `-ForegroundColor`)
- [x] SqlServer module PRIMARY (no custom DLL paths)
- [x] Simplified fallback (GAC only)  
- [x] Plain logging (pipeline-friendly)
- [x] PS5/PS7 compatible

**Final Script Features:**
```
Primary: Import-Module SqlServer → Backup-ASDatabase  
Fallback: Add-Type Microsoft.AnalysisServices.Core → Database.Backup()
Keep: All original functions, WhatIf, pipeline vars, env folders
```

**Test:**
```powershell
powershell.exe -File "wealth-devops-framework/scripts/cube/backup-cube.ps1" -SsasServer "localhost" -DatabaseName "Wealth" -Environment "DEV" -BackupRootPath "C:\backups" -WhatIf
```

**PS5/7 Verified** ✅

