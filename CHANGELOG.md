# Changelog

## 0.1.1 - 2026-10-11

- Menu up / down / left / right can be bound to wheel buttons (for wheels whose d-pad is buttons, not a hat
  switch), with the same auto-repeat as the hat.
- README: compatibility table (verified vs expected devices, what differs between devices) and a
  "Device report" issue template.

## 0.1.0 - 2026-10-10

First public version, extracted from the Sonnet Drive project.

- WheelBridge (DirectInput): input for all game controllers, force feedback (constant / spring / damper /
  friction / sine) on the steering device, safety ramp / slew limit / watchdog, `--list` `--monitor` `--ffbtest`
  `--fake` tools.
- `WheelInput` autoload: per device + axis bindings with automatic calibration (inverted axes, load-cell brakes),
  buttons to InputMap actions, hat switch menu navigation, guided FFB direction test, bridge supervision
  (restarts a dead bridge, clears stale devices).
- `WheelSetupPanel` setup screen, `WheelFFBVehicle` helper for VehicleBody3D, demo and headless tests.
