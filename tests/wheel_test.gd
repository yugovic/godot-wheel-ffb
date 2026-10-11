extends Node3D
## Headless tests for the Wheel FFB addon. No hardware needed: --wheel-fake makes WheelBridge emulate a wheel
## (steering swings left/right, buttons, FFB) and pedals on its own port (49351).
##   godot --headless --path . res://tests/wheel_test.tscn -- --wheel-fake [--test=link|capture|pov|dirbtn|panel|revive|vehicle|all]
##   godot --headless --path . res://tests/wheel_test.tscn -- --test=real      (real devices: lists them, no FFB)

var _fails := 0
var _which := "all"
var _ui_events: Dictionary = {}
var _down_times: Array[float] = []
var _action_events := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--test="):
			_which = a.substr(7)
	await get_tree().process_frame
	if _which in ["all", "vehicle"]:
		await _test_vehicle()
	if _which in ["all", "link"]:
		await _test_link()
	if _which in ["all", "capture"]:
		await _test_capture()
	if _which in ["all", "pov"]:
		await _test_pov()
	if _which in ["all", "dirbtn"]:
		await _test_dirbtn()
	if _which in ["all", "panel"]:
		await _test_panel()
	if _which in ["all", "revive"]:
		await _test_revive()
	if _which == "real":
		await _test_real()
	WheelInput.stop_link()
	print("== %s (%d failures)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok  " if ok else "FAIL", msg])


## Waits in wall-clock time (the bridge runs in real time even when the test uses --fixed-fps).
func _wait_until(cond: Callable, secs: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t0) * 0.001 < secs:
		if cond.call():
			return true
		await get_tree().process_frame
	return cond.call()


func _input(event: InputEvent) -> void:
	if event is InputEventAction and event.is_pressed():
		var a := (event as InputEventAction).action
		_ui_events[a] = int(_ui_events.get(a, 0)) + 1
		if a == "ui_down":
			_down_times.append(Time.get_ticks_msec() * 0.001)
		if a == "test_action":
			_action_events += 1


func _need_fake() -> bool:
	if not WheelInput.fake:
		_check(false, "run with -- --wheel-fake")
		return false
	if WheelInput.bridge_missing:
		_check(false, "WheelBridge.exe not found (addons/wheel_ffb/bin)")
		return false
	if not WheelInput.link_enabled:
		WheelInput.set_link_enabled(true)
	elif not WheelInput.link_running():
		WheelInput.start_link()
	return await _wait_until(func(): return WheelInput.connected and WheelInput.devices.size() >= 2, 6.0)


# ------------------------------------------------------------------ VehicleBody3D helper
## A car on flat ground turning right must get a force that pulls the rim back to the left (negative).
func _test_vehicle() -> void:
	print("[vehicle] WheelFFBVehicle on a VehicleBody3D")
	var demo: Node3D = (load("res://demo/demo.gd") as GDScript).new()
	demo.set("panel", null)
	add_child(demo)
	# demo._ready builds world + car + UI; run its physics with scripted inputs instead of _physics_process
	demo.set_physics_process(false)
	await get_tree().physics_frame
	var car: VehicleBody3D = demo.get("car")
	var ffb: WheelFFBVehicle = demo.get("ffb")
	var run := func(steer_right: float, secs: float) -> Dictionary:
		var t0 := Time.get_ticks_msec()
		var sum := 0.0
		var cnt := 0
		var frames := int(secs * 120.0)
		for i in range(frames):
			var v := car.linear_velocity.length()
			car.engine_force = clampf((14.0 - v) * 900.0, 0.0, 2600.0)
			car.brake = 0.0
			car.steering = -steer_right * deg_to_rad(32.0)
			await get_tree().physics_frame
			ffb.update(car, 1.0 / 120.0)
			if i > frames / 2:
				sum += ffb.constant
				cnt += 1
		return {"con": sum / maxf(cnt, 1), "speed": car.linear_velocity.length(), "spring": ffb.spring}
	var still: Dictionary = await run.call(0.0, 0.05)
	_check(still["spring"] > 0.4, "standstill: centering spring %.2f" % still["spring"])
	var straight: Dictionary = await run.call(0.0, 3.0)
	_check(absf(straight["con"]) < 0.1, "straight: |constant| %.3f < 0.1 (%.1f m/s)" % [absf(straight["con"]), straight["speed"]])
	var right: Dictionary = await run.call(0.25, 3.0)
	_check(right["con"] < -0.1, "turning right pulls the rim LEFT (constant %+.3f)" % right["con"])
	var left: Dictionary = await run.call(-0.25, 4.0)
	_check(left["con"] > 0.1, "turning left pulls the rim RIGHT (constant %+.3f)" % left["con"])
	_check(absf(right["con"]) <= 1.0 and absf(left["con"]) <= 1.0, "within -1..1")
	demo.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------------ link
func _test_link() -> void:
	print("[link] WheelBridge --fake over UDP")
	if not await _need_fake():
		_check(false, "bridge connected")
		return
	WheelInput.debug_report()
	var wheel_id := "FAKE-0000-WHEEL"
	var pedal_id := "FAKE-0000-PEDAL"
	_check(WheelInput.device_present(wheel_id) and WheelInput.device_present(pedal_id), "virtual wheel and pedals found")
	_check(WheelInput.device_has_ffb(wheel_id), "virtual wheel reports FFB effects")
	WheelInput.begin_capture("steer")
	var done := await _wait_until(func(): return WheelInput.capture_kind == "", 12.0)
	# the virtual pedals keep cycling through their full travel, so the capture may pick a pedal axis here
	# (with real hardware only the wheel moves); check that a capture completes and records an axis
	_check(done and WheelInput.bindings.has("steer") and WheelInput.bindings["steer"].has("axis"), "steering capture completes and records an axis")
	WheelInput.bindings["steer"] = {"id": wheel_id, "axis": 0, "center": 0.0, "sign": 1.0}
	WheelInput.bindings["throttle"] = {"id": pedal_id, "axis": 0, "rest": -1.0, "full": 1.0}
	WheelInput.bindings["brake"] = {"id": pedal_id, "axis": 1, "rest": -1.0, "full": 1.0}
	WheelInput.wheel_range = 900.0
	WheelInput.lock_to_lock = 540.0
	var ok_steer := true
	var ok_ped := true
	for i in range(30):
		await _wait_until(func(): return false, 0.03)
		var raw := WheelInput.raw_axis(wheel_id, 0)
		if absf(WheelInput.steer_value() - clampf(raw * 450.0 / 270.0, -1.0, 1.0)) > 0.08:
			ok_steer = false
		var tr_raw := (WheelInput.raw_axis(pedal_id, 0) + 1.0) * 0.5
		if absf(WheelInput.pedal_value("throttle") - (0.0 if tr_raw < 0.02 else tr_raw)) > 0.08:
			ok_ped = false
	_check(ok_steer, "steer_value = wheel angle / lock (900 deg range, 540 deg lock to lock)")
	_check(ok_ped, "pedal calibration with an inverted axis (-1 = released)")
	# buttons -> InputMap actions (the virtual wheel presses button 0 every 6 s)
	if not InputMap.has_action("test_action"):
		InputMap.add_action("test_action")
	WheelInput.register_action("test_action", "Test action")
	WheelInput.begin_capture("btn:test_action")
	_check(await _wait_until(func(): return WheelInput.capture_kind == "", 9.0) and WheelInput.buttons.has("test_action"), "button captured")
	_action_events = 0
	await _wait_until(func(): return _action_events > 0, 8.0)
	_check(_action_events > 0, "a wheel button fires its InputMap action")
	# FFB passes through (checked in the bridge log)
	WheelInput.ffb_verified = true
	WheelInput.ffb_enabled = true
	WheelInput.ffb_gain = 0.5
	WheelInput.ffb_invert = false
	await _send_for(2.6, 0.5)
	WheelInput.ffb_invert = true
	await _send_for(1.6, 0.5)
	var log := FileAccess.get_file_as_string(OS.get_user_data_dir().path_join("wheel_bridge_fake.log"))
	_check(log.contains("con=0.50") and log.contains("con=-0.50") and log.contains("gain=0.50"), "FFB reaches the bridge (direction and strength)")
	WheelInput.ffb_enabled = false
	WheelInput.ffb_verified = false
	WheelInput.bindings.clear()
	WheelInput.buttons.clear()


func _send_for(secs: float, con: float) -> void:
	var t0 := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t0) * 0.001 < secs:
		WheelInput.send_ffb(con, 0.2, 0.1, 0.0, 0.3, 25.0)
		await get_tree().physics_frame


# ------------------------------------------------------------------ pedal capture (no bridge)
## A load-cell brake (Heusinkveld: a normal press moves the axis only 5-15 %) must still be assignable.
func _test_capture() -> void:
	print("[capture] pedal assignment incl. a load-cell brake")
	WheelInput.stop_link()
	var pid := "TEST-PEDALS"
	WheelInput.devices = [{"i": 0, "id": pid, "n": "Test Pedals", "ffb": 0, "fx": 0, "nb": 0, "ax": [0, 0, 0, 1, 1, 1, 0, 0]}]
	WheelInput._id_to_index = {pid: 0}
	WheelInput.bindings = {}
	var keep_link := WheelInput.link_enabled
	WheelInput.link_enabled = true
	WheelInput.connected = true
	var set_axes := func(rx: float, ry: float) -> void:
		WheelInput._axes[0] = PackedFloat32Array([0.0, 0.0, 0.0, rx, ry, -1.0, 0.0, 0.0])
		WheelInput._axes_time[0] = Time.get_ticks_msec() * 0.001
	var run := func(kind: String, rx_peak: float, ry_peak: float) -> void:
		set_axes.call(-1.0, -1.0)
		WheelInput.begin_capture(kind)
		var t0 := Time.get_ticks_msec()
		while WheelInput.capture_kind != "" and Time.get_ticks_msec() - t0 < 6000:
			var e := (Time.get_ticks_msec() - t0) / 1000.0
			var k := clampf((e - 0.3) / 0.6, 0.0, 1.0)
			set_axes.call(lerpf(-1.0, rx_peak, k), lerpf(-1.0, ry_peak, k))
			WheelInput._capture_step(Time.get_ticks_msec() * 0.001)
			await get_tree().process_frame
	await run.call("throttle", 1.0, -1.0)
	var th = WheelInput.bindings.get("throttle")
	_check(th != null and int(th["axis"]) == 3, "throttle -> Rx")
	await run.call("brake", -1.0, -0.70)
	var br = WheelInput.bindings.get("brake")
	_check(br != null and int(br["axis"]) == 4, "a brake moving 15% of the range is assigned (Ry)")
	if br != null:
		set_axes.call(-1.0, -0.85)
		_check(absf(WheelInput.pedal_value("brake") - 0.5) < 0.05, "half the assigned force reads 50%% (%.2f)" % WheelInput.pedal_value("brake"))
	WheelInput.bindings.erase("brake")
	set_axes.call(-1.0, -1.0)
	WheelInput.begin_capture("brake")
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 2500:
		set_axes.call(-1.0, -0.96)
		WheelInput._capture_step(Time.get_ticks_msec() * 0.001)
		await get_tree().process_frame
	_check(not WheelInput.bindings.has("brake"), "a 2% twitch assigns nothing")
	WheelInput.cancel_capture()
	WheelInput.bindings = {}
	WheelInput.devices = []
	WheelInput._axes.clear()
	WheelInput.connected = false
	WheelInput.link_enabled = keep_link


# ------------------------------------------------------------------ POV menu navigation
func _test_pov() -> void:
	print("[pov] menu navigation with the hat switch")
	var table := {-1: "", 0: "ui_up", 45: "ui_right", 90: "ui_right", 135: "ui_down", 180: "ui_down", 225: "ui_left", 270: "ui_left", 315: "ui_up", 360: ""}
	var ok_map := true
	for p: int in table.keys():
		ok_map = ok_map and WheelInput.pov_action(p) == table[p]
	_check(ok_map, "POV angle -> ui_up / ui_right / ui_down / ui_left")
	if not await _need_fake():
		_check(false, "bridge connected")
		return
	WheelInput.bindings["steer"] = {"id": "FAKE-0000-WHEEL", "axis": 0, "center": 0.0, "sign": 1.0}
	var layer := CanvasLayer.new()
	add_child(layer)
	var box := VBoxContainer.new()
	layer.add_child(box)
	var btns: Array[Button] = []
	for i in range(4):
		var b := Button.new()
		b.text = "ITEM %d" % i
		b.focus_mode = Control.FOCUS_ALL
		box.add_child(b)
		btns.append(b)
	await get_tree().process_frame
	btns[0].grab_focus()
	await get_tree().process_frame
	var focus := func() -> int: return btns.find(get_viewport().gui_get_focus_owner())
	_ui_events.clear()
	var t0 := Time.get_ticks_msec()
	var seen := 0.0
	while Time.get_ticks_msec() - t0 < 1500:
		seen = maxf(seen, absf(WheelInput.steer_value()))
		await get_tree().process_frame
	_check(seen > 0.02 and focus.call() == 0 and int(_ui_events.get("ui_left", 0)) + int(_ui_events.get("ui_right", 0)) == 0,
			"the steering axis never drives ui_left / ui_right")
	_ui_events.clear()
	WheelInput.pov_override = 180
	_check(await _wait_until(func(): return focus.call() == 1, 1.0), "hat down moves the focus")
	WheelInput.pov_override = -1
	await _wait_until(func(): return WheelInput.pov == -1, 1.0)
	await _wait_until(func(): return false, 0.5)
	_check(focus.call() == 1 and int(_ui_events.get("ui_down", 0)) == 1, "a short press moves exactly once")
	btns[0].grab_focus()
	await get_tree().process_frame
	_down_times.clear()
	WheelInput.pov_override = 180
	await _wait_until(func(): return false, 0.75)
	WheelInput.pov_override = -1
	await _wait_until(func(): return WheelInput.pov == -1, 1.0)
	var gaps := []
	for i in range(1, _down_times.size()):
		gaps.append(snappedf(_down_times[i] - _down_times[i - 1], 0.01))
	var ok_gaps := gaps.size() >= 2 and float(gaps[0]) >= 0.3 and float(gaps[0]) <= 0.5
	for i in range(1, gaps.size()):
		ok_gaps = ok_gaps and float(gaps[i]) >= 0.1 and float(gaps[i]) <= 0.2
	_check(ok_gaps, "holding repeats after 0.35 s, then every 0.12 s (gaps %s)" % str(gaps))
	WheelInput.pov_override = -2
	WheelInput.bindings.clear()
	layer.queue_free()


# ------------------------------------------------------------------ d-pad buttons (wheels without a hat switch)
func _test_dirbtn() -> void:
	print("[dirbtn] menu directions bound to buttons")
	if not await _need_fake():
		_check(false, "bridge connected")
		return
	WheelInput.buttons["ui_down"] = {"id": "FAKE-0000-WHEEL", "btn": 0}
	_ui_events.clear()
	_down_times.clear()
	# button 0 of the virtual wheel is held for ~1 s every 6 s
	await _wait_until(func(): return _down_times.size() > 0, 7.0)
	await _wait_until(func(): return not WheelInput.button_down("ui_down"), 2.0)
	var n := _down_times.size()
	var gaps := []
	for i in range(1, n):
		gaps.append(snappedf(_down_times[i] - _down_times[i - 1], 0.01))
	var ok := n >= 3 and float(gaps[0]) >= 0.3 and float(gaps[0]) <= 0.5
	for i in range(1, gaps.size()):
		ok = ok and float(gaps[i]) >= 0.1 and float(gaps[i]) <= 0.2
	_check(ok, "a held direction button repeats like the hat (%d presses, gaps %s)" % [n, str(gaps)])
	_ui_events.clear()
	await _wait_until(func(): return false, 1.0)
	_check(int(_ui_events.get("ui_down", 0)) == 0, "no repeats after release")
	WheelInput.buttons.erase("ui_down")


# ------------------------------------------------------------------ setup panel
func _test_panel() -> void:
	print("[panel] FFB test button in WheelSetupPanel")
	if not WheelInput.fake:
		_check(false, "run with -- --wheel-fake")
		return
	WheelInput.bindings.clear()
	WheelInput.set_link_enabled(false)
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := WheelSetupPanel.new()
	layer.add_child(panel)
	panel.open()
	await _wait_until(func(): return false, 0.3)
	var btn: Button = panel._test_btn
	_check(not btn.disabled and panel._test_note.text.contains("link is off"), "pressable while the link is off, and says why")
	btn.pressed.emit()
	_check(WheelInput.link_enabled, "pressing it turns the link on")
	await _wait_until(func(): return not panel._test_pending, 8.0)
	_check(WheelInput.ffb_test_phase == 0 and panel._hint.text.contains("Steering is not assigned"), "no steering -> asks for it: %s" % panel._hint.text)
	WheelInput.bindings["steer"] = {"id": "FAKE-0000-WHEEL", "axis": 0, "center": 0.0, "sign": 1.0}
	WheelInput.set_link_enabled(false)
	await _wait_until(func(): return false, 0.3)
	btn.pressed.emit()
	_check(await _wait_until(func(): return WheelInput.ffb_test_phase == 1, 8.0), "link off + steering assigned -> the test starts once the wheel is found")
	_check(await _wait_until(func(): return WheelInput.ffb_test_phase == 3, 6.0) and panel._ask.visible, "spring -> push right -> asks which way it pulled")
	WheelInput.finish_ffb_test(false)
	_check(WheelInput.ffb_verified and WheelInput.ffb_enabled and WheelInput.ffb_invert, "answer 'left' -> FFB on, direction inverted")
	WheelInput.ffb_verified = false
	WheelInput.ffb_enabled = false
	WheelInput.ffb_invert = false
	WheelInput.bindings.clear()
	WheelInput.save_cfg()
	layer.queue_free()


# ------------------------------------------------------------------ bridge supervision
func _test_revive() -> void:
	print("[revive] bridge supervision")
	if not await _need_fake():
		_check(false, "bridge connected")
		return
	var old_pid := WheelInput.bridge_pid
	OS.kill(old_pid)
	_check(await _wait_until(func(): return WheelInput.devices.is_empty(), 3.0), "the stale device list is cleared when the bridge dies")
	_check(await _wait_until(func(): return WheelInput.connected and WheelInput.devices.size() >= 2, 6.0) and WheelInput.bridge_pid != old_pid,
			"a new bridge is started and connects by itself")
	for i in range(3):
		WheelInput.set_link_enabled(false)
		WheelInput.set_link_enabled(true)
	_check(await _wait_until(func(): return WheelInput.connected and WheelInput.devices.size() >= 2, 8.0), "quick off -> on x3 still ends connected")


# ------------------------------------------------------------------ real devices
func _test_real() -> void:
	print("[real] DirectInput devices through WheelBridge")
	_check(not WheelInput.fake, "run without --wheel-fake")
	_check(not WheelInput.bridge_missing, "WheelBridge.exe found")
	_check(await _wait_until(func(): return WheelInput.connected, 6.0), "bridge connected")
	await _wait_until(func(): return WheelInput.devices.size() > 0, 3.0)
	WheelInput.debug_report()
