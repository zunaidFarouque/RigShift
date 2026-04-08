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

try {
    $workspaces = Get-Content -Path $dbPath -Raw | ConvertFrom-Json
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

# Phase 3: The Start Pipeline
if ($Action -eq "Start") {
    $servicesProperty = $workspace.PSObject.Properties["services"]
    if ($null -ne $servicesProperty) {
        foreach ($serviceItem in $servicesProperty.Value) {
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

    # scripts_start (runs synchronously, after services, before executables)
    $scriptsStartProperty = $workspace.PSObject.Properties["scripts_start"]
    if ($null -ne $scriptsStartProperty) {
        foreach ($scriptItem in $scriptsStartProperty.Value) {
            if ($scriptItem -is [string] -and $scriptItem -match "^t\s+(\d+)$") {
                $sleepDuration = [int]$matches[1]
                Start-Sleep -Milliseconds $sleepDuration
                continue
            }

            $executionToken = [string]$scriptItem
            $filePath = $executionToken
            $argumentList = ""

            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
                $argumentList = $matches[2]
            }

            if ($filePath -match '\.ps1$') {
                $pwshArg = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$filePath`""
                if (-not [string]::IsNullOrWhiteSpace($argumentList)) {
                    $pwshArg = "$pwshArg $argumentList"
                }

                Start-Process -FilePath "pwsh.exe" -ArgumentList $pwshArg -Wait -NoNewWindow 2>&1 | Out-Null
            } else {
                if ([string]::IsNullOrWhiteSpace($argumentList)) {
                    Start-Process -FilePath $filePath -Wait -NoNewWindow 2>&1 | Out-Null
                } else {
                    Start-Process -FilePath $filePath -ArgumentList $argumentList -Wait -NoNewWindow 2>&1 | Out-Null
                }
            }
        }
    }

    $executablesProperty = $workspace.PSObject.Properties["executables"]
    if ($null -ne $executablesProperty) {
        foreach ($executableItem in $executablesProperty.Value) {
            if ($executableItem -is [string] -and $executableItem -match "^t\s+(\d+)$") {
                $sleepDuration = [int]$matches[1]
                Start-Sleep -Milliseconds $sleepDuration
                continue
            }

            $executionToken = [string]$executableItem
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

            if ($isOptionalExecutable -and -not (Test-Path -Path $filePath)) {
                Write-Host "Skipping optional executable: $filePath" -ForegroundColor DarkYellow
                continue
            }

            if ([string]::IsNullOrWhiteSpace($argumentList)) {
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
            if ($scriptItem -is [string] -and $scriptItem -match "^t\s+(\d+)$") {
                continue
            }

            $executionToken = [string]$scriptItem
            $filePath = $executionToken
            $argumentList = ""

            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
                $argumentList = $matches[2]
            }

            if ($filePath -match '\.ps1$') {
                $pwshArg = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$filePath`""
                if (-not [string]::IsNullOrWhiteSpace($argumentList)) {
                    $pwshArg = "$pwshArg $argumentList"
                }

                Start-Process -FilePath "pwsh.exe" -ArgumentList $pwshArg -Wait -NoNewWindow 2>&1 | Out-Null
            } else {
                if ([string]::IsNullOrWhiteSpace($argumentList)) {
                    Start-Process -FilePath $filePath -Wait -NoNewWindow 2>&1 | Out-Null
                } else {
                    Start-Process -FilePath $filePath -ArgumentList $argumentList -Wait -NoNewWindow 2>&1 | Out-Null
                }
            }
        }
    }

    $executablesProperty = $workspace.PSObject.Properties["executables"]
    if ($null -ne $executablesProperty) {
        $executables = @($executablesProperty.Value)
        for ($i = $executables.Count - 1; $i -ge 0; $i--) {
            $executableItem = $executables[$i]

            if ($executableItem -is [string] -and $executableItem -match "^t\s+(\d+)$") {
                continue
            }

            $executionToken = [string]$executableItem
            $filePath = $executionToken
            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
            }
            if ($filePath.StartsWith("?")) {
                $filePath = $filePath.Substring(1)
            }

            $exeName = Split-Path -Path $filePath -Leaf
            gsudo taskkill /F /IM $exeName /T 2>&1 | Out-Null
            Start-Sleep -Seconds 1
        }
    }

    $servicesProperty = $workspace.PSObject.Properties["services"]
    if ($null -ne $servicesProperty) {
        $services = @($servicesProperty.Value)
        for ($i = $services.Count - 1; $i -ge 0; $i--) {
            $serviceItem = $services[$i]

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
            gsudo sc.exe config $revServiceName start= demand 2>&1 | Out-Null
            gsudo net.exe start $revServiceName 2>&1 | Out-Null
        }
    }

    if ($showNotifications) {
        Show-Notification -Title "Workspace Stopped" -Message "$WorkspaceName has been cleanly terminated."
    }
}

$workspace
