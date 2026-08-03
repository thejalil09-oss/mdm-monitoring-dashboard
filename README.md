# OrgLab MDM — Monitoring & Compliance Dashboard
> Semester Project — Network Monitoring, Security and Auditing (Cyber Labwork II)

**Author:** Sulemana Akuantu Abdul Jalil · **Index:** FCM.41.018.245.23 · **Team:** Blue
**Repository:** https://github.com/thejalil09-oss/mdm-monitoring-dashboard

A self-hosted Mobile Device Management (MDM) monitoring and compliance dashboard for an
Android device fleet, driven entirely through the Android Debug Bridge (ADB). It collects
live device state, scores each device against a standards-mapped security baseline
(CIS Android OS Benchmark / NIST SP 800-124), renders a web dashboard, and remediates
non-compliant devices through the same ADB channel.

![Fleet dashboard](evidence/screenshots/dashboard-full.png)

## Highlights

- **Two-device Android 13 emulator fleet** (`MDM-DeviceA` managed, `MDM-DeviceB` baseline)
- **8-rule weighted policy baseline** (`scripts/policies/policy.json`) mapped to CIS/NIST
- **PowerShell/ADB collection engine** (`scripts/adb/mdm.ps1` + `collect.ps1`)
  producing structured audit snapshots with per-rule evidence
- **Zero-dependency web dashboard** (`src/dashboard/`) — renders offline from `devices.js`
- **Remediation** (`scripts/adb/apply-policy.ps1`) with `-DryRun` and `-KeepAdb` modes
- **Demonstrated before/after:** Device A 45% → 85%; Device B baseline 25%

## Repository layout

```
mdm-dashboard/
  scripts/
    adb/mdm.ps1            # ADB module: probes, scoring, sqlite helper, root
    adb/collect.ps1        # fleet collector → devices.js + JSON snapshot
    adb/apply-policy.ps1   # remediation / enforcement (-DryRun, -KeepAdb)
    policies/policy.json   # OrgLab MDM Baseline v1.0
  src/dashboard/           # static dashboard (index.html, css, js, data/)
  docs/REPORT.html         # project report (print-ready)
  docs/REPORT.pdf          # 25-page PDF of the report
  evidence/screenshots/    # captured evidence
  evidence/logs/           # raw audit snapshots
```

## Quick start (lab environment)

1. Provision an Android 13 emulator fleet (system image `android-33;google_apis;x86_64`)
   and boot headless.
2. Confirm both serials appear in `adb devices`.
3. Collect and score:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\adb\collect.ps1
   ```

4. Open `src/dashboard/index.html` in a browser to view the fleet.
5. Remediate a device (keep ADB alive):

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\adb\apply-policy.ps1 -Serial emulator-5554 -KeepAdb
   ```

6. Full lockdown (severs the ADB session — expected):

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\adb\apply-policy.ps1 -Serial emulator-5554
   ```

## Compliance model

| ID | Control | Sev | W |
|----|---------|-----|---|
| `screen-lock-enabled` | Screen lock configured (locksettings.db) | high | 20 |
| `screen-lock-timeout` | Auto-lock ≤ 60 s | high | 15 |
| `encryption` | Storage encrypted at rest | high | 20 |
| `usb-debugging` | USB debugging disabled | high | 15 |
| `unknown-sources` | Unknown sources blocked / ADB verified | med | 10 |
| `verify-apps` | Application verification enabled | med | 5 |
| `camera-restricted` | Camera disabled by policy | med | 10 |
| `security-patch` | Security patch ≥ 2024-03-01 | high | 5 |

Status bands: COMPLIANT = 100% · AT RISK = 60–99% · NON-COMPLIANT < 60%

## Notes

- Root (`adb root`) is required to read `locksettings.db`; the lab uses userdebug
  emulator builds.
- Disabling USB debugging (`adb_enabled=0`) severs the ADB management channel — the
  expected outcome of the final lockdown, and the reason `-KeepAdb` exists for staging.
- Everything is redacted/synthetic; no production credentials are included.
