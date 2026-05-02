@echo off
TITLE One-Shot Purge - Windows Update + Delivery Optimization (LTSC)
color 0C

:: PURPOSE:
::   One-time disk cleanup for update-related bloat on LTSC-like setups.
::
:: WHAT THIS SCRIPT DOES:
::   1) Stops Windows Update (wuauserv) and Delivery Optimization (dosvc).
::   2) Deletes Delivery Optimization cache folder.
::   3) Disables dosvc startup.
::   4) Clears and recreates SoftwareDistribution\Download.
::   5) Runs DISM component cleanup (WinSxS maintenance).
::   6) Restarts wuauserv.
::
:: WARNING:
::   This is an aggressive maintenance script. Use intentionally.
::   Run as Administrator (gsudo is used below).

echo =======================================================
echo 1. HALTING UPDATE SERVICES...
echo =======================================================
gsudo net stop wuauserv /y >nul 2>&1
gsudo net stop dosvc /y >nul 2>&1

echo.
echo =======================================================
echo 2. VAPORIZING DELIVERY OPTIMIZATION CACHE (3.3 GB)...
echo =======================================================
gsudo rd /s /q "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" 2>nul
:: Permanently disable the Delivery Optimization service
gsudo sc config dosvc start= disabled >nul

echo.
echo =======================================================
echo 3. PURGING STALE UPDATE DOWNLOADS (2.0 GB)...
echo =======================================================
gsudo rd /s /q "C:\Windows\SoftwareDistribution\Download" 2>nul
gsudo mkdir "C:\Windows\SoftwareDistribution\Download" 2>nul

echo.
echo =======================================================
echo 4. COMPRESSING WINSXS COMPONENT STORE...
echo (This step may take 3 to 10 minutes. Do not close.)
echo =======================================================
gsudo dism.exe /Online /Cleanup-Image /StartComponentCleanup

echo.
echo =======================================================
echo 5. RESTARTING ESSENTIAL UPDATE SERVICE...
echo =======================================================
gsudo net start wuauserv >nul 2>&1

echo.
echo [ SUCCESS ] Purge complete.
echo Run WizTree again to verify reclaimed SSD space.
pause
exit
