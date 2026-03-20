# Update-Roles

## Overview -

Purpose: Automatically synchronizes Active Directory group access from simple YAML configuration files into Cube model.


Business Value:
- Zero manual role management
- Environment isolation (DEV/UAT/PROD separate)
- Audit trail
- Onboarding/offboarding in 30 seconds

<br>

## File Locations

| Environment | Configuration File | Access Groups Members |
|-------------|-------------------|----------------------|
| DEV | wealth-cube/config/roles/dev.yml | Developers + Test users |
| UAT | wealth-cube/config/roles/uat.yml | Business acceptance testers |
| PROD | wealth-cube/config/roles/prod.yml | Live business users |

<br>

##  *Simple Configuration Format*

**Example (`dev.yml`):**
```yaml
environment: <env>                     # Environment
roles:
  - name: "<role-name>"                # Role-Name
    members:
      - "DOMAIN\\Member1"              # Members
      - "DOMAIN\\Member2"
```

<br>

### Test Cases - Real Scenarios



* Test 1: Perfect Match (No Changes)
  ```
  YAML: Read Access = 8 groups
  BIM: Read Access = 8 groups (same)
  RESULT: SUCCESS - No changes needed
  ```


* Test 2: Member Added in YAML (New Team Member)
  ```
  BIM Read Access: 8 groups
  YAML Read Access: 9 groups (+1 new AD group)
  RESULT: UPDATED: 8->9 members
  ```


* Test 3: Member Removed from YAML (Offboarding)
  ```
  BIM Read Access: 8 groups
  YAML Read Access: 6 groups (-2 removed)
  RESULT: UPDATED: 8->6 members
  ```
 

* Test 4: Role Added in YAML but Missing in BIM
  ```
  YAML has new "HR Team" role
  BIM missing "HR Team" role
  RESULT: FAIL - Role missing in BIM
  ```


* Test 6: Role Added in BIM but Missing in YAML
  ```
  BIM has extra "Old Role"
  YAML missing "Old Role"
  RESULT: FAIL - Extra role in BIM (Strict Mode)
  ```


* Test 7: Broken Group Name
  ```
  YAML: "FinanceUsers" (missing WINTRUST\\)
  RESULT: FAIL: Invalid member format
  ```


* Test 8: Wrong Environment
  ```
  -RolesConfigFile "prod.yml" -Environment "DEV"
  RESULT: FAIL: Environment mismatch
  ```

<br>


## Environment Comparison

| Role | DEV Groups | UAT Groups | PROD Groups |
|------|------------|------------|-------------|
| Read Access | 8 | 8 | 8 |
| Read_Process | 3 | 3 | 1 |
| CTC/WTI/GLA | 1 each | 1 each | 1 each |

<br>

## Built-in Safety Features

| Protection | What Happens | Business Benefit |
|------------|-------------|-----------------|
| Environment Lock | DEV config -> DEV only | No PROD accidents |
| Strict Sync | BIM must match YAML exactly | No access drift |
| Format Validation | DOMAIN\\GroupName only | No typos |
| Dry Run | Preview before save | Confidence |
| Pipeline Integration | Auto-runs on every deploy | Always current |
