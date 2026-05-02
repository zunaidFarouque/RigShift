@echo off
TITLE Delivery Optimization - HTTP Only + No Cache
color 0B

:: PURPOSE:
::   Forces Delivery Optimization to use direct HTTP downloads only and
::   disables local cache growth (policy values set to 0).
::
:: WHAT THIS SCRIPT CHANGES:
::   1) Sets dosvc startup to Manual (demand) and starts it.
::   2) Sets DODownloadMode=99 (no peering).
::   3) Sets DOMaxCacheSize=0 and DOAbsoluteMaxCacheSize=0.
::
:: NOTE:
::   Run as Administrator (gsudo is used below).

echo =======================================================
echo 1. Restoring base service to prevent Windows Update errors...
echo =======================================================
gsudo sc config dosvc start= demand >nul
gsudo net start dosvc 2>nul

echo.
echo =======================================================
echo 2. Forcing Download Mode 99 (HTTP Only, No Peering)...
echo =======================================================
gsudo reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v DODownloadMode /t REG_DWORD /d 99 /f >nul

echo.
echo =======================================================
echo 3. Forcing Cache Limit to 0 GB to protect SSD...
echo =======================================================
gsudo reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v DOMaxCacheSize /t REG_DWORD /d 0 /f >nul
gsudo reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v DOAbsoluteMaxCacheSize /t REG_DWORD /d 0 /f >nul

echo.
echo [ SUCCESS ] Delivery Optimization policy lock is applied.
echo Windows Update will now use direct HTTP downloads only.
timeout /t 3 >nul
exit
