function Get-WorkspaceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Workspace
    )

    $totalServices = 0
    $runningServices = 0
    $totalExecutables = 0
    $runningExecutables = 0

    $servicesProperty = $Workspace.PSObject.Properties["services"]
    if ($null -ne $servicesProperty) {
        foreach ($serviceItem in @($servicesProperty.Value)) {
            $serviceName = [string]$serviceItem
            if ([string]::IsNullOrWhiteSpace($serviceName)) {
                continue
            }
            if ($serviceName -match '^t\s+(\d+)$') {
                continue
            }

            $isOptional = $serviceName.StartsWith("?")
            if ($isOptional) {
                $serviceName = $serviceName.Substring(1)
            }

            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -ne $service -and $service.Status -eq "Running") {
                $totalServices++
                $runningServices++
            } elseif (-not $isOptional) {
                $totalServices++
            }
        }
    }

    $executablesProperty = $Workspace.PSObject.Properties["executables"]
    if ($null -ne $executablesProperty) {
        foreach ($executableItem in @($executablesProperty.Value)) {
            $executionToken = [string]$executableItem
            if ([string]::IsNullOrWhiteSpace($executionToken)) {
                continue
            }
            if ($executionToken -match '^t\s+(\d+)$') {
                continue
            }

            $filePath = $executionToken
            if ($executionToken -match "^'(.*?)'\s*(.*)$") {
                $filePath = $matches[1]
            }

            $isOptional = $filePath.StartsWith("?")
            if ($isOptional) {
                $filePath = $filePath.Substring(1)
            }

            $leafName = Split-Path -Path $filePath -Leaf
            $cleanName = $leafName -replace "\.exe$", ""

            $process = Get-Process -Name $cleanName -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                $totalExecutables++
                $runningExecutables++
            } elseif (-not $isOptional) {
                $totalExecutables++
            }
        }
    }

    $totalItems = $totalServices + $totalExecutables
    $runningItems = $runningServices + $runningExecutables

    if ($totalItems -eq 0) {
        return "Stopped"
    }

    if ($runningItems -eq 0) {
        return "Stopped"
    }

    if ($runningItems -eq $totalItems) {
        return "Ready"
    }

    return "Mixed"
}
