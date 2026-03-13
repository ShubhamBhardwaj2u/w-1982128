# SSAS Cube PowerShell Scripts - Developer Reference

## Architecture & Design

### `update-roles.ps1` - Role Synchronization Engine

**Single Source of Truth:** YAML files (`wealth-cube/config/roles/{env}.yml`)

**Strict Synchronization Flow:**
```
1. Load YAML → Validate structure/format/duplicates
2. Load BIM via TOM → DeserializeDatabase()
3. RoleSync validation:
   - YAML roles ⊆ BIM roles (missing → FAIL)
   - BIM roles ⊆ YAML roles (extra → FAIL) 
   - Case-sensitive exact match
4. Member replacement: Members.Clear() + Add WindowsGroupMember
5. SerializeDatabase() → NoNewline UTF8 save
```

**Validation Rules (Pipeline FAIL conditions):**
| Check | Fail Condition | Error Message |
|-------|----------------|---------------|
| Environment | YAML.env != param | "Environment mismatch" |
| Role Structure | YAML missing in BIM | "Role 'X' exists in YAML but missing in BIM" |
| Extra Roles | BIM has YAML-undefined | "Role 'X' exists in BIM but not in YAML" |
| Duplicates | Case-insensitive YAML dupes | "Duplicate role names detected" |
| Member Format | !`^[^\\]+\\[^\\]+$` | "Invalid member format" |

**TOM Implementation:**
```powershell
# Loading (GAC → fallback paths)
Add-Type -AssemblyName "Microsoft.AnalysisServices.Core,Tabular"

# Role lookup (safe)
$database.Model.Roles.Find($name)

# Group members (AD groups)
[Microsoft.AnalysisServices.Tabular.WindowsGroupMember]::new($group)
```

**Defensive Features:**
- Null-check Model.Roles
- DryRun: Compare-Object shows <= REMOVE, => ADD
- AD optional: Get-ADGroup -Identity (warning-only)
- YAML safe-install: try/catch fail message

### `validate-model.ps1` - Model Integrity Checker

**Comprehensive 10-Step Pipeline:**
1. JSON syntax (`ConvertFrom-Json`)
2. Root schema (name/compatibilityLevel/model)
3. Compatibility (1200-1600)
4. Required objects (tables)
5. Measures count
6. Relationships (fromTable/toTable)
7. Datasources (name/connectionString)
8. Partitions existence
9. Roles (name required)
10. Summary with strict mode

**StrictMode:** Warnings → Errors

## Deployment Patterns

**PR Validation (`wealth-cube/pipelines/pr-validation.yml`):**
```yaml
steps:
- script: wealth-devops-framework/scripts/cube/validate-model.ps1 -ModelPath Wealth.bim -StrictMode
- script: wealth-devops-framework/scripts/cube/validate-bim-roles.ps1 -BimPath Wealth.bim
```

**Environment Deploy (`wealth-cube/pipelines/cube-{env}.yml`):**
```yaml
steps:
- checkout: self
- task: PowerShell@2
  inputs:
    script: |
      cd src/model
      ../../../wealth-devops-framework/scripts/cube/update-roles.ps1 `
        -BimPath Wealth.bim `
        -Environment $(Environment) `
        -RolesConfigFile $(Pipeline.Workspace)/config/roles/$(Environment).yml
```

## Extensibility

**Custom Validations:** Add functions to main if-block, return $false on fail.

**TOM Fallback Paths:**
```
SSMS 19: CommonExtensions\Microsoft\AnalysisServices\Project\*.dll
SSMS 18: same
SQL SDK 150: SDK\Assemblies\*.dll
```

**YAML Schema (enforced):**
```yaml
environment: [DEV|UAT|PROD]
roles[]:
  name: string
  members[]: ["DOMAIN\\Group"]  # regex ^[^\\]+\\[^\\]+$
```

## Error Patterns & Recovery

| Error | Cause | Fix |
|-------|-------|-----|
| "TOM libraries" | No SSMS | Install SSMS/SQL SDK |
| "Role missing" | BIM drift | Rebuild BIM or add to YAML |
| "YAML install fail" | Network | `Install-Module powershell-yaml` manually |
| "Invalid member" | Bad format | Fix DOMAIN\Group syntax |

## Testing Matrix

```
DryRun + Verbose → Plan changes
StrictMode validate-model → PR gate
No -AllowRoleCreation → Production safety
```

**Self-Test:**
```powershell
# In wealth-cube/src/model
$env:Environment = "DEV"
../../wealth-devops-framework/scripts/cube/update-roles.ps1 -BimPath Wealth.bim -Environment DEV -RolesConfigFile ../../../config/roles/dev.yml -DryRun -Verbose
```

