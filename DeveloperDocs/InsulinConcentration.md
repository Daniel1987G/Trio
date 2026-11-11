# Insulin concentration (U100 / U200)

Settings → Therapy → Insulin Concentration lets the user declare that the pump is filled with
U200 insulin. Pump drivers are volumetric and always assume U100 (1 pump unit = 10 µl), so with
U200 one pump unit contains 2 units of insulin.

## Invariant

**Everything inside Trio is in actual insulin units** (what a U100 user sees): settings, basal
profile, limits, determinations, pump history in Core Data, IOB/COB, TDD, reservoir, Nightscout,
Tidepool, HealthKit, Watch, Live Activity.

Conversion happens **only at the `PumpManager` boundary**, in
`Trio/Sources/APS/Extensions/PumpManager+InsulinConcentration.swift`:

| Direction | What | Helper |
|---|---|---|
| Trio → pump (÷ factor) | bolus, SMB, temp basal | `enactBolus(actualUnits:…)`, `enactTempBasal(actualUnitsPerHour:…)` |
| | basal schedule | `syncBasalRateSchedule(actualItems:…)` |
| | delivery limits | `syncDeliveryLimits(actualLimits:…)` (result capped at the request for U200) |
| | pump setup (new pod/patch) | converted in `PumpConfig.PumpSetupView` |
| pump → Trio (× factor) | pump events / doses | `NewPumpEvent.convertedFromPump` in `DeviceDataManager.hasNewPumpEvents` |
| | reservoir | `DeviceDataManager` (all reservoir paths) |
| | running temp basal | `BaseAPSManager` current-temp lookup |
| | deliverable increments, rounding | `supportedBasalRates/BolusVolumes(concentration:)`, `roundTo…(actual…:concentration:)` |

**Rule:** outside that file, never call `enactBolus(units:)`, `enactTempBasal(unitsPerHour:)`,
`syncBasalRateSchedule(items:)`, `syncDeliveryLimits(limits:)`, `roundToSupported…`,
`supportedBasalRates` or `supportedBolusVolumes` on a pump manager directly. Quick check:

```sh
grep -rn "roundToSupportedBolusVolume(units\|roundToSupportedBasalRate(unitsPerHour\|\.supportedBasalRates\b\|\.supportedBolusVolumes\b\|syncDeliveryLimits(limits\|syncBasalRateSchedule(items\|enactBolus(units\|enactTempBasal(unitsPerHour" Trio/Sources --include=*.swift
```

Only `PumpManager+InsulinConcentration.swift` (and `profile.supportedBasalRates` inside the
algorithm, which is already in actual units) may show up.

Only power-of-two factors are offered: × 2 / ÷ 2 is exact in binary floating point, so pump
rate tables never lose an increment to rounding error.

## Changing the concentration

`InsulinConcentrationSettings.Provider.apply`:

1. Refuses (nothing changed) while a bolus runs or without a basal profile.
2. Persists the new concentration **first** – the user confirmed the pump now holds that insulin,
   so any concurrent loop cycle must already use the new factor – and sets
   `pumpInsulinConcentrationSyncPending`.
3. Cancels a running temp basal (it was commanded in the old pump units).
4. Rewrites delivery limits and basal schedule on the pump (limits first when pump-side values grow).
5. Clears the pending flag. On failure the flag stays set: the settings screen shows a warning
   with "Update Pump", the home reservoir badge shows `U200!`.

## Known limits

- Pump-driver screens (pod/patch settings, reservoir there, boluses entered on the pump itself)
  show pump units – they live in the submodules.
- Mutable/in-flight pump events re-reported after a concentration change are converted with the
  new factor. Change the concentration with a new pod/reservoir and no bolus running.
