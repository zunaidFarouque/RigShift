# ==============================================================================
# NVIDIA Optimus Driver Bounce Script for RigShift
# ==============================================================================

# 0. Self-Elevation Check
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrative Privileges..." -ForegroundColor Yellow
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$Host.UI.RawUI.WindowTitle = "RigShift - NVIDIA Driver Bounce"

# Smaller console (character grid, not pixels). Adjust as you like. Silently skipped if the host cannot resize.
$PreferredConsoleWidth  = 82
$PreferredConsoleHeight = 18
try {
    $raw = $Host.UI.RawUI
    if ($null -ne $raw.WindowSize -and $null -ne $raw.BufferSize) {
        if ($raw.BufferSize.Width -lt $PreferredConsoleWidth) {
            $raw.BufferSize = New-Object System.Management.Automation.Host.Size($PreferredConsoleWidth, $raw.BufferSize.Height)
        }
        $raw.WindowSize = New-Object System.Management.Automation.Host.Size($PreferredConsoleWidth, $PreferredConsoleHeight)
    }
} catch {
    # e.g. Windows PowerShell ISE, constrained remoting, or host without a resizable buffer
}

Clear-Host
Write-Host "Initializing NVIDIA PCIe Link Reset..." -ForegroundColor Cyan
Write-Host "--------------------------------------"

# Identify the Target Devices/Services
$svcPattern = "*NVIDIA Display*"
$gpuPattern = "*NVIDIA GeForce*"

$svc = Get-Service -DisplayName $svcPattern -ErrorAction SilentlyContinue | Select-Object -First 1
$gpu = Get-PnpDevice -FriendlyName $gpuPattern -ErrorAction SilentlyContinue | Select-Object -First 1

# Step 1: Disable Service
Write-Host "1. Disabling Service [$($svc.DisplayName)]... " -NoNewline
try {
    if ($svc) {
        Stop-Service -Name $svc.Name -Force -ErrorAction Stop
        Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
        Write-Host "OK | Disabled." -ForegroundColor Green
    } else {
        Write-Host "SKIPPED | Service Not Found." -ForegroundColor Yellow
    }
} catch {
    Write-Host "ERROR | $($_.Exception.Message)" -ForegroundColor Red
}

# Step 2: Disable GPU
Write-Host "2. Disabling PnpDevice [$($gpu.FriendlyName)]... " -NoNewline
try {
    if ($gpu) {
        $gpu | Disable-PnpDevice -Confirm:$false -ErrorAction Stop
        Write-Host "OK | Disabled." -ForegroundColor Green
    } else {
        Write-Host "SKIPPED | GPU Not Found." -ForegroundColor Yellow
    }
} catch {
    Write-Host "ERROR | $($_.Exception.Message)" -ForegroundColor Red
}

# Step 3: Pause
Write-Host "3. Pausing for 3 seconds... " -NoNewline
Start-Sleep -Seconds 3
Write-Host "OK | Resuming." -ForegroundColor Green

# Step 4: Enable GPU
Write-Host "4. Enabling PnpDevice [$($gpu.FriendlyName)]... " -NoNewline
try {
    if ($gpu) {
        $gpu | Enable-PnpDevice -Confirm:$false -ErrorAction Stop
        Write-Host "OK | Enabled." -ForegroundColor Green
    } else {
        Write-Host "SKIPPED | GPU Not Found." -ForegroundColor Yellow
    }
} catch {
    Write-Host "ERROR | $($_.Exception.Message)" -ForegroundColor Red
}

# Step 5: Enable Service
Write-Host "5. Enabling Service [$($svc.DisplayName)]... " -NoNewline
try {
    if ($svc) {
        Set-Service -Name $svc.Name -StartupType Automatic -ErrorAction Stop
        Start-Service -Name $svc.Name -ErrorAction Stop
        Write-Host "OK | Enabled." -ForegroundColor Green
    } else {
        Write-Host "SKIPPED | Service Not Found." -ForegroundColor Yellow
    }
} catch {
    Write-Host "ERROR | $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "--------------------------------------"
Write-Host "Driver Bounce Complete." -ForegroundColor Cyan
