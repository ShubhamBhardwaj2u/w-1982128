param(
[Parameter(Mandatory=$true)]
[string]$BimPath
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Validating BIM role memberships..."
Write-Host ""

if (!(Test-Path $BimPath)) {
Write-Error "BIM file not found: $BimPath"
exit 1
}

$json = Get-Content $BimPath -Raw | ConvertFrom-Json

if (-not $json.model.roles) {
Write-Host "No roles defined in BIM. Validation passed."
exit 0
}

$violations = @()

foreach ($role in $json.model.roles) {

```
if ($role.members -and $role.members.Count -gt 0) {

    foreach ($member in $role.members) {

        $violations += [PSCustomObject]@{
            Role   = $role.name
            Member = $member.name
        }

    }

}
```

}

if ($violations.Count -gt 0) {

```
Write-Host ""
Write-Host "❌ ERROR: BIM file contains role members."
Write-Host "Roles must NOT contain members in the BIM file."
Write-Host "Use YAML role configuration instead."
Write-Host ""

foreach ($v in $violations) {
    Write-Host "Role: $($v.Role)  ->  Member: $($v.Member)"
}

Write-Host ""
Write-Host "Remove these members from the BIM file."
Write-Host ""

exit 1
```

}

Write-Host "✔ BIM role validation passed."
exit 0
