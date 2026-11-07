# Yale Conexis Z-Wave Lock (Battery Poll)

A SmartThings Edge driver for the Yale Conexis L1/L2 with the Yale Z-Wave module
(`0x0129 / 0x6600 / 0x0002`). It is the stock `zwave-lock` driver with the
following additions; everything else (lock/unlock, lock codes, users,
credentials, tamper, refresh) behaves as stock.

## What it adds

- **Battery polling** – the lock never sends battery reports on its own, so the
  driver sends a Battery Get 30 s after start-up and then every *n* hours
  (setting: *Battery check interval*, default 6).
- **Tamper alerts** – the Conexis uses the `base-lock-tamper` profile, so the
  wrong-tag lockout alarm (161) is shown. Existing devices are moved over on start-up.
- **Lock settings** – beep volume, auto relock, auto relock delay, wrong tag
  limit and lockout time (Configuration parameters 1, 2, 3, 4, 7, per the
  Z-Wave JS config for this product). Values are read and logged at start-up
  and only written when you change a setting. Parameter 2 did not answer on an L2.
- **Tag unlocks** – Yale alarm 144 becomes an `rfid` unlock with the tag slot,
  optionally named via the *Tag names* setting (`3=Alex, 1=Sam`).
- **Readable History** – a custom capability, `aboutartist00260.lockActivity`,
  records "Unlocked by Alex", "Unlocked by SmartThings", "Locked Manually",
  "Locked Automatically" and so on, with the standard lock entries hidden from History.

## How lock events are worked out

The lock sends a plain Door Lock Operation Report about a second before the
alarm report that says how it was operated (21/22 handle, 24/25 remote,
27 auto-relock, 144 tag). The driver holds the plain event for 2 s so the
detailed one can replace it. If no alarm follows within 20 s of a lock or
unlock command the driver sent itself, the event is attributed to SmartThings.

## Custom capability

`aboutartist00260.lockActivity` lives in the author's SmartThings namespace.
To use this driver in another account, create an equivalent capability
(see `capabilities/lockActivity.yaml`; History template
`{{device.label}}: {{value}}`) and update the ID in `profiles/base-lock-tamper.yml`
and `src/yale_conexis.lua`.

## Tests

Run from `src/` with Lua 5.3 and the SmartThings Lua libraries on `LUA_PATH`,
as in `.github/workflows/run-tests.yml`; Yale-specific tests are in
`src/test/test_yale_conexis.lua`.
