param(
    [string] $StudentUser = "Student",
    [switch] $CleanPublicDesktop,
    [switch] $CleanMachineAutostart,
    [switch] $SkipPublicDesktopCleanup,
    [switch] $SkipMachineAutostartCleanup,
    [switch] $SkipWallpaperTask
)

# ============================================================
# Configure clean Student desktop, taskbar, autostart, wallpaper
# Run PowerShell as Administrator from an admin account
# ============================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\StudentAccountTools.ps1"

function Get-NormalizedFullPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    return [IO.Path]::GetFullPath($Path).TrimEnd("\")
}

function ConvertTo-ExpandedStudentPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $StudentProfilePath
    )

    $ExpandedPath = $Path `
        -replace "%USERPROFILE%", $StudentProfilePath `
        -replace "%HOMEDRIVE%%HOMEPATH%", $StudentProfilePath

    $ExpandedPath = [Environment]::ExpandEnvironmentVariables($ExpandedPath)

    if (-not [IO.Path]::IsPathRooted($ExpandedPath)) {
        $ExpandedPath = Join-Path -Path $StudentProfilePath -ChildPath $ExpandedPath
    }

    return [IO.Path]::GetFullPath($ExpandedPath)
}

function Test-PathUnderRoot {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Root
    )

    $NormalizedPath = Get-NormalizedFullPath -Path $Path
    $NormalizedRoot = Get-NormalizedFullPath -Path $Root

    return (
        $NormalizedPath -ieq $NormalizedRoot -or
        $NormalizedPath.StartsWith("$NormalizedRoot\", [StringComparison]::OrdinalIgnoreCase)
    )
}

function Resolve-SafeStudentProfilePath {
    param(
        [Parameter(Mandatory)]
        [string] $StudentUser
    )

    $ResolvedProfilePath = Get-StudentProfilePath -StudentUser $StudentUser
    $CurrentProfilePath = [Environment]::GetFolderPath("UserProfile")
    $FallbackProfilePath = "C:\Users\$StudentUser"

    if (
        $env:USERNAME -ine $StudentUser -and
        $CurrentProfilePath -and
        (Get-NormalizedFullPath -Path $ResolvedProfilePath) -ieq (Get-NormalizedFullPath -Path $CurrentProfilePath)
    ) {
        if (Test-Path -LiteralPath $FallbackProfilePath) {
            Write-Warning "Windows reported $ResolvedProfilePath for $StudentUser, but that is the current admin profile. Using $FallbackProfilePath instead."
            return $FallbackProfilePath
        }

        throw "Windows reported the current admin profile for $StudentUser. Log in once as $StudentUser so C:\Users\$StudentUser exists, then run this script again."
    }

    return $ResolvedProfilePath
}

function Add-UniquePath {
    param(
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Paths,

        [string] $Path
    )

    if ($null -eq $Paths) {
        throw "Path list was not initialized."
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $AlreadyAdded = @($Paths | Where-Object { $_ -ieq $Path }).Count -gt 0

    if (-not $AlreadyAdded) {
        [void] $Paths.Add($Path)
    }
}

function Get-StudentDesktopPaths {
    param(
        [Parameter(Mandatory)]
        [string] $StudentProfilePath,

        [string] $HiveRoot,

        [string] $CurrentProfilePath
    )

    $Paths = New-Object System.Collections.Generic.List[string]

    if ($HiveRoot) {
        $ExplorerPath = Join-Path `
            -Path $HiveRoot `
            -ChildPath "Software\Microsoft\Windows\CurrentVersion\Explorer"

        foreach ($FolderKeyName in @("User Shell Folders", "Shell Folders")) {
            $FolderKeyPath = Join-Path -Path $ExplorerPath -ChildPath $FolderKeyName

            if (Test-Path -Path $FolderKeyPath) {
                $FolderKey = Get-ItemProperty -Path $FolderKeyPath -ErrorAction SilentlyContinue
                $DesktopPath = $FolderKey.Desktop

                if ($DesktopPath) {
                    $ExpandedDesktopPath = ConvertTo-ExpandedStudentPath `
                        -Path $DesktopPath `
                        -StudentProfilePath $StudentProfilePath

                    if (
                        $CurrentProfilePath -and
                        -not (Test-PathUnderRoot -Path $StudentProfilePath -Root $CurrentProfilePath) -and
                        (Test-PathUnderRoot -Path $ExpandedDesktopPath -Root $CurrentProfilePath)
                    ) {
                        Write-Warning "Ignored desktop path because it points to current admin profile: $ExpandedDesktopPath"
                        continue
                    }

                    Add-UniquePath -Paths $Paths -Path $ExpandedDesktopPath
                }
            }
        }
    }

    Add-UniquePath -Paths $Paths -Path (Join-Path -Path $StudentProfilePath -ChildPath "Desktop")

    $OneDriveRoots = @()
    $DefaultOneDrivePath = Join-Path -Path $StudentProfilePath -ChildPath "OneDrive"

    if (Test-Path -LiteralPath $DefaultOneDrivePath) {
        $OneDriveRoots += $DefaultOneDrivePath
    }

    if (Test-Path -LiteralPath $StudentProfilePath) {
        $OneDriveRoots += @(Get-ChildItem `
            -LiteralPath $StudentProfilePath `
            -Directory `
            -Filter "OneDrive*" `
            -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }

    foreach ($OneDriveRoot in $OneDriveRoots) {
        Add-UniquePath `
            -Paths $Paths `
            -Path (Join-Path -Path $OneDriveRoot -ChildPath "Desktop")
    }

    return @($Paths.ToArray())
}

function Clear-DirectoryContents {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Description
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Host "Created $Description directory: $Path" -ForegroundColor Green
        return
    }

    $Items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)

    foreach ($Item in $Items) {
        try {
            Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop
            Write-Host "Removed $Description item: $($Item.FullName)" -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not remove $Description item $($Item.FullName). $($_.Exception.Message)"
        }
    }
}

function Clear-RegistryValueNames {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Description
    )

    try {
        if (-not (Test-Path -Path $Path)) {
            return
        }

        $ValueNames = @((Get-Item -Path $Path -ErrorAction Stop).GetValueNames() |
            Where-Object { -not [string]::IsNullOrEmpty($_) })
    }
    catch {
        Write-Warning "Could not inspect $Description autostart registry path $Path. $($_.Exception.Message)"
        return
    }

    foreach ($ValueName in $ValueNames) {
        try {
            Remove-ItemProperty -Path $Path -Name $ValueName -ErrorAction Stop
            Write-Host "Removed $Description autostart value: $ValueName" -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not remove $Description autostart value $ValueName. $($_.Exception.Message)"
        }
    }
}

function Set-OptionalRegistryDWord {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [int] $Value,

        [Parameter(Mandatory)]
        [string] $Description
    )

    try {
        Set-RegistryDWord -Path $Path -Name $Name -Value $Value
    }
    catch {
        Write-Warning "Could not set $Description registry value $Name at $Path. $($_.Exception.Message)"
    }
}

function Set-StudentTaskbarAndDesktopRegistry {
    param(
        [Parameter(Mandatory)]
        [string] $HiveRoot
    )

    $ExplorerAdvancedPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    $FeedsPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Microsoft\Windows\CurrentVersion\Feeds"
    $SearchPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Microsoft\Windows\CurrentVersion\Search"
    $SearchSettingsPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Microsoft\Windows\CurrentVersion\SearchSettings"
    $ExplorerPolicyPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $WindowsSearchPolicyPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Policies\Microsoft\Windows\Windows Search"
    $WindowsExplorerPolicyPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Policies\Microsoft\Windows\Explorer"
    $FeedsPolicyPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Policies\Microsoft\Windows\Windows Feeds"
    $DshPolicyPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Policies\Microsoft\Dsh"
    $CopilotPolicyPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Policies\Microsoft\Windows\WindowsCopilot"
    $HideDesktopIconsPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
    $ClassicHideDesktopIconsPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu"
    $TaskbandPath = Join-Path `
        -Path $HiveRoot `
        -ChildPath "Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"

    # Windows 10 News and interests / Windows 11 Widgets.
    Set-OptionalRegistryDWord `
        -Path $FeedsPath `
        -Name "ShellFeedsTaskbarViewMode" `
        -Value 2 `
        -Description "Student taskbar widget"
    Set-OptionalRegistryDWord `
        -Path $FeedsPolicyPath `
        -Name "EnableFeeds" `
        -Value 0 `
        -Description "Student taskbar widget policy"
    Set-OptionalRegistryDWord `
        -Path $DshPolicyPath `
        -Name "AllowNewsAndInterests" `
        -Value 0 `
        -Description "Student taskbar widget policy"
    Set-OptionalRegistryDWord `
        -Path $ExplorerAdvancedPath `
        -Name "TaskbarDa" `
        -Value 0 `
        -Description "Student taskbar widget"

    # Keep Windows search visible for the Student account.
    Set-OptionalRegistryDWord `
        -Path $SearchPath `
        -Name "SearchboxTaskbarMode" `
        -Value 2 `
        -Description "Student taskbar search"
    Set-OptionalRegistryDWord `
        -Path $SearchSettingsPath `
        -Name "IsDynamicSearchBoxEnabled" `
        -Value 0 `
        -Description "Student search highlights"
    Set-OptionalRegistryDWord `
        -Path $SearchPath `
        -Name "BingSearchEnabled" `
        -Value 0 `
        -Description "Student web search"
    Set-OptionalRegistryDWord `
        -Path $SearchPath `
        -Name "CortanaConsent" `
        -Value 0 `
        -Description "Student web search"
    Set-OptionalRegistryDWord `
        -Path $WindowsSearchPolicyPath `
        -Name "DisableWebSearch" `
        -Value 1 `
        -Description "Student web search policy"
    Set-OptionalRegistryDWord `
        -Path $WindowsSearchPolicyPath `
        -Name "ConnectedSearchUseWeb" `
        -Value 0 `
        -Description "Student web search policy"
    Set-OptionalRegistryDWord `
        -Path $WindowsSearchPolicyPath `
        -Name "ConnectedSearchUseWebOverMeteredConnections" `
        -Value 0 `
        -Description "Student web search policy"
    Set-OptionalRegistryDWord `
        -Path $WindowsSearchPolicyPath `
        -Name "AllowSearchToUseLocation" `
        -Value 0 `
        -Description "Student web search policy"
    Set-OptionalRegistryDWord `
        -Path $WindowsExplorerPolicyPath `
        -Name "DisableSearchBoxSuggestions" `
        -Value 1 `
        -Description "Student search suggestions policy"

    # Remove optional taskbar buttons so only search, system tray, and running apps remain.
    Set-OptionalRegistryDWord `
        -Path $ExplorerAdvancedPath `
        -Name "ShowTaskViewButton" `
        -Value 0 `
        -Description "Student taskbar button"
    Set-OptionalRegistryDWord `
        -Path $ExplorerAdvancedPath `
        -Name "ShowCortanaButton" `
        -Value 0 `
        -Description "Student taskbar button"
    Set-OptionalRegistryDWord `
        -Path $ExplorerAdvancedPath `
        -Name "PeopleBand" `
        -Value 0 `
        -Description "Student taskbar button"
    Set-OptionalRegistryDWord `
        -Path $ExplorerAdvancedPath `
        -Name "TaskbarMn" `
        -Value 0 `
        -Description "Student taskbar button"
    Set-OptionalRegistryDWord `
        -Path $ExplorerAdvancedPath `
        -Name "ShowCopilotButton" `
        -Value 0 `
        -Description "Student taskbar button"
    Set-OptionalRegistryDWord `
        -Path $ExplorerPolicyPath `
        -Name "HideSCAMeetNow" `
        -Value 1 `
        -Description "Student taskbar policy"
    Set-OptionalRegistryDWord `
        -Path $CopilotPolicyPath `
        -Name "TurnOffWindowsCopilot" `
        -Value 1 `
        -Description "Student Copilot policy"

    # Remove and block pinned taskbar app shortcuts for this student.
    Set-OptionalRegistryDWord `
        -Path $ExplorerPolicyPath `
        -Name "TaskbarNoPinnedList" `
        -Value 1 `
        -Description "Student taskbar pin policy"
    Set-OptionalRegistryDWord `
        -Path $ExplorerPolicyPath `
        -Name "NoPinningToTaskbar" `
        -Value 1 `
        -Description "Student taskbar pin policy"

    try {
        $TaskbandExists = Test-Path -Path $TaskbandPath
    }
    catch {
        Write-Warning "Could not inspect stored taskbar pin registry data. $($_.Exception.Message)"
        $TaskbandExists = $false
    }

    if ($TaskbandExists) {
        try {
            Remove-Item -Path $TaskbandPath -Recurse -Force -ErrorAction Stop
            Write-Host "Removed stored taskbar pin registry data" -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not remove stored taskbar pin registry data. $($_.Exception.Message)"
        }
    }

    # Keep desktop icons visible and ensure Recycle Bin / This PC are shown.
    Set-OptionalRegistryDWord `
        -Path $ExplorerAdvancedPath `
        -Name "HideIcons" `
        -Value 0 `
        -Description "Student desktop icon"
    Set-OptionalRegistryDWord `
        -Path $HideDesktopIconsPath `
        -Name "{645FF040-5081-101B-9F08-00AA002F954E}" `
        -Value 0 `
        -Description "Student Recycle Bin desktop icon"
    Set-OptionalRegistryDWord `
        -Path $ClassicHideDesktopIconsPath `
        -Name "{645FF040-5081-101B-9F08-00AA002F954E}" `
        -Value 0 `
        -Description "Student Recycle Bin desktop icon"
    Set-OptionalRegistryDWord `
        -Path $HideDesktopIconsPath `
        -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" `
        -Value 0 `
        -Description "Student This PC desktop icon"
    Set-OptionalRegistryDWord `
        -Path $ClassicHideDesktopIconsPath `
        -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" `
        -Value 0 `
        -Description "Student This PC desktop icon"

    Write-Host "Configured Student taskbar, widget, and desktop icon registry settings" -ForegroundColor Green
}

function Set-MachineTaskbarPolicies {
    $FeedsPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds"
    $DshPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
    $CopilotPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"

    Set-RegistryDWord -Path $FeedsPolicyPath -Name "EnableFeeds" -Value 0
    Set-RegistryDWord -Path $DshPolicyPath -Name "AllowNewsAndInterests" -Value 0
    Set-RegistryDWord -Path $CopilotPolicyPath -Name "TurnOffWindowsCopilot" -Value 1

    Write-Host "Configured machine taskbar widget policies" -ForegroundColor Green
}

function Clear-StudentAutostartRegistry {
    param(
        [Parameter(Mandatory)]
        [string] $HiveRoot
    )

    $AutostartPaths = @(
        "Software\Microsoft\Windows\CurrentVersion\Run",
        "Software\Microsoft\Windows\CurrentVersion\RunOnce",
        "Software\Microsoft\Windows\CurrentVersion\RunServices",
        "Software\Microsoft\Windows\CurrentVersion\RunServicesOnce",
        "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
        "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
    )

    foreach ($AutostartPath in $AutostartPaths) {
        Clear-RegistryValueNames `
            -Path (Join-Path -Path $HiveRoot -ChildPath $AutostartPath) `
            -Description "Student"
    }
}

function Clear-MachineAutostartRegistry {
    $AutostartPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunServices",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunServicesOnce",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
    )

    foreach ($AutostartPath in $AutostartPaths) {
        Clear-RegistryValueNames -Path $AutostartPath -Description "machine"
    }
}

function Test-StudentUserIdMatch {
    param(
        [string] $UserId,

        [Parameter(Mandatory)]
        [string] $StudentUser,

        [Parameter(Mandatory)]
        [string] $StudentSid
    )

    if ([string]::IsNullOrWhiteSpace($UserId)) {
        return $false
    }

    $NormalizedUserId = $UserId.Trim()

    return (
        $NormalizedUserId -ieq $StudentSid -or
        $NormalizedUserId -ieq $StudentUser -or
        $NormalizedUserId -ieq ".\$StudentUser" -or
        $NormalizedUserId -ieq "$env:COMPUTERNAME\$StudentUser" -or
        $NormalizedUserId -match "\\$([regex]::Escape($StudentUser))$"
    )
}

function Disable-StudentScheduledLogonTasks {
    param(
        [Parameter(Mandatory)]
        [string] $StudentUser,

        [Parameter(Mandatory)]
        [string] $StudentSid
    )

    $ScheduledTaskCommand = Get-Command -Name "Get-ScheduledTask" -ErrorAction SilentlyContinue

    if (-not $ScheduledTaskCommand) {
        Write-Host "ScheduledTasks module not available; skipping scheduled logon task cleanup." -ForegroundColor Yellow
        return
    }

    $Tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)

    foreach ($Task in $Tasks) {
        $LogonTriggers = @($Task.Triggers | Where-Object {
            $_.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger"
        })

        if ($LogonTriggers.Count -eq 0) {
            continue
        }

        $TaskMatchesStudent = Test-StudentUserIdMatch `
            -UserId $Task.Principal.UserId `
            -StudentUser $StudentUser `
            -StudentSid $StudentSid

        foreach ($Trigger in $LogonTriggers) {
            if (Test-StudentUserIdMatch `
                    -UserId $Trigger.UserId `
                    -StudentUser $StudentUser `
                    -StudentSid $StudentSid) {
                $TaskMatchesStudent = $true
            }
        }

        if (-not $TaskMatchesStudent) {
            continue
        }

        try {
            Disable-ScheduledTask -InputObject $Task -ErrorAction Stop | Out-Null
            Write-Host "Disabled Student logon scheduled task: $($Task.TaskPath)$($Task.TaskName)" -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not disable scheduled task $($Task.TaskPath)$($Task.TaskName). $($_.Exception.Message)"
        }
    }
}

function Get-ExistingCandidateFile {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $ExpandedPath = [Environment]::ExpandEnvironmentVariables($Path)

    if ($ExpandedPath -match "[\*\?]") {
        $Matches = @(Get-Item -Path $ExpandedPath -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            Sort-Object -Property FullName -Descending)

        if ($Matches.Count -gt 0) {
            return $Matches[0].FullName
        }

        return $null
    }

    if (Test-Path -LiteralPath $ExpandedPath -PathType Leaf) {
        return $ExpandedPath
    }

    return $null
}

function Get-AppPathExecutable {
    param(
        [Parameter(Mandatory)]
        [string] $ExeName
    )

    $RegistryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExeName",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$ExeName"
    )

    foreach ($RegistryPath in $RegistryPaths) {
        if (-not (Test-Path -Path $RegistryPath)) {
            continue
        }

        $ExecutablePath = (Get-Item -Path $RegistryPath -ErrorAction SilentlyContinue).GetValue("")

        if ($ExecutablePath -and (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
            return $ExecutablePath
        }
    }

    return $null
}

function Find-StartMenuShortcut {
    param(
        [Parameter(Mandatory)]
        [string[]] $Patterns,

        [Parameter(Mandatory)]
        [string] $StudentProfilePath
    )

    $StartMenuRoots = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        (Join-Path -Path $StudentProfilePath -ChildPath "AppData\Roaming\Microsoft\Windows\Start Menu\Programs")
    )

    foreach ($StartMenuRoot in $StartMenuRoots) {
        if (-not (Test-Path -LiteralPath $StartMenuRoot)) {
            continue
        }

        foreach ($Pattern in $Patterns) {
            $Shortcut = @(Get-ChildItem `
                -LiteralPath $StartMenuRoot `
                -Recurse `
                -File `
                -Filter $Pattern `
                -ErrorAction SilentlyContinue |
                Sort-Object -Property FullName |
                Select-Object -First 1)

            if ($Shortcut.Count -gt 0) {
                return $Shortcut[0].FullName
            }
        }
    }

    return $null
}

function Resolve-AppLauncher {
    param(
        [Parameter(Mandatory)]
        [hashtable] $AppDefinition,

        [Parameter(Mandatory)]
        [string] $StudentProfilePath
    )

    $StartMenuShortcut = Find-StartMenuShortcut `
        -Patterns $AppDefinition.StartMenuPatterns `
        -StudentProfilePath $StudentProfilePath

    if ($StartMenuShortcut) {
        return @{
            Kind = "Shortcut"
            Path = $StartMenuShortcut
        }
    }

    foreach ($ExeName in $AppDefinition.AppPathNames) {
        $ExecutablePath = Get-AppPathExecutable -ExeName $ExeName

        if ($ExecutablePath) {
            return @{
                Kind = "Executable"
                Path = $ExecutablePath
            }
        }
    }

    foreach ($CandidatePath in $AppDefinition.CandidatePaths) {
        $ExecutablePath = Get-ExistingCandidateFile -Path $CandidatePath

        if ($ExecutablePath) {
            return @{
                Kind = "Executable"
                Path = $ExecutablePath
            }
        }
    }

    return $null
}

function New-DesktopShortcut {
    param(
        [Parameter(Mandatory)]
        [string] $ShortcutPath,

        [Parameter(Mandatory)]
        [string] $TargetPath,

        [string] $Arguments,

        [string] $WorkingDirectory,

        [string] $IconLocation
    )

    $Shell = New-Object -ComObject WScript.Shell
    $Shortcut = $Shell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = $TargetPath

    if ($Arguments) {
        $Shortcut.Arguments = $Arguments
    }

    if ($WorkingDirectory) {
        $Shortcut.WorkingDirectory = $WorkingDirectory
    } else {
        $Shortcut.WorkingDirectory = Split-Path -Path $TargetPath -Parent
    }

    if ($IconLocation) {
        $Shortcut.IconLocation = $IconLocation
    } else {
        $Shortcut.IconLocation = $TargetPath
    }

    $Shortcut.Save()
}

function Get-DesktopAppDefinitions {
    param(
        [Parameter(Mandatory)]
        [string] $StudentProfilePath
    )

    return @(
        # Student desktop "PS" means Adobe Photoshop.
        @{
            ShortcutName = "PS"
            StartMenuPatterns = @("Adobe Photoshop*.lnk", "Photoshop*.lnk")
            AppPathNames = @("Photoshop.exe")
            CandidatePaths = @(
                "$env:ProgramFiles\Adobe\Adobe Photoshop *\Photoshop.exe",
                "${env:ProgramFiles(x86)}\Adobe\Adobe Photoshop *\Photoshop.exe"
            )
        },
        @{
            ShortcutName = "Google Chrome"
            StartMenuPatterns = @("Google Chrome.lnk", "Chrome.lnk")
            AppPathNames = @("chrome.exe")
            CandidatePaths = @(
                "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                "$StudentProfilePath\AppData\Local\Google\Chrome\Application\chrome.exe"
            )
        },
        @{
            ShortcutName = "Word"
            StartMenuPatterns = @("Word.lnk", "Microsoft Word*.lnk")
            AppPathNames = @("WINWORD.EXE")
            CandidatePaths = @(
                "$env:ProgramFiles\Microsoft Office\root\Office16\WINWORD.EXE",
                "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\WINWORD.EXE"
            )
        },
        @{
            ShortcutName = "Excel"
            StartMenuPatterns = @("Excel.lnk", "Microsoft Excel*.lnk")
            AppPathNames = @("EXCEL.EXE")
            CandidatePaths = @(
                "$env:ProgramFiles\Microsoft Office\root\Office16\EXCEL.EXE",
                "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\EXCEL.EXE"
            )
        },
        @{
            ShortcutName = "Access"
            StartMenuPatterns = @("Access.lnk", "Microsoft Access*.lnk")
            AppPathNames = @("MSACCESS.EXE")
            CandidatePaths = @(
                "$env:ProgramFiles\Microsoft Office\root\Office16\MSACCESS.EXE",
                "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\MSACCESS.EXE"
            )
        },
        @{
            ShortcutName = "PowerPoint"
            StartMenuPatterns = @("PowerPoint.lnk", "Microsoft PowerPoint*.lnk")
            AppPathNames = @("POWERPNT.EXE")
            CandidatePaths = @(
                "$env:ProgramFiles\Microsoft Office\root\Office16\POWERPNT.EXE",
                "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\POWERPNT.EXE"
            )
        },
        @{
            ShortcutName = "Thonny"
            StartMenuPatterns = @("Thonny.lnk", "Thonny*.lnk")
            AppPathNames = @("thonny.exe")
            CandidatePaths = @(
                "$env:ProgramFiles\Thonny\thonny.exe",
                "${env:ProgramFiles(x86)}\Thonny\thonny.exe",
                "$StudentProfilePath\AppData\Local\Programs\Thonny\thonny.exe"
            )
        },
        @{
            ShortcutName = "Scratch"
            StartMenuPatterns = @("Scratch.lnk", "Scratch 3.lnk", "Scratch Desktop.lnk", "Scratch*.lnk")
            AppPathNames = @("Scratch 3.exe", "Scratch.exe", "Scratch Desktop.exe")
            CandidatePaths = @(
                "$env:ProgramFiles\Scratch 3\Scratch 3.exe",
                "${env:ProgramFiles(x86)}\Scratch 3\Scratch 3.exe",
                "$env:ProgramFiles\Scratch Desktop\Scratch Desktop.exe",
                "${env:ProgramFiles(x86)}\Scratch Desktop\Scratch Desktop.exe",
                "$StudentProfilePath\AppData\Local\Programs\Scratch Desktop\Scratch Desktop.exe"
            )
        }
    )
}

function Install-DesktopAppShortcuts {
    param(
        [Parameter(Mandatory)]
        [string] $DesktopPath,

        [Parameter(Mandatory)]
        [string] $StudentProfilePath
    )

    try {
        New-Item -ItemType Directory -Path $DesktopPath -Force -ErrorAction Stop | Out-Null
    }
    catch {
        throw "Could not create Student desktop directory $DesktopPath. $($_.Exception.Message)"
    }

    foreach ($AppDefinition in (Get-DesktopAppDefinitions -StudentProfilePath $StudentProfilePath)) {
        try {
            $ShortcutPath = Join-Path `
                -Path $DesktopPath `
                -ChildPath "$($AppDefinition.ShortcutName).lnk"
            $Launcher = Resolve-AppLauncher `
                -AppDefinition $AppDefinition `
                -StudentProfilePath $StudentProfilePath

            if (-not $Launcher) {
                Write-Host "Skipped $($AppDefinition.ShortcutName): app not found" -ForegroundColor Yellow
                continue
            }

            if (Test-Path -LiteralPath $ShortcutPath) {
                Remove-Item -LiteralPath $ShortcutPath -Force -ErrorAction Stop
            }

            if ($Launcher.Kind -eq "Shortcut") {
                Copy-Item `
                    -LiteralPath $Launcher.Path `
                    -Destination $ShortcutPath `
                    -Force `
                    -ErrorAction Stop
            } else {
                New-DesktopShortcut -ShortcutPath $ShortcutPath -TargetPath $Launcher.Path
            }

            Write-Host "Created desktop shortcut: $ShortcutPath" -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not create shortcut for $($AppDefinition.ShortcutName). $($_.Exception.Message)"
        }
    }
}

function Clear-TaskbarPinnedShortcutFolder {
    param(
        [Parameter(Mandatory)]
        [string] $StudentProfilePath
    )

    $TaskbarPinnedPath = Join-Path `
        -Path $StudentProfilePath `
        -ChildPath "AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"

    Clear-DirectoryContents -Path $TaskbarPinnedPath -Description "taskbar pinned shortcut"
}

function Clear-StartupFolders {
    param(
        [Parameter(Mandatory)]
        [string] $StudentProfilePath
    )

    $StudentStartupPath = Join-Path `
        -Path $StudentProfilePath `
        -ChildPath "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"

    Clear-DirectoryContents -Path $StudentStartupPath -Description "Student startup"
    Write-Host "Skipping common startup cleanup because it affects all users." -ForegroundColor Yellow
}

function Install-RandomDefaultWallpaperTask {
    param(
        [Parameter(Mandatory)]
        [string] $StudentUser
    )

    $InstallDirectory = Join-Path -Path $env:ProgramData -ChildPath "SchoolStudentSetup"
    $WallpaperScriptPath = Join-Path -Path $InstallDirectory -ChildPath "Set-RandomDefaultWallpaper.ps1"
    $TaskName = "SchoolStudentRandomDefaultWallpaper"
    $StudentAccountName = "$env:COMPUTERNAME\$StudentUser"

    New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null

    $WallpaperScript = @'
$ErrorActionPreference = "SilentlyContinue"

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

$ExplorerAdvancedPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
$FeedsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds"
$SearchPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
$SearchSettingsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"
$WindowsSearchPolicyPath = "HKCU:\Software\Policies\Microsoft\Windows\Windows Search"
$WindowsExplorerPolicyPath = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"
$HideDesktopIconsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
$ClassicHideDesktopIconsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu"

Set-RegistryDWord -Path $FeedsPath -Name "ShellFeedsTaskbarViewMode" -Value 2
Set-RegistryDWord -Path $ExplorerAdvancedPath -Name "TaskbarDa" -Value 0
Set-RegistryDWord -Path $SearchPath -Name "SearchboxTaskbarMode" -Value 2
Set-RegistryDWord -Path $SearchSettingsPath -Name "IsDynamicSearchBoxEnabled" -Value 0
Set-RegistryDWord -Path $SearchPath -Name "BingSearchEnabled" -Value 0
Set-RegistryDWord -Path $SearchPath -Name "CortanaConsent" -Value 0
Set-RegistryDWord -Path $WindowsSearchPolicyPath -Name "DisableWebSearch" -Value 1
Set-RegistryDWord -Path $WindowsSearchPolicyPath -Name "ConnectedSearchUseWeb" -Value 0
Set-RegistryDWord -Path $WindowsSearchPolicyPath -Name "ConnectedSearchUseWebOverMeteredConnections" -Value 0
Set-RegistryDWord -Path $WindowsSearchPolicyPath -Name "AllowSearchToUseLocation" -Value 0
Set-RegistryDWord -Path $WindowsExplorerPolicyPath -Name "DisableSearchBoxSuggestions" -Value 1
Set-RegistryDWord -Path $ExplorerAdvancedPath -Name "HideIcons" -Value 0
Set-RegistryDWord `
    -Path $HideDesktopIconsPath `
    -Name "{645FF040-5081-101B-9F08-00AA002F954E}" `
    -Value 0
Set-RegistryDWord `
    -Path $ClassicHideDesktopIconsPath `
    -Name "{645FF040-5081-101B-9F08-00AA002F954E}" `
    -Value 0
Set-RegistryDWord `
    -Path $HideDesktopIconsPath `
    -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" `
    -Value 0
Set-RegistryDWord `
    -Path $ClassicHideDesktopIconsPath `
    -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" `
    -Value 0

$WallpaperRoots = @(
    (Join-Path -Path $env:WINDIR -ChildPath "Web\Wallpaper"),
    (Join-Path -Path $env:WINDIR -ChildPath "Web\4K\Wallpaper"),
    (Join-Path -Path $env:WINDIR -ChildPath "Web\Screen")
)

$Wallpapers = @()

foreach ($WallpaperRoot in $WallpaperRoots) {
    if (-not (Test-Path -LiteralPath $WallpaperRoot)) {
        continue
    }

    $Wallpapers += @(Get-ChildItem -LiteralPath $WallpaperRoot -Recurse -File |
        Where-Object { $_.Extension -match "^\.(jpg|jpeg|png|bmp)$" })
}

if ($Wallpapers.Count -eq 0) {
    exit 0
}

$SelectedWallpaper = Get-Random -InputObject $Wallpapers

Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "Wallpaper" -Value $SelectedWallpaper.FullName
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallpaperStyle" -Value "10"
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "TileWallpaper" -Value "0"

Add-Type @"
using System.Runtime.InteropServices;

public static class WallpaperApi
{
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@

[WallpaperApi]::SystemParametersInfo(20, 0, $SelectedWallpaper.FullName, 3) | Out-Null
'@

    Set-Content -Path $WallpaperScriptPath -Value $WallpaperScript -Encoding ASCII -Force

    $Action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WallpaperScriptPath`""
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $StudentAccountName
    $Principal = New-ScheduledTaskPrincipal `
        -UserId $StudentAccountName `
        -LogonType Interactive `
        -RunLevel Limited

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Principal $Principal `
        -Description "Set a random default Windows wallpaper when the Student user logs in." `
        -Force | Out-Null

    Write-Host "Installed random default wallpaper logon task: $TaskName" -ForegroundColor Green
}

try {
    Assert-RunningAsAdmin

    $Student = Get-LocalUser -Name $StudentUser -ErrorAction Stop
    $StudentSid = $Student.SID.Value
    $CurrentProfilePath = [Environment]::GetFolderPath("UserProfile")
    $RegistryStudentProfilePath = Get-StudentProfilePath -StudentUser $StudentUser
    $StudentProfilePath = Resolve-SafeStudentProfilePath -StudentUser $StudentUser
    $CanUseStudentHive = (
        (Get-NormalizedFullPath -Path $RegistryStudentProfilePath) -ieq
        (Get-NormalizedFullPath -Path $StudentProfilePath)
    )
    $script:StudentDesktopPaths = @()

    Write-Host "Using Student profile path: $StudentProfilePath" -ForegroundColor Cyan

    Set-MachineTaskbarPolicies

    if ($CanUseStudentHive) {
        try {
            $HiveApplied = Invoke-WithStudentUserHive -StudentUser $StudentUser -Action {
                param(
                    [string] $HiveRoot
                )

                try {
                    Set-StudentTaskbarAndDesktopRegistry -HiveRoot $HiveRoot
                }
                catch {
                    Write-Warning "Could not finish Student taskbar registry cleanup. $($_.Exception.Message)"
                }

                try {
                    Clear-StudentAutostartRegistry -HiveRoot $HiveRoot
                }
                catch {
                    Write-Warning "Could not finish Student autostart registry cleanup. $($_.Exception.Message)"
                }

                $script:StudentDesktopPaths = Get-StudentDesktopPaths `
                    -StudentProfilePath $StudentProfilePath `
                    -HiveRoot $HiveRoot `
                    -CurrentProfilePath $CurrentProfilePath
            }
        }
        catch {
            Write-Warning "Could not load or edit the Student registry hive. Continuing with file-based desktop cleanup. $($_.Exception.Message)"
            $HiveApplied = $false
        }
    }
    else {
        Write-Warning "Skipping offline Student registry hive edits because Windows reported profile path $RegistryStudentProfilePath, but this run will use $StudentProfilePath."
        $HiveApplied = $false
    }

    if (-not $HiveApplied) {
        if (-not (Test-Path -LiteralPath $StudentProfilePath)) {
            throw "Student profile is not ready yet. Log in once as $StudentUser, log out, then run this script again."
        }

        $script:StudentDesktopPaths = Get-StudentDesktopPaths `
            -StudentProfilePath $StudentProfilePath `
            -CurrentProfilePath $CurrentProfilePath
    }

    if ($script:StudentDesktopPaths.Count -eq 0) {
        throw "Could not resolve a desktop path for $StudentUser."
    }

    foreach ($DesktopPath in $script:StudentDesktopPaths) {
        Clear-DirectoryContents -Path $DesktopPath -Description "Student desktop"
    }

    if ($CleanPublicDesktop -and -not $SkipPublicDesktopCleanup) {
        $PublicDesktopPath = Join-Path -Path $env:PUBLIC -ChildPath "Desktop"
        Clear-DirectoryContents -Path $PublicDesktopPath -Description "public desktop"
    } else {
        Write-Host "Skipping public desktop cleanup because it affects all users." -ForegroundColor Yellow
    }

    Install-DesktopAppShortcuts `
        -DesktopPath $script:StudentDesktopPaths[0] `
        -StudentProfilePath $StudentProfilePath

    Clear-TaskbarPinnedShortcutFolder -StudentProfilePath $StudentProfilePath
    Clear-StartupFolders -StudentProfilePath $StudentProfilePath
    Disable-StudentScheduledLogonTasks -StudentUser $StudentUser -StudentSid $StudentSid

    if ($CleanMachineAutostart -and -not $SkipMachineAutostartCleanup) {
        Clear-MachineAutostartRegistry
    } else {
        Write-Host "Skipping machine autostart registry cleanup because it affects all users." -ForegroundColor Yellow
    }

    if ($SkipWallpaperTask) {
        Write-Host "Skipping random default wallpaper task." -ForegroundColor Yellow
    } else {
        Install-RandomDefaultWallpaperTask -StudentUser $StudentUser
    }

    Write-Host ""
    Write-Host "Student desktop setup completed for $StudentUser" -ForegroundColor Cyan
    Write-Host "Restart Windows or log out and back in as $StudentUser to refresh the taskbar and wallpaper." -ForegroundColor Cyan
}
catch {
    Write-Host ""
    Write-Host "Student desktop setup failed:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
