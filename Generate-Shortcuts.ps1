Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$jsonPath = Join-Path -Path $PSScriptRoot -ChildPath "workspaces.json"
if (-not (Test-Path -Path $jsonPath -PathType Leaf)) {
    throw "Fatal: workspaces.json not found at '$jsonPath'."
}

$db = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json
$configProperty = $db.PSObject.Properties["_config"]
$configObject = $null
if ($null -ne $configProperty) {
    $configObject = $configProperty.Value
}

$consoleStyle = "Normal"
$prefixStart = "!Start-"
$prefixStop = "!Stop-"
if ($null -ne $configObject) {
    $consoleStyleProperty = $configObject.PSObject.Properties["console_style"]
    if ($null -ne $consoleStyleProperty -and $consoleStyleProperty.Value -eq "Hidden") {
        $consoleStyle = "Hidden"
    }

    $prefixStartProperty = $configObject.PSObject.Properties["shortcut_prefix_start"]
    if ($null -ne $prefixStartProperty -and -not [string]::IsNullOrWhiteSpace([string]$prefixStartProperty.Value)) {
        $prefixStart = [string]$prefixStartProperty.Value
    }

    $prefixStopProperty = $configObject.PSObject.Properties["shortcut_prefix_stop"]
    if ($null -ne $prefixStopProperty -and -not [string]::IsNullOrWhiteSpace([string]$prefixStopProperty.Value)) {
        $prefixStop = [string]$prefixStopProperty.Value
    }
}

$shortcutDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\WorkspaceManager"
if (-not (Test-Path -Path $shortcutDir -PathType Container)) {
    New-Item -ItemType Directory -Path $shortcutDir -Force | Out-Null
}

Get-ChildItem -Path $shortcutDir -Filter "*.lnk" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

$wshShell = New-Object -ComObject WScript.Shell
$orchestratorPath = Join-Path -Path $PSScriptRoot -ChildPath "Orchestrator.ps1"
$metadataKeys = @("_config", "comment", "description")

foreach ($workspaceName in $db.PSObject.Properties.Name) {
    if ($metadataKeys -contains $workspaceName) {
        continue
    }

    $shortcutMode = "both"
    $wsObj = $db.PSObject.Properties[$workspaceName].Value
    if ($wsObj -is [pscustomobject]) {
        $createForProperty = $wsObj.PSObject.Properties["create_shortcut_for"]
        if ($null -ne $createForProperty) {
            $raw = [string]$createForProperty.Value
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $normalized = $raw.Trim().ToLowerInvariant()
                switch ($normalized) {
                    "none" { $shortcutMode = "none" }
                    "start" { $shortcutMode = "start" }
                    "stop" { $shortcutMode = "stop" }
                    default {
                        throw "Invalid create_shortcut_for for workspace '$workspaceName': '$raw'. Allowed values: none, start, stop."
                    }
                }
            }
        }
    }

    if ($shortcutMode -eq "both" -or $shortcutMode -eq "start") {
        $startShortcutPath = Join-Path -Path $shortcutDir -ChildPath "$prefixStart$workspaceName.lnk"
        $startShortcut = $wshShell.CreateShortcut($startShortcutPath)
        $startShortcut.TargetPath = "pwsh.exe"
        $startShortcut.Arguments = "-WindowStyle $consoleStyle -ExecutionPolicy Bypass -File `"$orchestratorPath`" -WorkspaceName `"$workspaceName`" -Action `"Start`""
        $startShortcut.Save()
    }

    if ($shortcutMode -eq "both" -or $shortcutMode -eq "stop") {
        $stopShortcutPath = Join-Path -Path $shortcutDir -ChildPath "$prefixStop$workspaceName.lnk"
        $stopShortcut = $wshShell.CreateShortcut($stopShortcutPath)
        $stopShortcut.TargetPath = "pwsh.exe"
        $stopShortcut.Arguments = "-WindowStyle $consoleStyle -ExecutionPolicy Bypass -File `"$orchestratorPath`" -WorkspaceName `"$workspaceName`" -Action `"Stop`""
        $stopShortcut.Save()
    }
}

Write-Host "[ SUCCESS ] Workspace shortcuts generated and indexed in the Start Menu." -ForegroundColor Green
