[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Start", "Stop")]
    [string]$Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command -Name Show-Notification -CommandType Function -ErrorAction SilentlyContinue)) {
    function Show-Notification {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Title,
            [Parameter(Mandatory = $true)]
            [string]$Message
        )

        try {
            $xmlPayload = @"
<toast>
  <visual>
    <binding template='ToastGeneric'>
      <text>$Title</text>
      <text>$Message</text>
    </binding>
  </visual>
</toast>
"@

            $xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xmlDoc.LoadXml($xmlPayload)
            $toast = [Windows.UI.Notifications.ToastNotification]::new($xmlDoc)
            $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("WorkspaceManager")
            $notifier.Show($toast)
        } catch {
            return
        }
    }
}

$dbPath = Join-Path -Path $PSScriptRoot -ChildPath "workspaces.json"

if (-not (Test-Path -Path $dbPath -PathType Leaf)) {
    throw "Fatal: workspaces.json not found."
}

$script:OrchestratorRepoRoot = [System.IO.Path]::GetDirectoryName($dbPath)

try {
    $workspaces = Get-Content -Path $dbPath -Raw -Encoding utf8 | ConvertFrom-Json
} catch {
    $parseDetail = $_.Exception.Message
    throw "Fatal: Failed to parse workspaces.json. $parseDetail"
}

$showNotifications = $false
$configProperty = $workspaces.PSObject.Properties["_config"]
if ($null -ne $configProperty) {
    $notificationsProperty = $configProperty.Value.PSObject.Properties["notifications"]
    if ($null -ne $notificationsProperty -and $notificationsProperty.Value -eq $true) {
        $showNotifications = $true
    }
}

$workspaceProperty = $workspaces.PSObject.Properties[$WorkspaceName]
if ($null -eq $workspaceProperty) {
    throw "Fatal: Workspace '$WorkspaceName' not defined in workspaces.json."
}

$workspace = $workspaceProperty.Value

$protectedProcessesProperty = $workspace.PSObject.Properties["protected_processes"]
if ($null -ne $protectedProcessesProperty) {
    $workspace.protected_processes = @(
        foreach ($processName in $protectedProcessesProperty.Value) {
            if ($processName -is [string]) {
                $processName -replace "\.exe$", ""
            } else {
                $processName
            }
        }
    )
}

# Phase 2: Pre-Flight Safety Checks
if ($Action -eq "Stop") {
    $protectedProcesses = @()
    $protectedProcessesProperty = $workspace.PSObject.Properties["protected_processes"]
    if ($null -ne $protectedProcessesProperty) {
        $protectedProcesses = @($protectedProcessesProperty.Value)
    }

    $activeProtected = @()
    if ($protectedProcesses.Count -gt 0) {
        foreach ($processName in $protectedProcesses) {
            if ([string]$processName -match '^#') {
                continue
            }
            $proc = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if ($null -ne $proc) {
                $activeProtected += $processName
            }
        }
    }

    if ($activeProtected.Count -gt 0) {
        Write-Host ""
        Write-Host "Warning: Protected Executables running..." -ForegroundColor Red
        foreach ($p in $activeProtected) {
            Write-Host "  - $($p).exe" -ForegroundColor Red
        }
        Write-Host "You might lose data if we force kill." -ForegroundColor Yellow
        $ans = Read-Host "Force kill anyway? (Y/N)"

        if ($ans -match "^[Nn]$") {
            throw "Abort: User cancelled teardown due to active protected process."
        }
    }
}

function Resolve-QuotedRelativeExecutionToken {
    param([Parameter(Mandatory)][string]$ExecutionToken)
    $root = $script:OrchestratorRepoRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = $PSScriptRoot
    }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    [regex]::Replace($ExecutionToken, "^'\.[\/\\](.*?)'", {
        param($match)
        $relativeRemainder = $match.Groups[1].Value -replace '/', $sep
        "'" + (Join-Path $root $relativeRemainder) + "'"
    })
}

function Resolve-RepoRelativeFilePath {
    param([Parameter(Mandatory)][string]$Path)
    $root = $script:OrchestratorRepoRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = $PSScriptRoot
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    $t = $Path.Trim()
    if ($t.Length -ge 2 -and $t[0] -eq [char]'.' -and ($t[1] -eq [char]'/' -or $t[1] -eq '\')) {
        $rest = $t.Substring(2).TrimStart([char[]]@('/', '\'))
        $rest = $rest -replace '/', [System.IO.Path]::DirectorySeparatorChar
        return (Join-Path $root $rest)
    }
    return $Path
}

function Start-ShortcutOrUrlShellExecute {
    param(
        [Parameter(Mandatory)][string]$ItemPath,
        [string]$Arguments,
        [switch]$Wait
    )
    $full = [System.IO.Path]::GetFullPath($ItemPath)
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $dir = $script:OrchestratorRepoRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $dir = $PSScriptRoot
        }
    }
    # Start-Process -FilePath treats () as wildcards. Use ShellExecute via ProcessStartInfo (works on PS 5.1+ and avoids Pester mocks that omit -LiteralPath).
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $full
    $psi.WorkingDirectory = $dir
    $psi.UseShellExecute = $true
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $psi.Arguments = $Arguments
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($Wait -and $null -ne $proc) {
        $proc.WaitForExit()
    }
}

# Phase 3: The Start Pipeline
if ($Action -eq "Start") {
    $servicesProperty = $workspace.PSObject.Properties["services"]
    if ($null -ne $servicesProperty) {
        foreach ($serviceItem in $servicesProperty.Value) {
            if ([string]$serviceItem -match '^#') {
                continue
            }
            if ($serviceItem -is [string] -and $serviceItem -match "^t\s+(\d+)$") {
                $sleepDuration = [int]$matches[1]
                Start-Sleep -Milliseconds $sleepDuration
                continue
            }

            $serviceName = [string]$serviceItem
            $isOptionalService = $serviceName.StartsWith("?")
            if ($isOptionalService) {
                $serviceName = $serviceName.Substring(1)
            }

            $svcCheck = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -eq $svcCheck) {
                if ($isOptionalService) {
                    Write-Host "Skipping optional service: $serviceName" -ForegroundColor DarkYellow
                    continue
                }
                Write-Host "Warning: Service '$serviceName' does not exist on this system." -ForegroundColor Yellow
                $ans = Read-Host "Ignore missing service and continue? (Y/N)"
                if ($ans -match "^[Nn]$") {
                    throw "Abort: Required service $serviceName is missing."
                }
                continue
            }

            Write-Host "Starting service: $serviceName..." -ForegroundColor Cyan
            gsudo sc.exe config $serviceName start= demand 2>&1 | Out-Null
            gsudo net.exe start $serviceName 2>&1 | Out-Null

            $pollStart = Get-Date
            while ($true) {
                $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                if ($null -ne $service -and $service.Status -eq "Running") {
                    break
                }

                $elapsedMs = ((Get-Date) - $pollStart).TotalMilliseconds
                if ($elapsedMs -ge 15000) {
                    Write-Warning "Timeout waiting for service [$serviceName] to reach Running state."
                    break
                }

                Start-Sleep -Milliseconds 500
            }
        }
    }

    $servicesDisableProperty = $workspace.PSObject.Properties["services_disable"]
    if ($null -ne $servicesDisableProperty) {
        foreach ($serviceItem in $servicesDisableProperty.Value) {
            if ([string]$serviceItem -match '^#') {
                continue
            }
            if ($serviceItem -is [string] -and $serviceItem -match "^t\s+(\d+)$") {
                $sleepDuration = [int]$matches[1]
                Start-Sleep -Milliseconds $sleepDuration
                continue
            }

            $serviceName = [string]$serviceItem
            $isOptionalSvcDisable = $serviceName.StartsWith("?")
            if ($isOptionalSvcDisable) {
                $serviceName = $serviceName.Substring(1)
            }

            $svcCheck = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -eq $svcCheck) {
                if ($isOptionalSvcDisable) {
                    Write-Host "Skipping optional services_disable entry: $serviceName" -ForegroundColor DarkYellow
                    continue
                }
                Write-Host "Warning: Service '$serviceName' does not exist on this system." -ForegroundColor Yellow
                $ans = Read-Host "Ignore missing service and continue? (Y/N)"
                if ($ans -match "^[Nn]$") {
                    throw "Abort: Required services_disable target $serviceName is missing."
                }
                continue
            }

            Write-Host "Stopping and disabling service: $serviceName..." -ForegroundColor Cyan
            gsudo net.exe stop $serviceName /y 2>&1 | Out-Null
            gsudo sc.exe config $serviceName start= disabled 2>&1 | Out-Null
        }
    }

    # scripts_start (runs synchronously, after services, before executables)
    $scriptsStartProperty = $workspace.PSObject.Properties["scripts_start"]
    if ($null -ne $scriptsStartProperty) {
        foreach ($scriptItem in $scriptsStartProperty.Value) {
            if ([string]$scriptItem -match '^#') {
                continue
            }
            if ($scriptItem -is [string] -and $scriptItem -match "^t\s+(\d+)$") {
                $sleepDuration = [int]$matches[1]
                Start-Sleep -Milliseconds $sleepDuration
                continue
            }

            $executionToken = Resolve-QuotedRelativeExecutionToken -ExecutionToken ([string]$scriptItem)
            $filePath = $executionToken
            $argumentList = ""

            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
                $argumentList = $matches[2]
            }

            $isOptionalScript = $filePath.StartsWith("?")
            if ($isOptionalScript) {
                $filePath = $filePath.Substring(1)
            }

            $filePath = Resolve-RepoRelativeFilePath -Path $filePath

            if (-not (Test-Path -LiteralPath $filePath)) {
                if ($isOptionalScript) {
                    Write-Host "Skipping optional script: $filePath" -ForegroundColor DarkYellow
                    continue
                }
                Write-Host "Warning: Script not found: $filePath" -ForegroundColor Yellow
                $ans = Read-Host "Ignore missing script and continue? (Y/N)"
                if ($ans -match "^[Nn]$") {
                    throw "Abort: Required script is missing: $filePath"
                }
                continue
            }

            $filePath = [System.IO.Path]::GetFullPath($filePath)

            if ($filePath -match '\.ps1$') {
                $pwshArg = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$filePath`""
                if (-not [string]::IsNullOrWhiteSpace($argumentList)) {
                    $pwshArg = "$pwshArg $argumentList"
                }

                Start-Process -FilePath "pwsh.exe" -ArgumentList $pwshArg -Wait -NoNewWindow 2>&1 | Out-Null
            } else {
                $ext = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
                $launchShortcutInOwnWindow = ($ext -eq '.lnk' -or $ext -eq '.url')
                if ($launchShortcutInOwnWindow) {
                    if ([string]::IsNullOrWhiteSpace($argumentList)) {
                        Start-ShortcutOrUrlShellExecute -ItemPath $filePath -Wait
                    } else {
                        Start-ShortcutOrUrlShellExecute -ItemPath $filePath -Arguments $argumentList -Wait
                    }
                } elseif ([string]::IsNullOrWhiteSpace($argumentList)) {
                    Start-Process -FilePath $filePath -Wait -NoNewWindow 2>&1 | Out-Null
                } else {
                    Start-Process -FilePath $filePath -ArgumentList $argumentList -Wait -NoNewWindow 2>&1 | Out-Null
                }
            }
        }
    }

    $pnpEnableProperty = $workspace.PSObject.Properties["pnp_devices_enable"]
    if ($null -ne $pnpEnableProperty) {
        foreach ($devName in @($pnpEnableProperty.Value)) {
            if ([string]::IsNullOrWhiteSpace([string]$devName)) { continue }
            if ([string]$devName -match '^#') { continue }
            $psCmd = 'Get-PnpDevice -FriendlyName "{0}" -ErrorAction SilentlyContinue | Enable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue' -f $devName
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($psCmd))
            gsudo powershell -NoProfile -EncodedCommand $encoded 2>&1 | Out-Null
        }
    }

    $pnpDisableProperty = $workspace.PSObject.Properties["pnp_devices_disable"]
    if ($null -ne $pnpDisableProperty) {
        foreach ($devName in @($pnpDisableProperty.Value)) {
            if ([string]::IsNullOrWhiteSpace([string]$devName)) { continue }
            if ([string]$devName -match '^#') { continue }
            $psCmd = 'Get-PnpDevice -FriendlyName "{0}" -ErrorAction SilentlyContinue | Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue' -f $devName
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($psCmd))
            gsudo powershell -NoProfile -EncodedCommand $encoded 2>&1 | Out-Null
        }
    }

    $powerPlanProperty = $workspace.PSObject.Properties["power_plan_start"]
    if ($null -ne $powerPlanProperty -and -not [string]::IsNullOrWhiteSpace([string]$powerPlanProperty.Value)) {
        $planName = [string]$powerPlanProperty.Value
        $plansOutput = powercfg /l
        foreach ($line in @($plansOutput)) {
            if ($line -match [regex]::Escape($planName)) {
                $guidMatch = [regex]::Match([string]$line, "([0-9a-fA-F-]{36})")
                if (-not $guidMatch.Success) {
                    continue
                }
                $planGuid = $guidMatch.Groups[1].Value
                powercfg /setactive $planGuid | Out-Null
                break
            }
        }
    }

    $registryTogglesProperty = $workspace.PSObject.Properties["registry_toggles"]
    if ($null -ne $registryTogglesProperty) {
        foreach ($item in @($registryTogglesProperty.Value)) {
            if ($null -eq $item) { continue }
            $pathProp = $item.PSObject.Properties["path"]
            $nameProp = $item.PSObject.Properties["name"]
            $valueStartProp = $item.PSObject.Properties["value_start"]
            $typeProp = $item.PSObject.Properties["type"]
            if ($null -eq $pathProp -or $null -eq $nameProp -or $null -eq $valueStartProp -or $null -eq $typeProp) { continue }
            gsudo New-ItemProperty -Path $pathProp.Value -Name $nameProp.Value -Value $valueStartProp.Value -PropertyType $typeProp.Value -Force 2>&1 | Out-Null
        }
    }

    $executablesProperty = $workspace.PSObject.Properties["executables"]
    if ($null -ne $executablesProperty) {
        foreach ($executableItem in $executablesProperty.Value) {
            if ([string]$executableItem -match '^#') {
                continue
            }
            if ($executableItem -is [string] -and $executableItem -match "^t\s+(\d+)$") {
                $sleepDuration = [int]$matches[1]
                Start-Sleep -Milliseconds $sleepDuration
                continue
            }

            $executionToken = Resolve-QuotedRelativeExecutionToken -ExecutionToken ([string]$executableItem)
            $filePath = $executionToken
            $argumentList = ""

            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
                $argumentList = $matches[2]
            }

            $isOptionalExecutable = $filePath.StartsWith("?")
            if ($isOptionalExecutable) {
                $filePath = $filePath.Substring(1)
            }

            $filePath = Resolve-RepoRelativeFilePath -Path $filePath

            if ($isOptionalExecutable -and -not (Test-Path -LiteralPath $filePath)) {
                Write-Host "Skipping optional executable: $filePath" -ForegroundColor DarkYellow
                continue
            }

            $filePath = [System.IO.Path]::GetFullPath($filePath)
            $exeExt = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
            if ($exeExt -eq '.lnk' -or $exeExt -eq '.url') {
                if ([string]::IsNullOrWhiteSpace($argumentList)) {
                    Start-ShortcutOrUrlShellExecute -ItemPath $filePath
                } else {
                    Start-ShortcutOrUrlShellExecute -ItemPath $filePath -Arguments $argumentList
                }
            } elseif ([string]::IsNullOrWhiteSpace($argumentList)) {
                Start-Process -FilePath $filePath
            } else {
                Start-Process -FilePath $filePath -ArgumentList $argumentList
            }
        }
    }

    if ($showNotifications) {
        Show-Notification -Title "Workspace Ready" -Message "$WorkspaceName is now active."
    }
}

# Phase 4: The Stop Pipeline
if ($Action -eq "Stop") {
    # scripts_stop (runs synchronously; scripts are executed before any teardown)
    $scriptsStopProperty = $workspace.PSObject.Properties["scripts_stop"]
    if ($null -ne $scriptsStopProperty) {
        foreach ($scriptItem in $scriptsStopProperty.Value) {
            if ([string]$scriptItem -match '^#') {
                continue
            }
            if ($scriptItem -is [string] -and $scriptItem -match "^t\s+(\d+)$") {
                continue
            }

            $executionToken = Resolve-QuotedRelativeExecutionToken -ExecutionToken ([string]$scriptItem)
            $filePath = $executionToken
            $argumentList = ""

            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
                $argumentList = $matches[2]
            }

            $isOptionalScript = $filePath.StartsWith("?")
            if ($isOptionalScript) {
                $filePath = $filePath.Substring(1)
            }

            $filePath = Resolve-RepoRelativeFilePath -Path $filePath

            if (-not (Test-Path -LiteralPath $filePath)) {
                if ($isOptionalScript) {
                    Write-Host "Skipping optional script: $filePath" -ForegroundColor DarkYellow
                    continue
                }
                Write-Host "Warning: Script not found: $filePath" -ForegroundColor Yellow
                $ans = Read-Host "Ignore missing script and continue? (Y/N)"
                if ($ans -match "^[Nn]$") {
                    throw "Abort: Required script is missing: $filePath"
                }
                continue
            }

            $filePath = [System.IO.Path]::GetFullPath($filePath)

            if ($filePath -match '\.ps1$') {
                $pwshArg = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$filePath`""
                if (-not [string]::IsNullOrWhiteSpace($argumentList)) {
                    $pwshArg = "$pwshArg $argumentList"
                }

                Start-Process -FilePath "pwsh.exe" -ArgumentList $pwshArg -Wait -NoNewWindow 2>&1 | Out-Null
            } else {
                $ext = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
                $launchShortcutInOwnWindow = ($ext -eq '.lnk' -or $ext -eq '.url')
                if ($launchShortcutInOwnWindow) {
                    if ([string]::IsNullOrWhiteSpace($argumentList)) {
                        Start-ShortcutOrUrlShellExecute -ItemPath $filePath -Wait
                    } else {
                        Start-ShortcutOrUrlShellExecute -ItemPath $filePath -Arguments $argumentList -Wait
                    }
                } elseif ([string]::IsNullOrWhiteSpace($argumentList)) {
                    Start-Process -FilePath $filePath -Wait -NoNewWindow 2>&1 | Out-Null
                } else {
                    Start-Process -FilePath $filePath -ArgumentList $argumentList -Wait -NoNewWindow 2>&1 | Out-Null
                }
            }
        }
    }

    $servicesDisableProperty = $workspace.PSObject.Properties["services_disable"]
    if ($null -ne $servicesDisableProperty) {
        foreach ($serviceItem in @($servicesDisableProperty.Value)) {
            if ([string]$serviceItem -match '^#') {
                continue
            }
            if ($serviceItem -is [string] -and $serviceItem -match "^t\s+(\d+)$") {
                continue
            }

            $serviceName = [string]$serviceItem
            if ($serviceName.StartsWith("?")) {
                $serviceName = $serviceName.Substring(1)
            }

            $svcCheck = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -eq $svcCheck) {
                continue
            }

            Write-Host "Restoring service: $serviceName..." -ForegroundColor Cyan
            gsudo sc.exe config $serviceName start= demand 2>&1 | Out-Null
            gsudo net.exe start $serviceName 2>&1 | Out-Null
        }
    }

    $powerPlanStopProp = $workspace.PSObject.Properties["power_plan_stop"]
    if ($null -ne $powerPlanStopProp -and -not [string]::IsNullOrWhiteSpace([string]$powerPlanStopProp.Value)) {
        $stopPlanName = [string]$powerPlanStopProp.Value
        $plansOutputStop = powercfg /l
        foreach ($line in @($plansOutputStop)) {
            if ($line -match [regex]::Escape($stopPlanName)) {
                $guidMatchStop = [regex]::Match([string]$line, "([0-9a-fA-F-]{36})")
                if (-not $guidMatchStop.Success) {
                    continue
                }
                $planGuidStop = $guidMatchStop.Groups[1].Value
                powercfg /setactive $planGuidStop | Out-Null
                break
            }
        }
    }

    $executablesProperty = $workspace.PSObject.Properties["executables"]
    if ($null -ne $executablesProperty) {
        $executables = @($executablesProperty.Value)
        for ($i = $executables.Count - 1; $i -ge 0; $i--) {
            $executableItem = $executables[$i]
            if ([string]$executableItem -match '^#') {
                continue
            }

            if ($executableItem -is [string] -and $executableItem -match "^t\s+(\d+)$") {
                continue
            }

            $executionToken = Resolve-QuotedRelativeExecutionToken -ExecutionToken ([string]$executableItem)
            $filePath = $executionToken
            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
            }
            if ($filePath.StartsWith("?")) {
                $filePath = $filePath.Substring(1)
            }

            $filePath = Resolve-RepoRelativeFilePath -Path $filePath

            $exeName = Split-Path -Path $filePath -Leaf
            gsudo taskkill /F /IM $exeName /T 2>&1 | Out-Null
            Start-Sleep -Seconds 1
        }
    }

    $pnpEnableProperty = $workspace.PSObject.Properties["pnp_devices_enable"]
    if ($null -ne $pnpEnableProperty) {
        foreach ($devName in @($pnpEnableProperty.Value)) {
            if ([string]::IsNullOrWhiteSpace([string]$devName)) { continue }
            if ([string]$devName -match '^#') { continue }
            $psCmd = 'Get-PnpDevice -FriendlyName "{0}" -ErrorAction SilentlyContinue | Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue' -f $devName
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($psCmd))
            gsudo powershell -NoProfile -EncodedCommand $encoded 2>&1 | Out-Null
        }
    }

    $pnpDisableProperty = $workspace.PSObject.Properties["pnp_devices_disable"]
    if ($null -ne $pnpDisableProperty) {
        foreach ($devName in @($pnpDisableProperty.Value)) {
            if ([string]::IsNullOrWhiteSpace([string]$devName)) { continue }
            if ([string]$devName -match '^#') { continue }
            $psCmd = 'Get-PnpDevice -FriendlyName "{0}" -ErrorAction SilentlyContinue | Enable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue' -f $devName
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($psCmd))
            gsudo powershell -NoProfile -EncodedCommand $encoded 2>&1 | Out-Null
        }
    }

    $powerPlanStartProp = $workspace.PSObject.Properties["power_plan_start"]
    $stopPlanConfigured = ($null -ne $powerPlanStopProp -and -not [string]::IsNullOrWhiteSpace([string]$powerPlanStopProp.Value))
    $onlyStartNoStop = ($null -ne $powerPlanStartProp -and -not [string]::IsNullOrWhiteSpace([string]$powerPlanStartProp.Value)) -and -not $stopPlanConfigured
    if ($onlyStartNoStop) {
        Write-Host "Note: Power plans are not automatically reverted on Stop. Use a Recovery workspace." -ForegroundColor Yellow
    }

    $registryTogglesProperty = $workspace.PSObject.Properties["registry_toggles"]
    if ($null -ne $registryTogglesProperty) {
        foreach ($item in @($registryTogglesProperty.Value)) {
            if ($null -eq $item) { continue }
            $pathProp = $item.PSObject.Properties["path"]
            $nameProp = $item.PSObject.Properties["name"]
            $typeProp = $item.PSObject.Properties["type"]
            $valueStopProp = $item.PSObject.Properties["value_stop"]
            if ($null -eq $pathProp -or $null -eq $nameProp -or $null -eq $typeProp) { continue }

            $stopVal = $null
            if ($null -ne $valueStopProp) {
                $stopVal = $valueStopProp.Value
            }
            if ($null -ne $stopVal) {
                Write-Host "Reverting Registry Key: $($nameProp.Value)..." -ForegroundColor Cyan
                gsudo New-ItemProperty -Path $pathProp.Value -Name $nameProp.Value -Value $stopVal -PropertyType $typeProp.Value -Force 2>&1 | Out-Null
            } else {
                Write-Host "Note: Registry toggle '$($nameProp.Value)' has no value_stop defined. Skipping reversion." -ForegroundColor Yellow
            }
        }
    }

    $servicesProperty = $workspace.PSObject.Properties["services"]
    if ($null -ne $servicesProperty) {
        $services = @($servicesProperty.Value)
        for ($i = $services.Count - 1; $i -ge 0; $i--) {
            $serviceItem = $services[$i]
            if ([string]$serviceItem -match '^#') {
                continue
            }

            if ($serviceItem -is [string] -and $serviceItem -match "^t\s+(\d+)$") {
                continue
            }

            $serviceName = [string]$serviceItem
            if ($serviceName.StartsWith("?")) {
                $serviceName = $serviceName.Substring(1)
            }
            $svcCheck = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -eq $svcCheck) {
                continue
            }

            Write-Host "Stopping service: $serviceName..." -ForegroundColor Cyan
            gsudo net.exe stop $serviceName /y 2>&1 | Out-Null
            gsudo sc.exe config $serviceName start= disabled 2>&1 | Out-Null
        }
    }

    $reverseRelationsProperty = $workspace.PSObject.Properties["reverse_relations"]
    if ($null -ne $reverseRelationsProperty) {
        foreach ($revServiceName in @($reverseRelationsProperty.Value)) {
            if ([string]$revServiceName -match '^#') {
                continue
            }
            gsudo sc.exe config $revServiceName start= demand 2>&1 | Out-Null
            gsudo net.exe start $revServiceName 2>&1 | Out-Null
        }
    }

    if ($showNotifications) {
        Show-Notification -Title "Workspace Stopped" -Message "$WorkspaceName has been cleanly terminated."
    }
}

$workspace
