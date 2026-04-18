[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Start", "Stop")]
    [string]$Action,

    [ValidateSet("App_Workload", "System_Mode", "Hardware_Override")]
    [string]$ProfileType,

    [ValidateSet("All", "HardwareOnly", "PowerPlanOnly", "ServicesOnly", "ExecutablesOnly")]
    [string]$ExecutionScope = "All",

    [switch]$SkipInterceptorSync,

    [switch]$InteractiveServiceWait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-OrchestratorRepoRoot {
    param([Parameter(Mandatory)][string]$ConfigDirectory)

    if (Test-Path -LiteralPath (Join-Path -Path $ConfigDirectory -ChildPath "CustomScripts") -PathType Container) {
        return $ConfigDirectory
    }

    $parentDir = Split-Path -Path $ConfigDirectory -Parent
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and
        (Test-Path -LiteralPath (Join-Path -Path $parentDir -ChildPath "CustomScripts") -PathType Container)) {
        return $parentDir
    }

    return $ConfigDirectory
}

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
            $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("RigShift")
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

$configDir = [System.IO.Path]::GetDirectoryName($dbPath)
$script:OrchestratorRepoRoot = Resolve-OrchestratorRepoRoot -ConfigDirectory $configDir
try {
    $workspaces = Get-Content -Path $dbPath -Raw -Encoding utf8 | ConvertFrom-Json
} catch {
    $parseDetail = $_.Exception.Message
    throw "Fatal: Failed to parse workspaces.json. $parseDetail"
}

$showNotifications = $false
$enableInterceptors = $false
$configProperty = $workspaces.PSObject.Properties["_config"]
if ($null -ne $configProperty) {
    $notificationsProperty = $configProperty.Value.PSObject.Properties["notifications"]
    if ($null -ne $notificationsProperty -and $notificationsProperty.Value -eq $true) {
        $showNotifications = $true
    }
    $interceptorsProperty = $configProperty.Value.PSObject.Properties["enable_interceptors"]
    if ($null -ne $interceptorsProperty -and $interceptorsProperty.Value -eq $true) {
        $enableInterceptors = $true
    }
}

$script:ExecutionWaitTimeoutMs = 15000
# Stop/start can sit in StopPending/StartPending (e.g. Office ClickToRun).
$script:ServiceLifecycleWaitTimeoutMs = 90000
$script:IfeoRegistryRoot = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
$script:OrchestratorInteractiveServiceWait = $InteractiveServiceWait.IsPresent
$script:RigShiftServiceWaitSkippedMessage = "RigShift: Service wait skipped by user."
$script:RigShiftServiceWaitAbortedMessage = "RigShift: Service wait aborted by user."

function Wait-OrchestratorServiceDesiredStatus {
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][System.ServiceProcess.ServiceControllerStatus]$DesiredStatus,
        [Parameter(Mandatory)][int]$TimeoutMs
    )

    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    $pollMs = 400
    while ($true) {
        $svc = Get-Service -Name $ServiceName -ErrorAction Stop
        if ($svc.Status -eq $DesiredStatus) {
            return
        }
        if ([datetime]::UtcNow -ge $deadline) {
            throw "Service '$ServiceName' did not reach ${DesiredStatus} state within ${TimeoutMs}ms (current status: $($svc.Status))."
        }
        if ($script:OrchestratorInteractiveServiceWait) {
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq [ConsoleKey]::Escape) {
                        throw $script:RigShiftServiceWaitAbortedMessage
                    }
                    if ($key.Key -eq [ConsoleKey]::S) {
                        throw $script:RigShiftServiceWaitSkippedMessage
                    }
                }
            } catch {
                if ([string]$_.Exception.Message -eq $script:RigShiftServiceWaitAbortedMessage -or
                    [string]$_.Exception.Message -eq $script:RigShiftServiceWaitSkippedMessage) {
                    throw
                }
            }
        }
        Start-Sleep -Milliseconds $pollMs
    }
}

function Invoke-ElevatedPowerShell {
    param([Parameter(Mandatory)][string]$Command)

    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
    gsudo powershell -NoProfile -EncodedCommand $encoded 2>&1 | Out-Null
}

function Invoke-ElevatedServiceLifecycle {
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][ValidateSet("Start", "Stop")][string]$Operation
    )

    $svc = Get-Service -Name $ServiceName -ErrorAction Stop

    if ($Operation -eq "Start") {
        if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
            return
        }
        if ($svc.StartType -eq [System.ServiceProcess.ServiceStartMode]::Disabled) {
            throw "Cannot start service '$ServiceName': startup type is disabled."
        }
    } else {
        if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            return
        }
    }

    # Single-quoted literal in the remote script — do NOT use "name" | ConvertFrom-Json (pipeline passes the
    # unquoted string value, which is invalid JSON and leaves $sn null).
    $svcNameLiteral = $ServiceName.Replace("'", "''")
    if ($Operation -eq "Start") {
        $body = "`$ErrorActionPreference='Stop'; `$sn = '$svcNameLiteral'; Start-Service -Name `$sn -ErrorAction Stop"
    } else {
        $killOfficeC2R = ""
        if ([string]$ServiceName -eq "ClickToRunSvc") {
            $killOfficeC2R = "foreach (`$im in @('OfficeClickToRun.exe','AppVShNotify.exe')) { Start-Process -FilePath (Join-Path `$env:SystemRoot 'System32\taskkill.exe') -ArgumentList @('/F','/IM',`$im,'/T') -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null }; "
        }
        $body = "`$ErrorActionPreference='Continue'; " + $killOfficeC2R +
            "`$sn = '$svcNameLiteral'; Stop-Service -Name `$sn -Force -ErrorAction SilentlyContinue; " +
            "`$s = Get-Service -Name `$sn -ErrorAction Stop; " +
            "if (`$s.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) { " +
            "`$sc = Join-Path `$env:SystemRoot 'System32\sc.exe'; " +
            "`$p = Start-Process -FilePath `$sc -ArgumentList @('stop',`$sn) -Wait -PassThru -WindowStyle Hidden; " +
            "if (`$null -ne `$p -and `$p.ExitCode -ne 0) { exit 1 } }"
    }
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($body))
    # Assignment from native output can leave $? true even when the elevated process failed; use exit code.
    $LASTEXITCODE = 0
    $out = & gsudo powershell -NoProfile -EncodedCommand $encoded 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = if ($null -ne $out) {
            (@($out) | ForEach-Object { "$_" }) -join "; "
        } else {
            "(no output)"
        }
        $verb = if ($Operation -eq "Start") { "start" } else { "stop" }
        throw "Failed to $verb service '$ServiceName': $msg"
    }

    $desired = if ($Operation -eq "Start") {
        [System.ServiceProcess.ServiceControllerStatus]::Running
    } else {
        [System.ServiceProcess.ServiceControllerStatus]::Stopped
    }
    if ($script:OrchestratorInteractiveServiceWait) {
        Write-Host ("Waiting for service '{0}' to reach {1}. Press S to skip waiting for this step, Esc to abort the commit." -f $ServiceName, $desired) -ForegroundColor DarkGray
    }
    Wait-OrchestratorServiceDesiredStatus -ServiceName $ServiceName -DesiredStatus $desired -TimeoutMs $script:ServiceLifecycleWaitTimeoutMs
}

function Wait-ProcessWithTimeout {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][int]$TimeoutMs,
        [Parameter(Mandatory)][string]$OperationName
    )

    if ($TimeoutMs -le 0) {
        $Process.WaitForExit()
        return
    }

    $finished = $Process.WaitForExit($TimeoutMs)
    if (-not $finished) {
        try {
            if (-not $Process.HasExited) {
                $Process.Kill($true)
            }
        } catch {
            # Best effort cleanup; continue with warning below.
        }
        Write-Warning "Timeout while waiting for '$OperationName'. Continuing after $TimeoutMs ms."
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

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $full
    $psi.WorkingDirectory = $dir
    $psi.UseShellExecute = $true
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $psi.Arguments = $Arguments
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($Wait -and $null -ne $proc) {
        Wait-ProcessWithTimeout -Process $proc -TimeoutMs $script:ExecutionWaitTimeoutMs -OperationName $full
    }
}

function Invoke-ExecutionToken {
    param(
        [Parameter(Mandatory)][string]$ExecutionToken,
        [switch]$Wait
    )

    $token = Resolve-QuotedRelativeExecutionToken -ExecutionToken $ExecutionToken
    $filePath = $token
    $argumentList = ""
    $tokenWasQuotedPath = $false
    if ($token -match "^'(.*?)'\s*(.*)$") {
        $filePath = $matches[1]
        $argumentList = $matches[2]
        $tokenWasQuotedPath = $true
    } elseif ($token -match "^(\S+)\s+(.+)$") {
        # Support command tokens like: gsudo taskkill /F /IM GCC.exe
        $filePath = $matches[1]
        $argumentList = $matches[2]
    }

    $shouldResolveAsPath = $tokenWasQuotedPath -or
        $filePath.StartsWith(".\") -or
        $filePath.StartsWith("./") -or
        $filePath -match '^[a-zA-Z]:[\\/]' -or
        $filePath.Contains("\") -or
        $filePath.Contains("/")

    if ($shouldResolveAsPath) {
        $filePath = Resolve-RepoRelativeFilePath -Path $filePath
        $filePath = [System.IO.Path]::GetFullPath($filePath)
        if (-not (Test-Path -LiteralPath $filePath)) {
            throw "Executable path does not exist: '$filePath'"
        }
    }

    $ext = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()

    if ($filePath -match '\.ps1$') {
        $pwshArg = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$filePath`""
        if (-not [string]::IsNullOrWhiteSpace($argumentList)) {
            $pwshArg = "$pwshArg $argumentList"
        }

        if ($Wait) {
            Start-Process -FilePath "pwsh.exe" -ArgumentList $pwshArg -Wait -NoNewWindow 2>&1 | Out-Null
        } else {
            Start-Process -FilePath "pwsh.exe" -ArgumentList $pwshArg 2>&1 | Out-Null
        }
        return
    }

    if ($ext -eq ".lnk" -or $ext -eq ".url") {
        if ([string]::IsNullOrWhiteSpace($argumentList)) {
            Start-ShortcutOrUrlShellExecute -ItemPath $filePath -Wait:$Wait
        } else {
            Start-ShortcutOrUrlShellExecute -ItemPath $filePath -Arguments $argumentList -Wait:$Wait
        }
        return
    }

    if ($Wait) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $filePath
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        if (-not [string]::IsNullOrWhiteSpace($argumentList)) {
            $psi.Arguments = $argumentList
        }

        $proc = [System.Diagnostics.Process]::Start($psi)
        if ($null -ne $proc) {
            $opName = if ([string]::IsNullOrWhiteSpace($argumentList)) { $filePath } else { "$filePath $argumentList" }
            Wait-ProcessWithTimeout -Process $proc -TimeoutMs $script:ExecutionWaitTimeoutMs -OperationName $opName
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($argumentList)) {
            Start-Process -FilePath $filePath 2>&1 | Out-Null
        } else {
            Start-Process -FilePath $filePath -ArgumentList $argumentList 2>&1 | Out-Null
        }
    }
}

function Set-PowerPlanByName {
    param([Parameter(Mandatory)][string]$PlanName)

    $plansOutput = powercfg /l
    foreach ($line in @($plansOutput)) {
        if ($line -match [regex]::Escape($PlanName)) {
            $guidMatch = [regex]::Match([string]$line, "([0-9a-fA-F-]{36})")
            if ($guidMatch.Success) {
                powercfg /setactive $guidMatch.Groups[1].Value | Out-Null
            }
            break
        }
    }
}

function Invoke-HardwareDefinitionTransition {
    param(
        [Parameter(Mandatory = $true)][string]$ComponentName,
        [Parameter(Mandatory = $true)][psobject]$Definition,
        [Parameter(Mandatory = $true)][string]$DesiredState
    )

    $overrideEntries = $null
    if ($DesiredState -eq "ON" -and $null -ne $Definition.PSObject.Properties["action_override_on"]) {
        $overrideEntries = @($Definition.action_override_on)
    } elseif ($DesiredState -eq "OFF" -and $null -ne $Definition.PSObject.Properties["action_override_off"]) {
        $overrideEntries = @($Definition.action_override_off)
    }

    if ($null -ne $overrideEntries -and $overrideEntries.Count -gt 0) {
        foreach ($entry in $overrideEntries) {
            if ([string]::IsNullOrWhiteSpace([string]$entry)) { continue }
            Invoke-ExecutionToken -ExecutionToken ([string]$entry) -Wait
        }
        return
    }

    switch ([string]$Definition.type) {
        "pnp_device" {
            foreach ($matchPattern in @($Definition.match)) {
                if ([string]::IsNullOrWhiteSpace([string]$matchPattern)) { continue }
                $verb = if ($DesiredState -eq "ON") { "Enable-PnpDevice" } else { "Disable-PnpDevice" }
                $psCmd = 'Get-PnpDevice -FriendlyName "{0}" -ErrorAction SilentlyContinue | {1} -Confirm:$false -ErrorAction SilentlyContinue' -f ([string]$matchPattern), $verb
                $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($psCmd))
                gsudo powershell -NoProfile -EncodedCommand $encoded 2>&1 | Out-Null
            }
        }
        "service" {
            $serviceName = [string]$Definition.name
            if ([string]::IsNullOrWhiteSpace($serviceName)) { break }
            if ($DesiredState -eq "ON") {
                Invoke-ElevatedServiceLifecycle -ServiceName $serviceName -Operation Start
            } else {
                Invoke-ElevatedServiceLifecycle -ServiceName $serviceName -Operation Stop
            }
        }
        "registry" {
            $valueToSet = if ($DesiredState -eq "ON") { $Definition.value_on } else { $Definition.value_off }
            $path = [string]$Definition.path
            $name = [string]$Definition.name
            if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($name)) { break }
            $propertyType = "DWord"
            if ($null -ne $Definition.PSObject.Properties["value_type"] -and -not [string]::IsNullOrWhiteSpace([string]$Definition.value_type)) {
                $propertyType = [string]$Definition.value_type
            }
            gsudo New-ItemProperty -Path $path -Name $name -Value $valueToSet -PropertyType $propertyType -Force 2>&1 | Out-Null
        }
        "process" {
            # No native command path for process targets; rely on action overrides.
        }
        "stateless" {
            # No native command path for stateless targets.
        }
    }
}

function Invoke-HardwareTargetTransitions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$HardwareTargets,
        [Parameter(Mandatory = $true)]
        [psobject]$HardwareDefinitions,
        [Parameter(Mandatory = $true)]
        [ValidateSet("Start", "Stop")]
        [string]$Action,
        [switch]$InvertOnStop
    )

    if ($null -eq $HardwareTargets) {
        return
    }

    $resolvedTargetMap = [ordered]@{}
    foreach ($target in $HardwareTargets.PSObject.Properties) {
        $targetKey = [string]$target.Name
        $targetState = [string]$target.Value
        if ([string]::IsNullOrWhiteSpace($targetKey)) {
            continue
        }

        if ($targetKey.StartsWith("@")) {
            $aliasToken = $targetKey.Substring(1).Trim()
            if ([string]::IsNullOrWhiteSpace($aliasToken)) {
                continue
            }
            $aliasPattern = "*$aliasToken*"
            $matchedComponents = @(
                $HardwareDefinitions.PSObject.Properties |
                    Where-Object { [string]$_.Name -like $aliasPattern } |
                    Sort-Object -Property Name |
                    ForEach-Object { [string]$_.Name }
            )
            foreach ($matchedComponent in $matchedComponents) {
                $resolvedTargetMap[$matchedComponent] = $targetState
            }
            continue
        }

        $resolvedTargetMap[$targetKey] = $targetState
    }

    foreach ($componentName in $resolvedTargetMap.Keys) {
        $targetState = [string]$resolvedTargetMap[$componentName]
        if ($targetState -eq "ANY") {
            continue
        }

        $desiredState = $targetState
        if ($Action -eq "Stop" -and $InvertOnStop.IsPresent) {
            $desiredState = if ($targetState -eq "ON") { "OFF" } else { "ON" }
        }

        if ($null -eq $HardwareDefinitions -or $null -eq $HardwareDefinitions.PSObject.Properties[$componentName]) {
            continue
        }

        $def = $HardwareDefinitions.PSObject.Properties[$componentName].Value
        Invoke-HardwareDefinitionTransition -ComponentName $componentName -Definition $def -DesiredState $desiredState
    }
}

function Sync-Interceptors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Workspaces,
        [Parameter(Mandatory)][bool]$Enabled
    )

    $ifeoRoot = $script:IfeoRegistryRoot
    $ownerTag = "BG-Services-Orchestrator"
    $versionTag = "1"
    if (-not $Enabled) {
        $removedCount = 0
        $existingKeys = @(Get-ChildItem -Path $ifeoRoot -ErrorAction SilentlyContinue)
        foreach ($key in $existingKeys) {
            $managed = Get-ItemProperty -Path $key.PSPath -Name "RigShift_Managed" -ErrorAction SilentlyContinue
            if ($null -eq $managed -or [string]$managed.RigShift_Managed -ne "1") {
                continue
            }
            $owner = Get-ItemProperty -Path $key.PSPath -Name "RigShift_Owner" -ErrorAction SilentlyContinue
            if ($null -ne $owner -and
                $null -ne $owner.PSObject.Properties["RigShift_Owner"] -and
                -not [string]::IsNullOrWhiteSpace([string]$owner.RigShift_Owner) -and
                [string]$owner.RigShift_Owner -ne $ownerTag) {
                continue
            }

            $escapedPath = ($ifeoRoot + "\" + $key.PSChildName).Replace('"', '""')
            Invoke-ElevatedPowerShell -Command "Remove-ItemProperty -Path `"$escapedPath`" -Name `"Debugger`" -ErrorAction SilentlyContinue; Remove-ItemProperty -Path `"$escapedPath`" -Name `"RigShift_Managed`" -ErrorAction SilentlyContinue; Remove-ItemProperty -Path `"$escapedPath`" -Name `"RigShift_Owner`" -ErrorAction SilentlyContinue; Remove-ItemProperty -Path `"$escapedPath`" -Name `"RigShift_InterceptorVersion`" -ErrorAction SilentlyContinue; Remove-ItemProperty -Path `"$escapedPath`" -Name `"RigShift_LastSyncedUtc`" -ErrorAction SilentlyContinue"
            $removedCount++
        }
        return [pscustomobject]@{
            Enabled      = $false
            AddedCount   = 0
            RemovedCount = $removedCount
        }
    }

    $addedCount = 0
    $wrapperPath = Join-Path -Path $PSScriptRoot -ChildPath "Interceptor.vbs"
    $wrapperPath = [System.IO.Path]::GetFullPath($wrapperPath)
    $debuggerValue = ('wscript.exe "{0}"' -f $wrapperPath).Replace('"', '`"')

    foreach ($entry in @(Get-AppWorkloadEntries -AppWorkloads $Workspaces.App_Workloads)) {
        $interceptsProp = $entry.Workload.PSObject.Properties["intercepts"]
        if ($null -eq $interceptsProp) { continue }

        foreach ($intercept in @($entry.Workload.intercepts)) {
            # Support legacy string intercepts and new intercept-rule objects.
            $exeNames = @()
            if ($intercept -is [string]) {
                $exeNames = @($intercept)
            } else {
                $exeProp = $intercept.PSObject.Properties["exe"]
                if ($null -eq $exeProp) { continue }
                $exeValue = $intercept.exe
                if ($exeValue -is [System.Array]) {
                    $exeNames = @($exeValue)
                } else {
                    $exeNames = @([string]$exeValue)
                }
            }

            foreach ($exeName in @($exeNames)) {
                $exeName = [string]$exeName
                if ([string]::IsNullOrWhiteSpace($exeName)) { continue }

                $ifeoPath = ($ifeoRoot + "\" + $exeName).Replace('"', '""')
                $syncStamp = [DateTime]::UtcNow.ToString("o")
                $command = @"
New-Item -Path "$ifeoPath" -Force | Out-Null
New-ItemProperty -Path "$ifeoPath" -Name "Debugger" -Value "$debuggerValue" -PropertyType String -Force | Out-Null
New-ItemProperty -Path "$ifeoPath" -Name "RigShift_Managed" -Value "1" -PropertyType String -Force | Out-Null
New-ItemProperty -Path "$ifeoPath" -Name "RigShift_Owner" -Value "$ownerTag" -PropertyType String -Force | Out-Null
New-ItemProperty -Path "$ifeoPath" -Name "RigShift_InterceptorVersion" -Value "$versionTag" -PropertyType String -Force | Out-Null
New-ItemProperty -Path "$ifeoPath" -Name "RigShift_LastSyncedUtc" -Value "$syncStamp" -PropertyType String -Force | Out-Null
"@
                Invoke-ElevatedPowerShell -Command $command
                $addedCount++
            }
        }
    }

    return [pscustomobject]@{
        Enabled      = $true
        AddedCount   = $addedCount
        RemovedCount = 0
    }
}

function Get-AppWorkloadEntries {
    [CmdletBinding()]
    param([psobject]$AppWorkloads)

    if ($null -eq $AppWorkloads) { return @() }
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($domainProp in @($AppWorkloads.PSObject.Properties)) {
        if ($null -eq $domainProp.Value) { continue }
        foreach ($workloadProp in @($domainProp.Value.PSObject.Properties)) {
            if ($null -eq $workloadProp.Value) { continue }
            $entries.Add([pscustomobject]@{
                Domain   = [string]$domainProp.Name
                Name     = [string]$workloadProp.Name
                Workload = $workloadProp.Value
            })
        }
    }
    return @($entries)
}

function Resolve-AppWorkloadByName {
    [CmdletBinding()]
    param(
        [psobject]$AppWorkloads,
        [string]$WorkloadName
    )

    foreach ($entry in @(Get-AppWorkloadEntries -AppWorkloads $AppWorkloads)) {
        if ([string]$entry.Name -eq $WorkloadName) {
            return $entry.Workload
        }
    }
    return $null
}

# Phase 1 routing: resolve profile type and data
$resolvedProfileType = $null
$resolvedProfileData = $null
$systemModesProperty = $workspaces.PSObject.Properties["System_Modes"]
$appWorkloadsProperty = $workspaces.PSObject.Properties["App_Workloads"]
$hardwareDefsProperty = $workspaces.PSObject.Properties["Hardware_Definitions"]

if ($null -ne $configProperty -and -not $SkipInterceptorSync.IsPresent) {
    $interceptorSync = Sync-Interceptors -Workspaces $workspaces -Enabled:$enableInterceptors
    if ($null -ne $interceptorSync) {
        if ($interceptorSync.Enabled) {
            Write-Host "Interceptors: synced $($interceptorSync.AddedCount) managed IFEO hook(s)."
        } else {
            Write-Host "Interceptors: cleaned $($interceptorSync.RemovedCount) managed IFEO hook(s)."
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($ProfileType)) {
    if ($ProfileType -eq "Hardware_Override") {
        if ($null -eq $hardwareDefsProperty -or $null -eq $hardwareDefsProperty.Value.PSObject.Properties[$WorkspaceName]) {
            throw "Fatal: Hardware override component '$WorkspaceName' not defined in workspaces.json."
        }
        $resolvedProfileType = "Hardware_Override"
        $resolvedProfileData = $hardwareDefsProperty.Value.PSObject.Properties[$WorkspaceName].Value
    } elseif ($ProfileType -eq "System_Mode") {
        if ($null -eq $systemModesProperty -or $null -eq $systemModesProperty.Value.PSObject.Properties[$WorkspaceName]) {
            throw "Fatal: Workspace '$WorkspaceName' not defined under System_Modes in workspaces.json."
        }
        $resolvedProfileType = "System_Mode"
        $resolvedProfileData = $systemModesProperty.Value.PSObject.Properties[$WorkspaceName].Value
    } elseif ($ProfileType -eq "App_Workload") {
        $resolvedAppWorkload = Resolve-AppWorkloadByName -AppWorkloads $appWorkloadsProperty.Value -WorkloadName $WorkspaceName
        if ($null -eq $appWorkloadsProperty -or $null -eq $resolvedAppWorkload) {
            throw "Fatal: Workspace '$WorkspaceName' not defined under App_Workloads in workspaces.json."
        }
        $resolvedProfileType = "App_Workload"
        $resolvedProfileData = $resolvedAppWorkload
    }
} elseif ($null -ne $systemModesProperty -and $null -ne $systemModesProperty.Value.PSObject.Properties[$WorkspaceName]) {
    $resolvedProfileType = "System_Mode"
    $resolvedProfileData = $systemModesProperty.Value.PSObject.Properties[$WorkspaceName].Value
} else {
    $resolvedAppWorkload = $null
    if ($null -ne $appWorkloadsProperty) {
        $resolvedAppWorkload = Resolve-AppWorkloadByName -AppWorkloads $appWorkloadsProperty.Value -WorkloadName $WorkspaceName
    }
    if ($null -ne $resolvedAppWorkload) {
    $resolvedProfileType = "App_Workload"
        $resolvedProfileData = $resolvedAppWorkload
    } else {
        throw "Fatal: Workspace '$WorkspaceName' not defined in workspaces.json."
    }
}

# Phase 3/4 execution
if ($resolvedProfileType -eq "App_Workload") {
    $runHardware = ($ExecutionScope -eq "All" -or $ExecutionScope -eq "HardwareOnly")
    $runServices = ($ExecutionScope -eq "All" -or $ExecutionScope -eq "ServicesOnly")
    $runExecutables = ($ExecutionScope -eq "All" -or $ExecutionScope -eq "ExecutablesOnly")

    $appHardwareTargetsProperty = $resolvedProfileData.PSObject.Properties["hardware_targets"]
    if ($runHardware -and $null -ne $appHardwareTargetsProperty) {
        $hardwareDefs = $workspaces.PSObject.Properties["Hardware_Definitions"]
        if ($null -ne $hardwareDefs) {
            Invoke-HardwareTargetTransitions -HardwareTargets $appHardwareTargetsProperty.Value -HardwareDefinitions $hardwareDefs.Value -Action $Action -InvertOnStop
        }
    }

    if ($Action -eq "Start") {
        if ($runServices) {
            foreach ($serviceName in @($resolvedProfileData.services)) {
                if ([string]::IsNullOrWhiteSpace([string]$serviceName)) { continue }
                Invoke-ElevatedServiceLifecycle -ServiceName ([string]$serviceName) -Operation Start
            }
        }
        if ($runExecutables) {
            foreach ($executionToken in @($resolvedProfileData.executables)) {
                if ([string]::IsNullOrWhiteSpace([string]$executionToken)) { continue }
                Invoke-ExecutionToken -ExecutionToken ([string]$executionToken)
            }
        }

        if ($showNotifications) {
            Show-Notification -Title "Workspace Ready" -Message "$WorkspaceName is now active."
        }
    } else {
        if ($runExecutables) {
            $executables = @($resolvedProfileData.executables)
            for ($i = $executables.Count - 1; $i -ge 0; $i--) {
                $executionToken = Resolve-QuotedRelativeExecutionToken -ExecutionToken ([string]$executables[$i])
                $filePath = $executionToken
                if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                    $filePath = $matches[1]
                }
                $filePath = Resolve-RepoRelativeFilePath -Path $filePath
                $exeName = Split-Path -Path $filePath -Leaf
                if (-not [string]::IsNullOrWhiteSpace($exeName)) {
                    gsudo taskkill /F /IM $exeName /T 2>&1 | Out-Null
                }
            }
        }
        if ($runServices) {
            foreach ($serviceName in @($resolvedProfileData.services)) {
                if ([string]::IsNullOrWhiteSpace([string]$serviceName)) { continue }
                Invoke-ElevatedServiceLifecycle -ServiceName ([string]$serviceName) -Operation Stop
            }
        }

        if ($showNotifications) {
            Show-Notification -Title "Workspace Stopped" -Message "$WorkspaceName has been cleanly terminated."
        }
    }
} elseif ($resolvedProfileType -eq "System_Mode") {
    $powerPlanProp = $resolvedProfileData.PSObject.Properties["power_plan"]
    $runHardware = ($ExecutionScope -eq "All" -or $ExecutionScope -eq "HardwareOnly")
    $runPowerPlan = ($ExecutionScope -eq "All" -or $ExecutionScope -eq "PowerPlanOnly")
    if ($runPowerPlan -and $Action -eq "Start" -and $null -ne $powerPlanProp -and -not [string]::IsNullOrWhiteSpace([string]$powerPlanProp.Value)) {
        Set-PowerPlanByName -PlanName ([string]$powerPlanProp.Value)
    }

    $hardwareTargets = $resolvedProfileData.PSObject.Properties["hardware_targets"]
    if (-not $runHardware -or $null -eq $hardwareTargets) {
        $resolvedProfileData
        return
    }

    $hardwareDefs = $workspaces.PSObject.Properties["Hardware_Definitions"]
    if ($null -ne $hardwareDefs) {
        Invoke-HardwareTargetTransitions -HardwareTargets $hardwareTargets.Value -HardwareDefinitions $hardwareDefs.Value -Action $Action -InvertOnStop
    }

    if ($Action -eq "Start" -and $showNotifications) {
        Show-Notification -Title "Workspace Ready" -Message "$WorkspaceName is now active."
    }
    if ($Action -eq "Stop" -and $showNotifications) {
        Show-Notification -Title "Workspace Stopped" -Message "$WorkspaceName has been cleanly terminated."
    }
} elseif ($resolvedProfileType -eq "Hardware_Override") {
    $targetState = if ($null -ne $resolvedProfileData.PSObject.Properties["target_state"]) { [string]$resolvedProfileData.target_state } else { "" }
    if ([string]::IsNullOrWhiteSpace($targetState)) {
        $targetState = if ($Action -eq "Start") { "ON" } else { "OFF" }
    }
    if ($targetState -eq "ANY") {
        $resolvedProfileData
        return
    }

    $desiredState = $targetState

    Invoke-HardwareDefinitionTransition -ComponentName $WorkspaceName -Definition $resolvedProfileData -DesiredState $desiredState
}

$resolvedProfileData
