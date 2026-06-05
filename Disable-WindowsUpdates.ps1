param(
    [switch] $SkipServiceChanges,
    [switch] $SkipScheduledTaskChanges
)

# ============================================================
# Disable automatic Windows 10 update download/install behavior
# Run PowerShell as Administrator
# ============================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\StudentAccountTools.ps1"

function Set-WindowsUpdatePolicyRegistry {
    $WindowsUpdatePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $AuPolicyPath = Join-Path -Path $WindowsUpdatePolicyPath -ChildPath "AU"
    $CurrentVersionPolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate"
    $DriverSearchPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"
    $DriverSearchPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"
    $WindowsStorePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore"

    Set-RegistryDWord -Path $AuPolicyPath -Name "NoAutoUpdate" -Value 1
    Set-RegistryDWord -Path $AuPolicyPath -Name "AUOptions" -Value 2
    Set-RegistryDWord -Path $AuPolicyPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 1

    Set-RegistryDWord -Path $WindowsUpdatePolicyPath -Name "SetDisableUXWUAccess" -Value 1
    Set-RegistryDWord -Path $WindowsUpdatePolicyPath -Name "DisableWindowsUpdateAccess" -Value 1
    Set-RegistryDWord -Path $WindowsUpdatePolicyPath -Name "DoNotConnectToWindowsUpdateInternetLocations" -Value 1
    Set-RegistryDWord -Path $WindowsUpdatePolicyPath -Name "DisableDualScan" -Value 1
    Set-RegistryDWord -Path $WindowsUpdatePolicyPath -Name "ExcludeWUDriversInQualityUpdate" -Value 1

    Set-RegistryDWord -Path $CurrentVersionPolicyPath -Name "DisableWindowsUpdateAccess" -Value 1
    Set-RegistryDWord -Path $DriverSearchPolicyPath -Name "DontSearchWindowsUpdate" -Value 1
    Set-RegistryDWord -Path $DriverSearchPath -Name "SearchOrderConfig" -Value 0
    Set-RegistryDWord -Path $WindowsStorePolicyPath -Name "AutoDownload" -Value 2

    Write-Host "Applied Windows Update, driver update, and Store auto-download policies" -ForegroundColor Green
}

function Disable-ServiceSafely {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $Service = Get-Service -Name $Name -ErrorAction SilentlyContinue

    if (-not $Service) {
        Write-Host "Service not found: $Name" -ForegroundColor Yellow
        return
    }

    if ($Service.Status -ne "Stopped") {
        try {
            Stop-Service -Name $Name -Force -ErrorAction Stop
            Write-Host "Stopped service: $Name" -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not stop service $Name. $($_.Exception.Message)"
        }
    }

    try {
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        Write-Host "Disabled service startup: $Name" -ForegroundColor Green
        return
    }
    catch {
        Write-Warning "Set-Service could not disable $Name. Trying sc.exe."
    }

    $ScOutput = & sc.exe config $Name start= disabled 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Disabled service startup with sc.exe: $Name" -ForegroundColor Green
        return
    }

    Write-Warning "Could not disable service $Name. $($ScOutput -join ' ')"
}

function Disable-UpdateServices {
    $UpdateServices = @(
        "wuauserv",
        "UsoSvc",
        "WaaSMedicSvc",
        "BITS",
        "DoSvc",
        "InstallService"
    )

    foreach ($ServiceName in $UpdateServices) {
        Disable-ServiceSafely -Name $ServiceName
    }
}

function Disable-UpdateScheduledTasks {
    $UpdateTaskPaths = @(
        "\Microsoft\Windows\InstallService\",
        "\Microsoft\Windows\UpdateOrchestrator\",
        "\Microsoft\Windows\WaaSMedic\",
        "\Microsoft\Windows\WindowsUpdate\"
    )

    foreach ($TaskPath in $UpdateTaskPaths) {
        $Tasks = @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue)

        foreach ($Task in $Tasks) {
            try {
                Disable-ScheduledTask -InputObject $Task -ErrorAction Stop | Out-Null
                Write-Host "Disabled scheduled task: $($Task.TaskPath)$($Task.TaskName)" -ForegroundColor Green
            }
            catch {
                Write-Warning "Could not disable scheduled task $($Task.TaskPath)$($Task.TaskName). $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-ComputerPolicyRefresh {
    $GpUpdate = Get-Command -Name "gpupdate.exe" -ErrorAction SilentlyContinue

    if (-not $GpUpdate) {
        Write-Host "gpupdate.exe not found; restart Windows to apply all policy changes." -ForegroundColor Yellow
        return
    }

    $GpUpdateOutput = & gpupdate.exe /target:computer /force 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Refreshed computer policy" -ForegroundColor Green
        return
    }

    Write-Warning "gpupdate.exe failed. Restart Windows to apply all policy changes. $($GpUpdateOutput -join ' ')"
}

try {
    Assert-RunningAsAdmin

    Write-Host ""
    Write-Host "WARNING:" -ForegroundColor Red
    Write-Host "This disables automatic Windows, driver, and Microsoft Store update behavior."
    Write-Host "That can leave the computer without security patches until updates are re-enabled."
    Write-Host ""

    Set-WindowsUpdatePolicyRegistry

    if ($SkipServiceChanges) {
        Write-Host "Skipping Windows Update service changes." -ForegroundColor Yellow
    } else {
        Disable-UpdateServices
    }

    if ($SkipScheduledTaskChanges) {
        Write-Host "Skipping Windows Update scheduled task changes." -ForegroundColor Yellow
    } else {
        Disable-UpdateScheduledTasks
    }

    Invoke-ComputerPolicyRefresh

    Write-Host ""
    Write-Host "Windows automatic updates have been disabled as far as local policy allows." -ForegroundColor Cyan
    Write-Host "Restart the computer to make sure all service and policy changes are active."
    Write-Host "Some protected Windows components may be re-enabled by repairs or feature servicing."
}
catch {
    Write-Host ""
    Write-Host "Windows update disabling failed:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
