# Settings Backup & Restore

Settings → Trio Backup → **Backup & Restore**.

## What is in a backup

One JSON file (`Trio-Backup-<UTC timestamp>-<kind>.json`, format id `org.nightscout.trio.settings-backup`, version 1) with the
settings files exactly as Trio keeps them (mg/dL, actual insulin units):

| Part | Source |
|---|---|
| `settings` | `freeaps/freeaps_settings.json` (TrioSettings) |
| `preferences` | `preferences.json` (oref) |
| `pumpSettings` | `settings/settings.json` (max bolus, max basal, DIA) |
| `basalProfile`, `insulinSensitivities`, `carbRatios`, `bgTargets` | `settings/*.json` |
| `extras` | small UserDefaults values (FPU insulin share of the meal types) |
| `overridePresets`, `tempTargetPresets` | Core Data `OverrideStored` / `TempTargetStored` with `isPreset` |
| `sealed` | only with a backup password: pump pairing and passwords, encrypted (below) |

Not included: CGM pairing, Tidepool login, Core Data history.

## Password-protected part (`sealed`)

With a backup password (Keychain key `backup.password`, at least 8 characters) every backup carries
`SettingsBackupPrivate` as JSON, encrypted with AES-256-GCM. The key comes from PBKDF2-HMAC-SHA256 (310 000 rounds, 16 byte
random salt, both stored next to the ciphertext). Contents:

- `pumpManagerState`: `PumpManager.rawValue` as a binary property list, plus the pump name. It contains the pod's keys,
  which is why it is never written without encryption.
- Nightscout URL and API secret, API keys of the AI providers.

The restore sheet asks for the password; only then the sections `passwords` and `pumpPairing` appear (passwords
pre-selected, pump pairing never).

### Pump pairing rules

- Only when no pump is set up (`pumpAlreadySetUp`): a working pairing is never replaced.
- Only when the insulin concentration on this iPhone equals the one in the backup (`pumpConcentrationMismatch`): the pod
  holds the insulin of the backup time; with another setting every dose would be off by that factor.
- Restored first, through `DeviceDataManager.restorePumpManager(rawValue:)` (same path as pump setup), then basal and
  limits are written to it.
- The sheet shows the age of the state and warns: insulin delivered since the backup is unknown (IOB may be too low), and
  a stale Omnipod state may no longer talk to the pod.

## Presets

Merged by name (trimmed, case-insensitive): a preset with the same name is updated, others are appended at the end of the
order. Restored rows are never enabled; running overrides and temp targets are copies and are not touched.

## Where

- `Documents/Backups` on the iPhone (visible in the Files app, Trio has `UIFileSharingEnabled`).
- Optionally a copy in a folder the user picks (security-scoped bookmark), e.g. iCloud Drive.

Retention: 5 automatic, 3 "before restore", manual backups are only deleted by the user.

## Automatic cycle

`BaseBackupManager` checks after every loop cycle (`lastLoopDateSubject`, also runs in the background), on
`didBecomeActive` and 60 s after launch. A backup is made when the last automatic one is at least 7 days old.

## Restore

1. Only the selected parts that exist in the file; validation against the editor ranges (`validationIssues`).
2. Refused while a bolus runs, or when the basal rates are not deliverable at the current insulin concentration.
3. Pump pairing checks (see above) also come before any change.
4. A "before restore" backup of the current state is written first; if that fails nothing is changed.
5. Delivery limits and basal schedule go to the pump first and are saved only when the pump accepted them
   (order chosen so the pump never holds a schedule above its max basal).
6. Then ISF, carb ratios, targets, preferences, app settings, presets and passwords; observers are notified and the
   profile is uploaded to Nightscout.

Never restored (device/insulin bound): insulin concentration and its pending flag, dosing mode, CGM selection, bolus increment.
