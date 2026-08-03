param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime = "win-x64",
    [switch]$FrameworkDependent
)

$ErrorActionPreference = "Stop"
$Project = Join-Path $PSScriptRoot "CodexPetMonitor.Windows\CodexPetMonitor.Windows.csproj"
$Output = Join-Path $PSScriptRoot "publish\$Runtime"
$SelfContained = if ($FrameworkDependent) { "false" } else { "true" }

dotnet publish $Project `
    --configuration Release `
    --runtime $Runtime `
    --self-contained $SelfContained `
    --output $Output `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None `
    -p:DebugSymbols=false

Write-Host "Built: $Output\CodexPetMonitor.exe"
