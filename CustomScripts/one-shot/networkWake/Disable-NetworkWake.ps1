# PURPOSE:
#   One-shot hardening script to prevent network adapters from waking the PC.
#
# WHAT IT DOES:
#   1) OS-level: runs `powercfg /devicedisablewake` for each physical adapter.
#   2) Driver-level: disables Wake on Magic Packet and Wake on Pattern Match.
#
# WHEN TO USE:
#   If your laptop/PC wakes unexpectedly from sleep because of network activity.
#
# NOTES:
#   - Targets physical adapters (`Get-NetAdapter -Physical`).
#   - Uses gsudo auto-elevation; no manual "Run as admin" is required.
#   - Non-fatal adapter-specific errors are ignored intentionally.
#
# Clean, modern gsudo auto-elevation check utilizing pwsh (PowerShell 7)
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    gsudo pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit
}

Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "Executing Hardware Wake Containment Protocol..." -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan

# Find all physical network adapters (ignoring virtual Docker/Hyper-V switches)
$adapters = Get-NetAdapter -Physical

# 1. OS-Level: Uncheck the "Allow this device to wake the computer" box
Write-Host "Phase 1: Stripping OS ACPI Wake Permissions" -ForegroundColor Yellow
foreach ($adapter in $adapters) {
    $deviceName = $adapter.InterfaceDescription
    Write-Host " -> Neutralizing: $deviceName"
    # We pipe errors to NUL because powercfg throws a harmless error if the device is already disabled
    cmd.exe /c "powercfg /devicedisablewake `"$deviceName`" 2>NUL"
}

# 2. Driver-Level: Disable Magic Packet and Pattern Match in the Advanced tab
Write-Host "`nPhase 2: Disabling Driver-Level Listening Protocols" -ForegroundColor Yellow
$adapters | Disable-NetAdapterPowerManagement -WakeOnMagicPacket -ErrorAction SilentlyContinue
$adapters | Set-NetAdapterAdvancedProperty -DisplayName "*Wake on Magic Packet*" -DisplayValue "Disabled" -ErrorAction SilentlyContinue
$adapters | Set-NetAdapterAdvancedProperty -DisplayName "*Wake on Pattern Match*" -DisplayValue "Disabled" -ErrorAction SilentlyContinue

Write-Host "`n[ SUCCESS ] All network adapters are permanently locked out of ACPI wake states." -ForegroundColor Green
Write-Host "Your laptop will no longer turn itself on inside your bag." -ForegroundColor Green
Start-Sleep -Seconds 4