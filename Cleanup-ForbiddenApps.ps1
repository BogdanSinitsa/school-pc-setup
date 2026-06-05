param(
    [string] $StudentUser = "Student",
    [string[]] $Apps = @("All"),
    [switch] $ListApps
)

# ============================================================
# Cleanup forbidden per-user apps and games from Student profile
# Run PowerShell as Administrator from an admin account
# ============================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\StudentAccountTools.ps1"

$ForbiddenAppDefinitions = @(
    @{
        Name = "Roblox"
        ProcessPatterns = @("*Roblox*")
        Paths = @(
            @{
                Scope = "StudentProfile"
                Path = "AppData\Local\Roblox"
                Wildcard = $false
            },
            @{
                Scope = "StudentProfile"
                Path = "AppData\Local\RobloxStudio"
                Wildcard = $false
            },
            @{
                Scope = "StudentProfile"
                Path = "AppData\Local\Temp\Roblox*"
                Wildcard = $true
            },
            @{
                Scope = "StudentProfile"
                Path = "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Roblox*"
                Wildcard = $true
            },
            @{
                Scope = "StudentProfile"
                Path = "Desktop\Roblox*.lnk"
                Wildcard = $true
            },
            @{
                Scope = "Absolute"
                Path = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Roblox*"
                Wildcard = $true
            }
        )
    }
)

function Get-ForbiddenAppNames {
    return @($ForbiddenAppDefinitions | ForEach-Object { $_.Name })
}

function Resolve-SelectedForbiddenApps {
    param(
        [Parameter(Mandatory)]
        [string[]] $SelectedApps
    )

    if ($SelectedApps -contains "All") {
        return @($ForbiddenAppDefinitions)
    }

    $KnownApps = Get-ForbiddenAppNames
    $UnknownApps = @($SelectedApps | Where-Object { $_ -notin $KnownApps })

    if ($UnknownApps.Count -gt 0) {
        throw "Unknown cleanup app(s): $($UnknownApps -join ', '). Known apps: $($KnownApps -join ', ')."
    }

    return @($ForbiddenAppDefinitions | Where-Object { $SelectedApps -contains $_.Name })
}

function Resolve-CleanupPath {
    param(
        [Parameter(Mandatory)]
        [string] $StudentProfilePath,

        [Parameter(Mandatory)]
        [hashtable] $PathSpec
    )

    switch ($PathSpec.Scope) {
        "StudentProfile" {
            return Join-Path -Path $StudentProfilePath -ChildPath $PathSpec.Path
        }
        "Absolute" {
            return $PathSpec.Path
        }
        default {
            throw "Unknown cleanup path scope: $($PathSpec.Scope)"
        }
    }
}

function Resolve-RemovalTargets {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [switch] $AllowWildcards
    )

    if ($AllowWildcards) {
        return @(Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue)
    }

    if (Test-Path -LiteralPath $Path) {
        return @(Get-Item -LiteralPath $Path -Force -ErrorAction Stop)
    }

    return @()
}

function Remove-PathWithOwnershipRetry {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [switch] $AllowWildcards
    )

    $Targets = Resolve-RemovalTargets -Path $Path -AllowWildcards:$AllowWildcards

    foreach ($Target in $Targets) {
        try {
            Remove-Item -LiteralPath $Target.FullName -Recurse -Force -ErrorAction Stop
            Write-Host "Removed $($Target.FullName)" -ForegroundColor Green
        }
        catch {
            Write-Warning "Initial deletion failed for $($Target.FullName). Taking ownership and retrying."

            $TakeownArgs = @("/F", $Target.FullName)
            $IcaclsArgs = @($Target.FullName, "/grant", "Administrators:F")

            if ($Target.PSIsContainer) {
                $TakeownArgs += @("/R", "/D", "Y")
                $IcaclsArgs += "/T"
            }

            & takeown.exe @TakeownArgs | Out-Null
            & icacls.exe @IcaclsArgs | Out-Null

            Remove-Item -LiteralPath $Target.FullName -Recurse -Force -ErrorAction Stop
            Write-Host "Removed $($Target.FullName)" -ForegroundColor Green
        }
    }
}

function Stop-ForbiddenAppProcesses {
    param(
        [Parameter(Mandatory)]
        [hashtable] $AppDefinition
    )

    foreach ($ProcessPattern in $AppDefinition.ProcessPatterns) {
        Get-Process -Name $ProcessPattern -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ForbiddenAppCleanup {
    param(
        [Parameter(Mandatory)]
        [hashtable] $AppDefinition,

        [Parameter(Mandatory)]
        [string] $StudentProfilePath
    )

    Write-Host ""
    Write-Host "Cleaning $($AppDefinition.Name)..." -ForegroundColor Cyan

    Stop-ForbiddenAppProcesses -AppDefinition $AppDefinition

    foreach ($PathSpec in $AppDefinition.Paths) {
        $ResolvedPath = Resolve-CleanupPath `
            -StudentProfilePath $StudentProfilePath `
            -PathSpec $PathSpec

        Remove-PathWithOwnershipRetry `
            -Path $ResolvedPath `
            -AllowWildcards:$PathSpec.Wildcard
    }
}

try {
    Assert-RunningAsAdmin

    if ($ListApps) {
        Write-Host "Known forbidden apps/games:" -ForegroundColor Cyan
        Get-ForbiddenAppNames | ForEach-Object { Write-Host "- $_" }
        exit 0
    }

    $StudentProfilePath = Get-StudentProfilePath -StudentUser $StudentUser
    $SelectedAppDefinitions = Resolve-SelectedForbiddenApps -SelectedApps $Apps

    foreach ($AppDefinition in $SelectedAppDefinitions) {
        Invoke-ForbiddenAppCleanup `
            -AppDefinition $AppDefinition `
            -StudentProfilePath $StudentProfilePath
    }

    Write-Host ""
    Write-Host "Forbidden app cleanup completed for $StudentUser" -ForegroundColor Cyan
}
catch {
    Write-Host ""
    Write-Host "Forbidden app cleanup failed:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
