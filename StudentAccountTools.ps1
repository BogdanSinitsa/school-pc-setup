function Assert-RunningAsAdmin {
    $CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal] $CurrentIdentity

    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Please run PowerShell as Administrator."
    }

    Write-Host "Running as Administrator..." -ForegroundColor Green
}

function Ensure-RegistryKey {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
}

function Set-RegistryDWord {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [int] $Value
    )

    Ensure-RegistryKey -Path $Path

    New-ItemProperty `
        -Path $Path `
        -Name $Name `
        -Value $Value `
        -PropertyType DWord `
        -Force | Out-Null
}

function Set-RegistryString {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Name,

        [AllowEmptyString()]
        [Parameter(Mandatory)]
        [string] $Value
    )

    Ensure-RegistryKey -Path $Path

    New-ItemProperty `
        -Path $Path `
        -Name $Name `
        -Value $Value `
        -PropertyType String `
        -Force | Out-Null
}

function Ensure-StudentUser {
    param(
        [Parameter(Mandatory)]
        [string] $StudentUser,

        [Parameter(Mandatory)]
        [string] $StudentPassword
    )

    $SecurePassword = ConvertTo-SecureString $StudentPassword -AsPlainText -Force
    $ExistingUser = Get-LocalUser -Name $StudentUser -ErrorAction SilentlyContinue

    if (-not $ExistingUser) {
        New-LocalUser `
            -Name $StudentUser `
            -Password $SecurePassword `
            -FullName "Student User" `
            -Description "Restricted student account for school computer" `
            -PasswordNeverExpires | Out-Null

        Write-Host "Created user: $StudentUser" -ForegroundColor Green
        return
    }

    Set-LocalUser `
        -Name $StudentUser `
        -Password $SecurePassword `
        -PasswordNeverExpires $true

    if (-not $ExistingUser.Enabled) {
        Enable-LocalUser -Name $StudentUser
    }

    Write-Host "Updated existing user: $StudentUser" -ForegroundColor Green
}

function Test-LocalUserInGroup {
    param(
        [Parameter(Mandatory)]
        [string] $StudentUser,

        [Parameter(Mandatory)]
        [string] $Group
    )

    $User = Get-LocalUser -Name $StudentUser -ErrorAction Stop
    $UserSid = $User.SID.Value

    $Members = Get-LocalGroupMember -Group $Group -ErrorAction Stop

    foreach ($Member in $Members) {
        $MemberSid = if ($Member.SID -is [Security.Principal.SecurityIdentifier]) {
            $Member.SID.Value
        } else {
            [string] $Member.SID
        }

        if ($MemberSid -eq $UserSid) {
            return $true
        }
    }

    return $false
}

function Ensure-StandardUser {
    param(
        [Parameter(Mandatory)]
        [string] $StudentUser
    )

    if (-not (Test-LocalUserInGroup -StudentUser $StudentUser -Group "Users")) {
        Add-LocalGroupMember -Group "Users" -Member $StudentUser -ErrorAction Stop
        Write-Host "Added $StudentUser to Users group" -ForegroundColor Green
    } else {
        Write-Host "$StudentUser is already in Users group" -ForegroundColor Yellow
    }

    if (Test-LocalUserInGroup -StudentUser $StudentUser -Group "Administrators") {
        Remove-LocalGroupMember -Group "Administrators" -Member $StudentUser -ErrorAction Stop
        Write-Host "Removed $StudentUser from Administrators group" -ForegroundColor Green
    } else {
        Write-Host "$StudentUser is not in Administrators group" -ForegroundColor Yellow
    }
}

function Set-InstallerRestrictions {
    $InstallerPolicyPath = "HKLM:\Software\Policies\Microsoft\Windows\Installer"

    # DisableMSI = 2 disables Windows Installer.
    Set-RegistryDWord -Path $InstallerPolicyPath -Name "DisableMSI" -Value 2

    # DisableUserInstalls = 1 blocks per-user MSI installs.
    Set-RegistryDWord -Path $InstallerPolicyPath -Name "DisableUserInstalls" -Value 1

    Write-Host "Blocked Windows Installer and user MSI installs" -ForegroundColor Green
}

function Set-StoreRestrictions {
    $StorePolicyPath = "HKLM:\Software\Policies\Microsoft\WindowsStore"

    Set-RegistryDWord -Path $StorePolicyPath -Name "RemoveWindowsStore" -Value 1

    Write-Host "Blocked Microsoft Store app" -ForegroundColor Green
}

function Get-StudentProfilePath {
    param(
        [Parameter(Mandatory)]
        [string] $StudentUser
    )

    $User = Get-LocalUser -Name $StudentUser -ErrorAction Stop
    $ProfileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    $ProfileRegistryPath = Join-Path -Path $ProfileListPath -ChildPath $User.SID.Value

    if (Test-Path -Path $ProfileRegistryPath) {
        $Profile = Get-ItemProperty -Path $ProfileRegistryPath -ErrorAction Stop

        if ($Profile.ProfileImagePath) {
            return [Environment]::ExpandEnvironmentVariables($Profile.ProfileImagePath)
        }
    }

    return "C:\Users\$StudentUser"
}

function Invoke-WithStudentUserHive {
    param(
        [Parameter(Mandatory)]
        [string] $StudentUser,

        [Parameter(Mandatory)]
        [scriptblock] $Action
    )

    $User = Get-LocalUser -Name $StudentUser -ErrorAction Stop
    $LoadedHiveRoot = "Registry::HKEY_USERS\$($User.SID.Value)"

    if (Test-Path -Path $LoadedHiveRoot) {
        & $Action $LoadedHiveRoot
        return $true
    }

    $StudentProfilePath = Get-StudentProfilePath -StudentUser $StudentUser
    $StudentHivePath = Join-Path -Path $StudentProfilePath -ChildPath "NTUSER.DAT"
    $TempHiveKey = "TempStudentHive"
    $TempHiveRegPath = "HKU\$TempHiveKey"
    $TempHiveRoot = "Registry::HKEY_USERS\$TempHiveKey"
    $LoadedByScript = $false

    if (-not (Test-Path -LiteralPath $StudentHivePath)) {
        Write-Host ""
        Write-Host "$StudentUser profile does not exist yet." -ForegroundColor Yellow
        Write-Host "Log in once as $StudentUser, then log out and run this script again." -ForegroundColor Yellow
        Write-Host "Auto-login can still be configured before the profile exists." -ForegroundColor Yellow
        return $false
    }

    if (Test-Path -Path $TempHiveRoot) {
        throw "Temporary registry hive $TempHiveRegPath is already loaded. Unload it first or choose a different temporary hive name."
    }

    try {
        $LoadOutput = & reg.exe load $TempHiveRegPath $StudentHivePath 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to load $StudentHivePath into $TempHiveRegPath. $($LoadOutput -join ' ')"
        }

        $LoadedByScript = $true
        & $Action $TempHiveRoot
        return $true
    }
    finally {
        if ($LoadedByScript) {
            [GC]::Collect()
            Start-Sleep -Milliseconds 200

            $UnloadOutput = & reg.exe unload $TempHiveRegPath 2>&1

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to unload $TempHiveRegPath. $($UnloadOutput -join ' ')"
            }
        }
    }
}

function Remove-CmdRestrictionFromHive {
    param(
        [Parameter(Mandatory)]
        [string] $HiveRoot
    )

    $SystemPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Microsoft\Windows\CurrentVersion\Policies\System"

    Ensure-RegistryKey -Path $SystemPath

    Remove-ItemProperty `
        -Path $SystemPath `
        -Name "DisableCMD" `
        -ErrorAction SilentlyContinue
}

function Remove-CmdRestrictionForStudent {
    param(
        [string] $StudentUser = "Student"
    )

    $Applied = Invoke-WithStudentUserHive -StudentUser $StudentUser -Action {
        param(
            [string] $HiveRoot
        )

        Remove-CmdRestrictionFromHive -HiveRoot $HiveRoot
    }

    if ($Applied) {
        Write-Host "CMD restriction removed or confirmed absent for $StudentUser" -ForegroundColor Green
    }

    return $Applied
}

function Set-StudentUserPolicies {
    param(
        [string] $StudentUser = "Student"
    )

    $Applied = Invoke-WithStudentUserHive -StudentUser $StudentUser -Action {
        param(
            [string] $HiveRoot
        )

        $PoliciesPath = Join-Path `
            -Path $HiveRoot `
            -ChildPath "Software\Microsoft\Windows\CurrentVersion\Policies"
        $ExplorerPath = Join-Path -Path $PoliciesPath -ChildPath "Explorer"
        $SystemPath = Join-Path -Path $PoliciesPath -ChildPath "System"

        # Block Control Panel and Settings.
        Set-RegistryDWord -Path $ExplorerPath -Name "NoControlPanel" -Value 1

        # Block Registry Editor.
        Set-RegistryDWord -Path $SystemPath -Name "DisableRegistryTools" -Value 1

        # Keep CMD available for IT lessons.
        Remove-CmdRestrictionFromHive -HiveRoot $HiveRoot
    }

    if ($Applied) {
        Write-Host "Applied user-specific restrictions to $StudentUser; CMD remains allowed" -ForegroundColor Green
    }

    return $Applied
}

function Enable-StudentAutoLogin {
    param(
        [Parameter(Mandatory)]
        [string] $StudentUser,

        [Parameter(Mandatory)]
        [string] $StudentPassword
    )

    $WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

    Set-RegistryString -Path $WinlogonPath -Name "AutoAdminLogon" -Value "1"
    Set-RegistryString -Path $WinlogonPath -Name "DefaultUserName" -Value $StudentUser
    Set-RegistryString -Path $WinlogonPath -Name "DefaultPassword" -Value $StudentPassword
    Set-RegistryString -Path $WinlogonPath -Name "DefaultDomainName" -Value $env:COMPUTERNAME

    Write-Host "Automatic login enabled for $StudentUser" -ForegroundColor Green
}

function Disable-StudentAutoLogin {
    param(
        [string] $StudentUser = "Student"
    )

    $WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $CurrentWinlogon = Get-ItemProperty -Path $WinlogonPath -ErrorAction SilentlyContinue

    Set-RegistryString -Path $WinlogonPath -Name "AutoAdminLogon" -Value "0"

    if ($CurrentWinlogon.DefaultUserName -eq $StudentUser) {
        Remove-ItemProperty -Path $WinlogonPath -Name "DefaultUserName" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $WinlogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $WinlogonPath -Name "DefaultDomainName" -ErrorAction SilentlyContinue
    }

    Write-Host "Automatic login disabled for $StudentUser" -ForegroundColor Green
}
