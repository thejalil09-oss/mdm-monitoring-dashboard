# mdm.ps1 - MDM monitoring & compliance engine (ADB control channel)
# Author: Sulemana Akuantu Abdul Jalil (FCM.41.018.245.23)
# Blue Team - Cyber Labwork II Semester Project
#
# This module drives the Android Emulator fleet over the Android Debug Bridge
# (ADB). It collects device state, evaluates it against the policy baseline in
# scripts/policies/policy.json and computes a compliance score per device.

$script:AdbPath = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"

function Invoke-AdbShell {
    param(
        [string]$Serial,
        [string]$Command,
        [string]$Adb = $script:AdbPath
    )
    & $Adb -s $Serial shell $Command 2>$null
}

function Get-AdbProp {
    param([string]$Serial, [string]$Prop)
    return (Invoke-AdbShell -Serial $Serial -Command "getprop $Prop" | Out-String).Trim()
}

function Get-AdbSetting {
    param([string]$Serial, [string]$Namespace, [string]$Key)
    return (Invoke-AdbShell -Serial $Serial -Command "settings get $Namespace $Key" | Out-String).Trim()
}

function Get-DeviceIdentity {
    param([string]$Serial)
    $androidId = Get-AdbSetting -Serial $Serial -Namespace secure -Key android_id
    return [PSCustomObject]@{
        adbSerial      = $Serial
        androidId      = if ($androidId -eq "null") { "" } else { $androidId }
        model          = Get-AdbProp $Serial "ro.product.model"
        manufacturer   = Get-AdbProp $Serial "ro.product.manufacturer"
        osVersion      = Get-AdbProp $Serial "ro.build.version.release"
        sdkLevel       = Get-AdbProp $Serial "ro.build.version.sdk"
        securityPatch  = Get-AdbProp $Serial "ro.build.version.security_patch"
        buildFingerprint = Get-AdbProp $Serial "ro.build.fingerprint"
        serialNo       = Get-AdbProp $Serial "ro.serialno"
        deviceName     = Get-AdbSetting $Serial global device_name
    }
}

function Get-BatteryState {
    param([string]$Serial)
    $dump = Invoke-AdbShell -Serial $Serial -Command "dumpsys battery" | Out-String
    $level = [regex]::Match($dump, "level:\s*(\d+)").Groups[1].Value
    $health = [regex]::Match($dump, "health:\s*(\d+)").Groups[1].Value
    $status = [regex]::Match($dump, "status:\s*(\d+)").Groups[1].Value
    return [PSCustomObject]@{
        level  = if ($level) { [int]$level } else { -1 }
        health = if ($health) { [int]$health } else { -1 }
        status = if ($status) { [int]$status } else { -1 }
    }
}

function Get-StorageUsage {
    param([string]$Serial)
    $df = Invoke-AdbShell -Serial $Serial -Command "df -k /data" | Out-String
    $lines = $df -split "`n" | Where-Object { $_ -match "/data" }
    $usedMb = 0; $totalMb = 0
    foreach ($line in $lines) {
        $parts = ($line -split "\s+" | Where-Object { $_ -ne "" })
        if ($parts.Count -ge 4 -and $parts[0] -match "/data") {
            # fields: Filesystem 1K-blocks Used Available Use% Mounted
            $totalMb = [math]::Round([double]$parts[1] / 1024, 1)
            $usedMb = [math]::Round([double]$parts[2] / 1024, 1)
        }
    }
    return [PSCustomObject]@{ usedGb = [math]::Round($usedMb / 1024, 2); totalGb = [math]::Round($totalMb / 1024, 2) }
}

function Get-InstalledApps {
    param([string]$Serial)
    $pkgs = Invoke-AdbShell -Serial $Serial -Command "pm list packages -3" | Out-String
    $names = $pkgs -split "`n" | ForEach-Object { $_.Trim() -replace "^package:", "" } | Where-Object { $_ -ne "" }
    return @($names)
}

function Invoke-AdbSqlite {
    param(
        [string]$Serial,
        [string]$Sql,
        [string]$Db = "/data/system/locksettings.db",
        [string]$Adb = $script:AdbPath
    )
    # Pushing the SQL as a file avoids the shell-quoting problems that adb.exe
    # has with embedded quotes on Windows. Requires root (adb root) to read the
    # locksettings database.
    $hostSql = Join-Path $env:TEMP "mdm_query.sql"
    Set-Content -LiteralPath $hostSql -Value $Sql -NoNewline -Encoding ASCII
    & $Adb -s $Serial push $hostSql /data/local/tmp/mdm_query.sql 2> "$env:TEMP\adb_push_err.txt" | Out-Null
    return (Invoke-AdbShell -Serial $Serial -Command "sqlite3 $Db < /data/local/tmp/mdm_query.sql" | Out-String).Trim()
}

function Enable-AdbRoot {
    param([string]$Serial)
    & $script:AdbPath -s $Serial root 2> "$env:TEMP\adb_root_err.txt" | Out-Null
    & $script:AdbPath -s $Serial wait-for-device 2> "$env:TEMP\adb_wait_err.txt" | Out-Null
    # Wait until the device is fully booted again (settings service available)
    for ($i = 0; $i -lt 30; $i++) {
        $boot = (Invoke-AdbShell -Serial $Serial -Command "getprop sys.boot_completed" | Out-String).Trim()
        if ($boot -eq "1") { break }
        Start-Sleep -Seconds 2
    }
    # The settings service may still be warming up after adbd restarts; poll it.
    for ($i = 0; $i -lt 15; $i++) {
        $probe = (Invoke-AdbShell -Serial $Serial -Command "settings get secure android_id" | Out-String).Trim()
        if ($probe -ne "" -and $probe -ne "cmd: Can't find service: settings" -and $probe -ne "null") { return }
        Start-Sleep -Seconds 2
    }
}

function Get-ScreenLockState {
    param([string]$Serial)
    # The Android lock credential lives in the locksettings database. An MDM
    # agent reads this same store to determine whether a device is locked down.
    $sql = "SELECT name, value FROM locksettings WHERE user=0 AND name IN ('lockscreen.password_type','lockscreen.password_type_alternate','lockscreen.disabled');"
    $rows = Invoke-AdbSqlite -Serial $Serial -Sql $sql
    $type = "0"; $alt = "0"; $disabled = "1"
    foreach ($line in ($rows -split "`n")) {
        $parts = $line -split "\|"
        if ($parts.Count -ge 2) {
            switch ($parts[0].Trim()) {
                "lockscreen.password_type"              { $type = $parts[1].Trim() }
                "lockscreen.password_type_alternate"    { $alt = $parts[1].Trim() }
                "lockscreen.disabled"                   { $disabled = $parts[1].Trim() }
            }
        }
    }
    $effective = if ([int]$type -gt 0) { $type } elseif ([int]$alt -gt 0) { $alt } else { "0" }
    return [PSCustomObject]@{
        passwordType = [int]$type
        alternate    = [int]$alt
        disabled     = $disabled
        lockSet      = ([int]$effective -gt 0 -and $disabled -ne "1")
    }
}

function Get-ComplianceCheck {
    param([string]$Serial, [object]$Rule)
    $result = "FAIL"
    $actual = ""
    $detail = ""

    switch ($Rule.id) {
        "screen-lock-enabled" {
            $s = Get-ScreenLockState -Serial $Serial
            $actual = "password_type=" + $s.passwordType + ", lockscreen.disabled=" + $s.disabled
            if ($s.lockSet) { $result = "PASS" }
            $detail = "Requires lockscreen.password_type != 0"
        }
        "screen-lock-timeout" {
            $screenOff = Get-AdbSetting $Serial system "screen_off_timeout"
            $lockAfter = Get-AdbSetting $Serial secure "lock_screen_lock_after_timeout"
            if ($screenOff -eq "null") { $screenOff = "-1" }
            if ($lockAfter -eq "null") { $lockAfter = "-1" }
            $actual = "screen_off_timeout=$screenOff ms, lock_after_timeout=$lockAfter ms"
            $maxMs = [math]::Max([long]$screenOff, [long]$lockAfter)
            if ($maxMs -gt 0 -and $maxMs -le 60000) { $result = "PASS" }
            $detail = "Requires max auto-lock <= 60000 ms"
        }
        "encryption" {
            $state = Get-AdbProp $Serial "ro.crypto.state"
            $type = Get-AdbProp $Serial "ro.crypto.type"
            $actual = "ro.crypto.state=$state, ro.crypto.type=$type"
            if ($state -eq "encrypted") { $result = "PASS" }
            $detail = "Requires full-disk or file-based encryption"
        }
        "usb-debugging" {
            $adbEnabled = Get-AdbSetting $Serial global "adb_enabled"
            if ($adbEnabled -eq "null" -or $adbEnabled -eq "") { $adbEnabled = "1" }
            $actual = "adb_enabled=$adbEnabled"
            if ($adbEnabled -eq "0") { $result = "PASS" }
            $detail = "Requires adb_enabled == 0"
        }
        "unknown-sources" {
            $nonMarket = Get-AdbSetting $Serial secure "install_non_market_apps"
            $verifyAdb = Get-AdbSetting $Serial global "verifier_verify_adb_installs"
            if ($nonMarket -eq "null") { $nonMarket = "-1" }
            if ($verifyAdb -eq "null") { $verifyAdb = "0" }
            $actual = "install_non_market_apps=$nonMarket, verifier_verify_adb_installs=$verifyAdb"
            if ($nonMarket -eq "0" -and $verifyAdb -eq "1") { $result = "PASS" }
            $detail = "Requires unknown-source installs blocked and ADB installs verified"
        }
        "verify-apps" {
            $verifier = Get-AdbSetting $Serial global "package_verifier_enable"
            $actual = "package_verifier_enable=$verifier"
            if ($verifier -eq "1") { $result = "PASS" }
            $detail = "Requires app verification (Play Protect) enabled"
        }
        "camera-restricted" {
            $disabled = Invoke-AdbShell -Serial $Serial -Command "pm list packages -d" | Out-String
            $hasCamera = Invoke-AdbShell -Serial $Serial -Command "pm list packages | grep com.android.camera2" | Out-String
            $actual = "camera2 disabled = " + ($disabled -match "com.android.camera2")
            if ($disabled -match "com.android.camera2") { $result = "PASS" }
            $detail = "Requires camera package disabled via policy"
        }
        "security-patch" {
            $patch = Get-AdbProp $Serial "ro.build.version.security_patch"
            $baseline = "2024-03-01"
            $actual = "security_patch=$patch (baseline $baseline)"
            if ($patch -ge $baseline) { $result = "PASS" }
            $detail = "Requires security patch >= $baseline"
        }
        default {
            $result = "SKIP"
            $actual = "No probe defined"
        }
    }

    return [PSCustomObject]@{
        ruleId     = $Rule.id
        title      = $Rule.title
        severity   = $Rule.severity
        weight     = [int]$Rule.weight
        expected   = $Rule.expected
        actual     = $actual
        detail     = $detail
        result     = $result
    }
}

function Get-DeviceReport {
    param(
        [string]$Serial,
        [object]$Policy
    )
    $identity = Get-DeviceIdentity -Serial $Serial
    $battery = Get-BatteryState -Serial $Serial
    $storage = Get-StorageUsage -Serial $Serial
    $apps = Get-InstalledApps -Serial $Serial

    $checks = @()
    $score = 0.0
    $passWeight = 0
    $totalWeight = 0
    foreach ($rule in $Policy.rules) {
        $check = Get-ComplianceCheck -Serial $Serial -Rule $rule
        $checks += $check
        $totalWeight += $check.weight
        if ($check.result -eq "PASS") { $passWeight += $check.weight }
    }
    if ($totalWeight -gt 0) { $score = [math]::Round(($passWeight / $totalWeight) * 100, 1) }
    $status = if ($score -ge 100) { "COMPLIANT" } elseif ($score -ge 60) { "AT RISK" } else { "NON-COMPLIANT" }

    return [PSCustomObject]@{
        id          = ($identity.androidId.Substring(0, [Math]::Min(8, $identity.androidId.Length)) + "-" + $identity.model)
        enrolledAt  = "2026-07-01T09:00:00Z"
        lastCheckIn = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        identity    = $identity
        inventory   = [PSCustomObject]@{
            batteryLevel = $battery.level
            batteryHealth = $battery.health
            batteryStatus = $battery.status
            storageUsedGb = $storage.usedGb
            storageTotalGb = $storage.totalGb
            appCount     = $apps.Count
            apps         = $apps
        }
        compliance  = [PSCustomObject]@{
            score  = $score
            status = $status
            checks = $checks
        }
    }
}
