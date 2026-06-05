# ============================================================
# Setup restricted Student user for school/public PC
# Run PowerShell as Administrator
# ============================================================

$StudentUser = "Student"
$StudentPassword = "123456"   # CHANGE THIS PASSWORD if needed

# ============================================================
# 1. Check admin rights
# ============================================================

$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "Please run PowerShell as Administrator." -ForegroundColor Red
    exit
}

Write-Host "Running as Administrator..." -ForegroundColor Green

# ============================================================
# 2. Create Student user if it does not exist
# ============================================================

$ExistingUser = Get-LocalUser -Name $StudentUser -ErrorAction SilentlyContinue

if (-not $ExistingUser) {
    $SecurePassword = ConvertTo-SecureString $StudentPassword -AsPlainText -Force

    New-LocalUser `
        -Name $StudentUser `
        -Password $SecurePassword `
        -FullName "Student User" `
        -Description "Restricted student account for school computer" `
        -PasswordNeverExpires

    Write-Host "Created user: $StudentUser" -ForegroundColor Green
} else {
    Write-Host "User already exists: $StudentUser" -ForegroundColor Yellow

    # Optional: update password to match script
    $SecurePassword = ConvertTo-SecureString $StudentPassword -AsPlainText -Force
    Set-LocalUser -Name $StudentUser -Password $SecurePassword -PasswordNeverExpires $true

    Write-Host "Updated password for: $StudentUser" -ForegroundColor Green
}

# ============================================================
# 3. Add Student to Users group
# ============================================================

try {
    Add-LocalGroupMember -Group "Users" -Member $StudentUser -ErrorAction Stop
    Write-Host "Added $StudentUser to Users group" -ForegroundColor Green
} catch {
    Write-Host "$StudentUser is probably already in Users group" -ForegroundColor Yellow
}

# ============================================================
# 4. Remove Student from Administrators group
# ============================================================

try {
    Remove-LocalGroupMember -Group "Administrators" -Member $StudentUser -ErrorAction Stop
    Write-Host "Removed $StudentUser from Administrators group" -ForegroundColor Green
} catch {
    Write-Host "$StudentUser is not in Administrators group" -ForegroundColor Yellow
}

# ============================================================
# 5. Block Windows Installer system-wide
# ============================================================

$InstallerPolicyPath = "HKLM:\Software\Policies\Microsoft\Windows\Installer"

if (-not (Test-Path $InstallerPolicyPath)) {
    New-Item -Path $InstallerPolicyPath -Force | Out-Null
}

# DisableMSI = 2 means Windows Installer is always disabled
New-ItemProperty `
    -Path $InstallerPolicyPath `
    -Name "DisableMSI" `
    -Value 2 `
    -PropertyType DWord `
    -Force | Out-Null

# DisableUserInstalls = 1 blocks per-user MSI installs
New-ItemProperty `
    -Path $InstallerPolicyPath `
    -Name "DisableUserInstalls" `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null

Write-Host "Blocked Windows Installer and user installs" -ForegroundColor Green

# ============================================================
# 6. Block Microsoft Store system-wide
# ============================================================

$StorePolicyPath = "HKLM:\Software\Policies\Microsoft\WindowsStore"

if (-not (Test-Path $StorePolicyPath)) {
    New-Item -Path $StorePolicyPath -Force | Out-Null
}

New-ItemProperty `
    -Path $StorePolicyPath `
    -Name "RemoveWindowsStore" `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null

Write-Host "Blocked Microsoft Store" -ForegroundColor Green

# ============================================================
# 7. Apply Student-specific restrictions
# ============================================================

$StudentProfilePath = "C:\Users\$StudentUser"
$StudentHivePath = "$StudentProfilePath\NTUSER.DAT"
$TempHiveName = "HKU\TempStudentHive"

if (-not (Test-Path $StudentHivePath)) {
    Write-Host ""
    Write-Host "Student profile does not exist yet." -ForegroundColor Yellow
    Write-Host "Log in once as Student, then log out and run this script again." -ForegroundColor Yellow
    Write-Host "Auto-login will still be configured below." -ForegroundColor Yellow
} else {
    try {
        # Load Student registry hive
        reg load $TempHiveName $StudentHivePath | Out-Null

        $StudentPoliciesPath = "Registry::$TempHiveName\Software\Microsoft\Windows\CurrentVersion\Policies"
        $ExplorerPath = "$StudentPoliciesPath\Explorer"
        $SystemPath = "$StudentPoliciesPath\System"

        if (-not (Test-Path $ExplorerPath)) {
            New-Item -Path $ExplorerPath -Force | Out-Null
        }

        if (-not (Test-Path $SystemPath)) {
            New-Item -Path $SystemPath -Force | Out-Null
        }

        # Block Control Panel and Settings
        New-ItemProperty `
            -Path $ExplorerPath `
            -Name "NoControlPanel" `
            -Value 1 `
            -PropertyType DWord `
            -Force | Out-Null

        # Disable CMD
        # 1 = disable command prompt and batch files
        # 2 = disable command prompt but allow batch files
        New-ItemProperty `
            -Path $SystemPath `
            -Name "DisableCMD" `
            -Value 1 `
            -PropertyType DWord `
            -Force | Out-Null

        # Disable Registry Editor
        New-ItemProperty `
            -Path $SystemPath `
            -Name "DisableRegistryTools" `
            -Value 1 `
            -PropertyType DWord `
            -Force | Out-Null

        Write-Host "Applied user-specific restrictions to $StudentUser" -ForegroundColor Green
    }
    finally {
        # Unload Student registry hive
        reg unload $TempHiveName | Out-Null
    }
}

# ============================================================
# 8. Enable automatic login for Student user
# ============================================================

$ComputerName = $env:COMPUTERNAME
$WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

Set-ItemProperty `
    -Path $WinlogonPath `
    -Name "AutoAdminLogon" `
    -Value "1" `
    -Type String

Set-ItemProperty `
    -Path $WinlogonPath `
    -Name "DefaultUserName" `
    -Value $StudentUser `
    -Type String

Set-ItemProperty `
    -Path $WinlogonPath `
    -Name "DefaultPassword" `
    -Value $StudentPassword `
    -Type String

Set-ItemProperty `
    -Path $WinlogonPath `
    -Name "DefaultDomainName" `
    -Value $ComputerName `
    -Type String

Write-Host "Automatic login enabled for $StudentUser" -ForegroundColor Green

# ============================================================
# 9. Final message
# ============================================================

Write-Host ""
Write-Host "Setup completed." -ForegroundColor Cyan
Write-Host ""
Write-Host "Important next step:" -ForegroundColor Yellow
Write-Host "1. Restart the computer."
Write-Host "2. It should automatically log in as Student."
Write-Host "3. If you saw the profile warning, log out from Student, log in as admin, and run this script again."
Write-Host ""
Write-Host "WARNING:" -ForegroundColor Red
Write-Host "Auto-login stores the Student password in Windows registry."
Write-Host "Use this only for a restricted Student account, never for an admin account."