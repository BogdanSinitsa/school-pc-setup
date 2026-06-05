# School PC Student Setup

Scripts for preparing a Windows school/public computer with a restricted local
`Student` account, a clean desktop, controlled startup behavior, and optional
cleanup of unwanted apps.

The `.cmd` files are the easiest way to run the setup. They request
administrator permission automatically and then run the matching PowerShell
script with `ExecutionPolicy Bypass`.

## What It Does

- Creates or updates a local `Student` user.
- Makes sure `Student` is a standard user, not an administrator.
- Blocks Windows Installer MSI installs and per-user MSI installs.
- Blocks the Microsoft Store app.
- Blocks Control Panel, Settings, and Registry Editor for the Student profile.
- Keeps Command Prompt available for IT lessons.
- Enables automatic Windows login for the Student account.
- Cleans the Student desktop, public desktop, startup folders, taskbar pins, and
  common autostart registry entries.
- Creates Student desktop shortcuts for installed school apps:
  - Adobe Photoshop, shown as `PS`
  - Google Chrome
  - Word
  - Excel
  - Access
  - PowerPoint
  - Thonny
  - Scratch
- Hides common taskbar buttons such as Search, Task View, Widgets, Meet Now, and
  Copilot.
- Installs a Student logon task that selects a random default Windows wallpaper.
- Removes known forbidden per-user apps. Currently this targets Roblox.
- Optionally disables automatic Windows, driver, and Microsoft Store update
  behavior.

## Requirements

- Windows 10 or Windows 11.
- A local administrator account.
- PowerShell 5+.
- Run from an extracted/local folder, not directly from inside a ZIP file.

## Quick Start

Run these from an administrator account.

1. Double-click `Run-StudentSetup-AsAdmin.cmd`.
2. Restart the computer.
3. Confirm Windows automatically logs in as `Student`.
4. Log out from `Student`.
5. Log back in as an administrator.
6. Double-click `Run-StudentDesktopSetup-AsAdmin.cmd`.
7. Optional: double-click `Run-StudentCleanup-AsAdmin.cmd`.
8. Optional: double-click `Run-DisableWindowsUpdates-AsAdmin.cmd`.
9. Restart the computer again.

If the first setup run says the Student profile does not exist yet, let the
computer log in once as `Student`, log out, then run
`Run-StudentSetup-AsAdmin.cmd` again from the administrator account.

## Main Commands

### Student Account Setup

Use:

```bat
Run-StudentSetup-AsAdmin.cmd
```

This runs:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Student.ps1
```

Default account:

- Username: `Student`
- Password: `Student123!`

To use a different account or password, run PowerShell as Administrator:

```powershell
.\Setup-Student.ps1 -StudentUser "Student" -StudentPassword "ChangeMe123!"
```

### Student Desktop Setup

Use:

```bat
Run-StudentDesktopSetup-AsAdmin.cmd
```

This cleans the Student desktop and startup locations, removes taskbar pins,
sets taskbar restrictions, creates shortcuts for installed school apps, and
installs the random wallpaper logon task.

Optional switches:

```powershell
.\Configure-StudentDesktop.ps1 -SkipPublicDesktopCleanup
.\Configure-StudentDesktop.ps1 -SkipMachineAutostartCleanup
.\Configure-StudentDesktop.ps1 -SkipWallpaperTask
```

### Forbidden App Cleanup

Use:

```bat
Run-StudentCleanup-AsAdmin.cmd
```

This removes known forbidden apps from the Student profile. Currently the known
target is `Roblox`.

List known cleanup targets:

```powershell
.\Cleanup-ForbiddenApps.ps1 -ListApps
```

Clean selected targets:

```powershell
.\Cleanup-ForbiddenApps.ps1 -Apps Roblox
```

### Disable Student Auto-Login

Use:

```bat
Disable-StudentAutoLogin-AsAdmin.cmd
```

This disables automatic login and removes the stored Student auto-login
credentials when the configured auto-login user is `Student`.

Equivalent PowerShell command:

```powershell
.\Setup-Student.ps1 -DisableAutoLogin
```

### Disable Automatic Windows Updates

Use only if this is required for the school PC environment:

```bat
Run-DisableWindowsUpdates-AsAdmin.cmd
```

This applies local policies, disables update-related services, disables
update-related scheduled tasks, and refreshes computer policy.

Optional switches:

```powershell
.\Disable-WindowsUpdates.ps1 -SkipServiceChanges
.\Disable-WindowsUpdates.ps1 -SkipScheduledTaskChanges
```

## Important Notes

Auto-login stores the Student password in the Windows registry. Use auto-login
only for a restricted standard Student account. Do not use these scripts to
auto-login an administrator account.

Disabling Windows updates can leave the computer without security patches until
updates are re-enabled or managed another way. Some protected Windows services
may also be re-enabled later by Windows repair or feature servicing.

The desktop setup removes files from the Student desktop, public desktop,
startup folders, taskbar pinned shortcut folder, and selected autostart registry
locations. Move anything important before running it.

## File Overview

- `Run-StudentSetup-AsAdmin.cmd`: elevated launcher for Student account setup.
- `Setup-Student.ps1`: creates/restricts the Student user and configures
  auto-login.
- `StudentAccountTools.ps1`: shared helper functions for admin checks,
  registry edits, profile hive loading, policies, and auto-login.
- `Run-StudentDesktopSetup-AsAdmin.cmd`: elevated launcher for desktop cleanup.
- `Configure-StudentDesktop.ps1`: cleans desktop/startup/taskbar state and adds
  school app shortcuts.
- `Run-StudentCleanup-AsAdmin.cmd`: elevated launcher for forbidden app cleanup.
- `Cleanup-ForbiddenApps.ps1`: removes known unwanted apps from the Student
  profile.
- `Disable-StudentAutoLogin-AsAdmin.cmd`: elevated launcher to turn off
  Student auto-login.
- `Run-DisableWindowsUpdates-AsAdmin.cmd`: elevated launcher for update
  suppression.
- `Disable-WindowsUpdates.ps1`: applies local Windows Update restrictions.
