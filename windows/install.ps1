param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime = "win-x64"
)

$ErrorActionPreference = "Stop"
$PublishDir = Join-Path $PSScriptRoot "publish\$Runtime"
$Executable = Join-Path $PublishDir "CodexPetMonitor.exe"
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\CodexPetMonitor"

if (-not (Test-Path $Executable)) {
    throw "Build output not found. Run .\windows\build.ps1 -Runtime $Runtime first."
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Path (Join-Path $PublishDir "*") -Destination $InstallDir -Recurse -Force

$Shell = New-Object -ComObject WScript.Shell
$ShortcutPath = Join-Path ([Environment]::GetFolderPath("Programs")) "Codex Pet Monitor.lnk"
$Shortcut = $Shell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = Join-Path $InstallDir "CodexPetMonitor.exe"
$Shortcut.WorkingDirectory = $InstallDir
$Shortcut.Description = "Codex task status desktop pet"
$Shortcut.Save()

Start-Process (Join-Path $InstallDir "CodexPetMonitor.exe")
Write-Host "Installed: $InstallDir"
