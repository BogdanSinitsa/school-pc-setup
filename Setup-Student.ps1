param(
    [string] $StudentUser = "Student",
    [string] $StudentPassword = "Student123!",
    [switch] $DisableAutoLogin
)

# ============================================================
# Setup restricted Student user for school/public PC
# Run PowerShell as Administrator
# ============================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\StudentAccountTools.ps1"

try {
    Assert-RunningAsAdmin

    if ($DisableAutoLogin) {
        Disable-StudentAutoLogin -StudentUser $StudentUser

        Write-Host ""
        Write-Host "Auto-login disabled." -ForegroundColor Cyan
        exit 0
    }

    Ensure-StudentUser -StudentUser $StudentUser -StudentPassword $StudentPassword
    Ensure-StandardUser -StudentUser $StudentUser
    Set-InstallerRestrictions
    Set-StoreRestrictions
    Set-StudentUserPolicies -StudentUser $StudentUser
    Enable-StudentAutoLogin -StudentUser $StudentUser -StudentPassword $StudentPassword

    Write-Host ""
    Write-Host "Setup completed." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Important next step:" -ForegroundColor Yellow
    Write-Host "1. Restart the computer."
    Write-Host "2. It should automatically log in as $StudentUser."
    Write-Host "3. If you saw the profile warning, log out from $StudentUser, log in as admin, and run this script again."
    Write-Host ""
    Write-Host "WARNING:" -ForegroundColor Red
    Write-Host "Auto-login stores the $StudentUser password in Windows registry."
    Write-Host "Use this only for a restricted Student account, never for an admin account."
}
catch {
    Write-Host ""
    Write-Host "Setup failed:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
