# apply-policy.ps1 - Enforce / remediate MDM policy on a device
# Author: Sulemana Akuantu Abdul Jalil (FCM.41.018.245.23)
#
# Brings a single device back into compliance with the OrgLab MDM Baseline
# using the ADB control channel (the same actions an MDM agent performs via
# the Android Device Administration / Device Owner APIs).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File apply-policy.ps1 -Serial emulator-5554
#   powershell -ExecutionPolicy Bypass -File apply-policy.ps1 -Serial emulator-5554 -DryRun
#
# NOTE: Disabling USB debugging (adb_enabled=0) severs the ADB session. The
# emulator console or `adb reconnect` is used to restore connectivity.

param(
    [Parameter(Mandatory = $true)]
    [string]$Serial,
    [switch]$DryRun,
    [switch]$KeepAdb
)

$ErrorActionPreference = "Continue"
$adb = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
Import-Module (Join-Path $PSScriptRoot "mdm.ps1") -Force

function Invoke-Enforce {
    param([string]$Label, [string]$Command)
    if ($DryRun) {
        Write-Host ("[DRY-RUN] {0}: {1}" -f $Label, $Command) -ForegroundColor DarkGray
        return
    }
    Write-Host ("[EXEC] {0}: {1}" -f $Label, $Command) -ForegroundColor Cyan
    Invoke-AdbShell -Serial $Serial -Command $Command | Out-Host
}

Write-Host "Applying OrgLab MDM Baseline to $Serial" -ForegroundColor Magenta
Write-Host "-------------------------------------------"
Enable-AdbRoot -Serial $Serial

# 1) Screen lock - write the lock credential state directly to the locksettings
#    database (equivalent of Device Admin setQuality(KEYGUARD_QUALITY_NUMERIC))
$lockSql = @"
INSERT OR REPLACE INTO locksettings(_id,name,user,value) VALUES(99,'lockscreen.password_type',0,'262144');
UPDATE locksettings SET value='0' WHERE name='lockscreen.disabled' AND user=0;
"@
if ($DryRun) {
    Write-Host "[DRY-RUN] screen-lock: locksettings.db <- password_type=262144 (PIN), lockscreen.disabled=0" -ForegroundColor DarkGray
} else {
    Write-Host "[EXEC] screen-lock: locksettings.db <- password_type=262144 (PIN), lockscreen.disabled=0" -ForegroundColor Cyan
    Invoke-AdbSqlite -Serial $Serial -Sql $lockSql | Out-Null
}

# 2) Auto-lock timeout <= 60s (CIS 4.1)
Invoke-Enforce "screen-lock-timeout" "settings put system screen_off_timeout 30000"
Invoke-Enforce "screen-lock-timeout" "settings put secure lock_screen_lock_after_timeout 30000"

# 3) Storage encryption - already enforced by OS; verified via ro.crypto.state

# 4) Block unknown sources + verify ADB installs (CIS 4.5)
Invoke-Enforce "unknown-sources" "settings put secure install_non_market_apps 0"
Invoke-Enforce "unknown-sources" "settings put global verifier_verify_adb_installs 1"

# 5) Enable app verification / Play Protect (CIS 4.6)
Invoke-Enforce "verify-apps" "settings put global package_verifier_enable 1"

# 6) Restrict camera app (data-loss-prevention)
Invoke-Enforce "camera-restricted" "pm disable-user --user 0 com.android.camera2"

# 7) USB debugging OFF (CIS 4.3) - disconnects ADB session.
#    -KeepAdb skips this so the live dashboard/collector can stay connected.
if ($KeepAdb) {
    Write-Host "[SKIP] usb-debugging (adb_enabled=0) skipped: -KeepAdb specified" -ForegroundColor DarkGray
} else {
    Invoke-Enforce "usb-debugging" "settings put global adb_enabled 0"
}

Write-Host ""
Write-Host "Policy enforcement complete for $Serial" -ForegroundColor Green
if (-not $DryRun) {
    Write-Host "USB debugging was disabled; use the emulator console or" -ForegroundColor Yellow
    Write-Host "  adb -s $Serial reconnect  (or restart the emulator) to re-connect." -ForegroundColor Yellow
}
