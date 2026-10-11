extends Node
## Steering wheel + pedals input and force feedback for Godot (Windows, DirectInput).
## Registered as the autoload "WheelInput" by the Wheel FFB plugin.
##
## WheelBridge.exe (addons/wheel_ffb/bin) reads every DirectInput game controller and plays force-feedback
## effects; this node talks to it over localhost UDP. Bindings are "device id + axis", so a wheel base and
## separate pedals (e.g. Simagic + Heusinkveld) work together.
##   steer             : {id, axis, center, sign}   center = value at straight ahead, sign = +1 if turning right increases it
##   throttle / brake  : {id, axis, rest, full}     value released / fully pressed (inverted axes are handled)
##
## Menu navigation: the wheel's POV hat is sent as ui_up / ui_right / ui_down / ui_left (auto-repeat after
## 0.35 s, then every 0.12 s). Wheels whose d-pad reports buttons instead of a hat can bind those buttons to
## the same four directions (same auto-repeat). Buttons can also be bound to ui_accept / ui_cancel and to any
## InputMap action the game registers with register_action(). Joypad events Godot itself generates for bound devices are dropped,
## so the wheel does not also act as a gamepad.
##
## Nothing happens when the bridge or a wheel is missing: keyboard and gamepads keep working.

signal devices_changed
signal capture_finished(kind: String, ok: bool)
signal ffb_test_changed(phase: int)

const PORT := 49321
const PORT_FAKE := 49351             # virtual test devices use another port, so tests never talk to a running game's bridge
const CONFIG_PATH := "user://wheel_ffb.cfg"
const BRIDGE_RES_PATH := "res://addons/wheel_ffb/bin/WheelBridge.exe"
const AXIS_NAMES: Array[String] = ["X", "Y", "Z", "Rx", "Ry", "Rz", "S0", "S1"]
const MENU_ACTIONS: Array[String] = ["ui_accept", "ui_cancel", "ui_up", "ui_down", "ui_left", "ui_right"]
const DIRECTION_ACTIONS: Array[String] = ["ui_up", "ui_down", "ui_left", "ui_right"]
const POV_REPEAT_FIRST := 0.35
const POV_REPEAT_NEXT := 0.12

# --- settings (saved to config_path) ----------------------------------------
var link_enabled := true            # launch and use the bridge
var ffb_enabled := false            # stays off until the direction test has been answered
var ffb_verified := false           # the force direction was confirmed with the FFB test
var ffb_gain := 0.3                 # overall strength 0..1 (conservative default for high-torque direct drives)
var ffb_invert := false             # flip the force direction
var ffb_damper := 1.0               # multipliers for damper / spring / vibration
var ffb_spring := 1.0
var ffb_vibration := 1.0
var wheel_range := 900.0            # rotation range set in the wheel's own software (degrees, lock to lock)
var lock_to_lock := 540.0           # the game's lock to lock (degrees); smaller = quicker steering
var steer_gamma := 1.0              # 1 = linear, > 1 = softer around the centre
var bindings: Dictionary = {}       # "steer" / "throttle" / "brake" -> see above
var buttons: Dictionary = {}        # action -> {id, btn}

## Actions that can be bound to wheel buttons, in display order: action -> [label, hint].
## Games add their own with register_action().
var action_labels: Dictionary = {
	"ui_accept": ["Accept", "Press the focused menu button"],
	"ui_cancel": ["Back", "Close a menu / go back"],
	"ui_up": ["Menu up", "Only for d-pads that are buttons (a hat switch works without this)"],
	"ui_down": ["Menu down", ""],
	"ui_left": ["Menu left", ""],
	"ui_right": ["Menu right", ""],
}

# --- runtime state ----------------------------------------------------------
var devices: Array = []             # [{i, id, n, vid, pid, ffb, fx, nb, ax}] as reported by the bridge
var connected := false              # state packets arrived recently
var bridge_missing := false
var bridge_pid := -1
var fake := false                   # --wheel-fake: virtual devices for tests
var config_path := CONFIG_PATH
var port := PORT
var link_problem := ""              # human readable link trouble ("" = fine)
var _cfg_link := true               # link value that is saved (a temporary --no-wheel is not)

var _udp: PacketPeerUDP
var _last_state := -10.0
var _last_hello := -10.0
var _link_started := -10.0
var _proc_check := 0.0
var _restart_at := -1.0
var _restarts := 0
var _axes: Dictionary = {}          # device index -> PackedFloat32Array (-1..1)
var _axes_time: Dictionary = {}
var _bits: Dictionary = {}          # device index -> hex string of button bits
var _id_to_index: Dictionary = {}
var _btn_prev: Dictionary = {}
var _btn_repeat: Dictionary = {}   # direction action held on a button -> next repeat time (s)
var _devs_sig := ""

var pov := -1                       # POV of the steering device in degrees (-1 = centred)
var pov_override := -2              # tests: >= -1 replaces the device POV
var _pov_action := ""
var _pov_next := 0.0

var capture_kind := ""              # "" / "steer" / "throttle" / "brake" / "btn:<action>"
var capture_hint := ""
var _cap_base: Dictionary = {}
var _cap_ext: Dictionary = {}
var _cap_first := -1.0
var _cap_start := 0.0

var ffb_test_phase := 0             # 0 none / 1 spring / 2 push right / 3 waiting for the answer
var _ffb_test_t := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	fake = "--wheel-fake" in args
	if fake:
		config_path = "user://wheel_ffb_fake.cfg"
		port = PORT_FAKE
	for a in args:
		if a.begins_with("--wheel-config="):
			config_path = a.substr(15)
	load_cfg()
	_cfg_link = link_enabled
	if "--no-wheel" in args:
		link_enabled = false
	if link_enabled:
		start_link()


func _exit_tree() -> void:
	stop_link()


## Lets a wheel button trigger an InputMap action. Call once at startup (e.g. from your game's _ready).
func register_action(action: String, label: String, hint: String = "") -> void:
	action_labels[action] = [label, hint]


func button_actions() -> Array[String]:
	var out: Array[String] = []
	for k: String in action_labels.keys():
		out.append(k)
	return out


# ------------------------------------------------------------------ bridge process / UDP
func bridge_path() -> String:
	if OS.get_name() != "Windows":
		return ""
	var exe_dir := OS.get_executable_path().get_base_dir()
	var cands: Array[String] = [
		exe_dir.path_join("WheelBridge.exe"),                                   # exported game: copy it next to the .exe
		ProjectSettings.globalize_path(BRIDGE_RES_PATH),                         # running from the editor / source
		exe_dir.path_join("addons/wheel_ffb/bin/WheelBridge.exe"),
	]
	for p in cands:
		if FileAccess.file_exists(p):
			return p
	return ""


func start_link() -> void:
	if _udp != null:
		return
	var exe := bridge_path()
	bridge_missing = exe == ""
	if bridge_missing:
		return
	var log_name := "wheel_bridge_fake.log" if fake else "wheel_bridge.log"
	var args := PackedStringArray(["--serve", "--port", str(port), "--parent", str(OS.get_process_id()), "--log", OS.get_user_data_dir().path_join(log_name)])
	if fake:
		args.append("--fake")
	bridge_pid = OS.create_process(exe, args)
	_link_started = Time.get_ticks_msec() * 0.001
	_proc_check = _link_started
	_udp = PacketPeerUDP.new()
	_udp.connect_to_host("127.0.0.1", port)
	_send("hello")


func stop_link() -> void:
	if _udp != null:
		_send("quit")
		_udp.close()
		_udp = null
	connected = false
	bridge_pid = -1
	_restart_at = -1.0
	_forget_devices()
	_set_pov(-1, 0.0)


func link_running() -> bool:
	return _udp != null


func set_link_enabled(on: bool) -> void:
	link_enabled = on
	_cfg_link = on
	_restarts = 0
	link_problem = ""
	if on:
		start_link()
	else:
		stop_link()
	save_cfg()


func _send(text: String) -> void:
	if _udp != null:
		_udp.put_packet(text.to_utf8_buffer())


func _process(delta: float) -> void:
	var t := Time.get_ticks_msec() * 0.001
	if _udp == null:
		if _restart_at > 0.0 and t >= _restart_at and link_enabled:
			_restart_at = -1.0
			start_link()
		return
	_watch_bridge(t)
	if _udp == null:
		return
	if t - _last_hello > 0.5:
		_last_hello = t
		_send("hello")
	while _udp.get_available_packet_count() > 0:
		var txt := _udp.get_packet().get_string_from_utf8()
		var d = JSON.parse_string(txt)
		if d is Dictionary:
			_handle(d, t)
	connected = t - _last_state < 0.5
	if connected:
		_restarts = 0
		link_problem = ""
	elif not devices.is_empty() and t - maxf(_last_state, _link_started) > 2.0:
		# no state for 2 s: do not keep showing the last device list as "detected"
		_forget_devices()
		link_problem = "Lost contact with the wheel bridge. Reconnecting..."
	if capture_kind != "":
		_capture_step(t)
	_pov_step(t)
	_button_repeat_step(t)
	_test_step(delta)


## Checks the bridge process every second. If it is gone (could not get its port, was killed, ...)
## the device list is cleared and the bridge is restarted after 1 s (up to 5 times in a row).
func _watch_bridge(t: float) -> void:
	if bridge_pid <= 0 or t - _proc_check < 1.0:
		return
	_proc_check = t
	if OS.is_process_running(bridge_pid):
		return
	_udp.close()
	_udp = null
	bridge_pid = -1
	connected = false
	_forget_devices()
	cancel_capture()
	if _restarts < 5:
		_restarts += 1
		_restart_at = t + 1.0
		link_problem = "The wheel bridge stopped. Restarting... (attempt %d)" % _restarts
	else:
		link_problem = "Cannot start the wheel bridge. Turn the link off and on again (log: user://wheel_bridge.log)."


func _forget_devices() -> void:
	if devices.is_empty() and _axes.is_empty():
		return
	devices = []
	_id_to_index.clear()
	_axes.clear()
	_axes_time.clear()
	_bits.clear()
	_devs_sig = ""
	devices_changed.emit()


func _handle(d: Dictionary, t: float) -> void:
	match str(d.get("t", "")):
		"devs":
			devices = d.get("d", [])
			_id_to_index.clear()
			var sig := ""
			for dv in devices:
				_id_to_index[str(dv["id"])] = int(dv["i"])
				sig += "%s|%s|%s;" % [dv["id"], dv["n"], dv.get("ffb", 0)]
			if sig != _devs_sig:
				_devs_sig = sig
				devices_changed.emit()
		"s":
			_last_state = t
			var si := steer_device_index()
			var seen := false
			for e in d.get("d", []):
				var i := int(e["i"])
				var a: Array = e["a"]
				var arr := PackedFloat32Array()
				arr.resize(8)
				for k in range(mini(a.size(), 8)):
					arr[k] = clampf(float(a[k]) / 32768.0, -1.0, 1.0)
				_axes[i] = arr
				_axes_time[i] = t
				_bits[i] = str(e.get("b", ""))
				_buttons_changed(i)
				if i == si:
					seen = true
					_set_pov(int(e.get("p", -1)) if pov_override < -1 else pov_override, t)
			# the steering device stopped reporting: release a held hat direction
			if not seen:
				_set_pov(-1, t)


# ------------------------------------------------------------------ values
func device_name(id: String) -> String:
	for dv in devices:
		if str(dv["id"]) == id:
			return str(dv["n"])
	return ""


func device_present(id: String) -> bool:
	return _id_to_index.has(id)


## Raw axis value -1..1, or INF when the device is absent or stale.
func raw_axis(id: String, axis: int) -> float:
	if not _id_to_index.has(id):
		return INF
	var i: int = _id_to_index[id]
	if not _axes.has(i) or Time.get_ticks_msec() * 0.001 - float(_axes_time.get(i, -10.0)) > 0.5:
		return INF
	return (_axes[i] as PackedFloat32Array)[clampi(axis, 0, 7)]


func has_binding(fn: String) -> bool:
	if not link_enabled or not connected or not bindings.has(fn):
		return false
	return raw_axis(str(bindings[fn]["id"]), int(bindings[fn]["axis"])) != INF


## True when a wheel is bound and reporting: use steer_value() instead of your keyboard / pad steering.
func steer_active() -> bool:
	return has_binding("steer")


func has_pedals() -> bool:
	return has_binding("throttle") and has_binding("brake")


## Steering -1..1, right positive, mapped from the wheel's rotation range to the game's lock to lock.
## -1 / +1 means the car's full lock. Apply it 1:1 (no smoothing or rate limit) for a real wheel feel.
func steer_value() -> float:
	if not has_binding("steer"):
		return 0.0
	var b: Dictionary = bindings["steer"]
	var x := raw_axis(str(b["id"]), int(b["axis"]))
	var v := (x - float(b["center"])) * float(b["sign"])
	var out := clampf(v * wheel_range * 0.5 / (lock_to_lock * 0.5), -1.0, 1.0)
	if steer_gamma != 1.0:
		out = signf(out) * pow(absf(out), steer_gamma)
	return out


## Pedal 0..1 ("throttle" / "brake").
func pedal_value(fn: String) -> float:
	if not has_binding(fn):
		return 0.0
	var b: Dictionary = bindings[fn]
	var x := raw_axis(str(b["id"]), int(b["axis"]))
	var span := float(b["full"]) - float(b["rest"])
	if absf(span) < 0.05:
		return 0.0
	var v := clampf((x - float(b["rest"])) / span, 0.0, 1.0)
	return 0.0 if v < 0.02 else v


func button_down(action: String) -> bool:
	if not buttons.has(action):
		return false
	var b: Dictionary = buttons[action]
	return _bit(str(b["id"]), int(b["btn"]))


func _bit(id: String, n: int) -> bool:
	if not _id_to_index.has(id):
		return false
	var i: int = _id_to_index[id]
	var s: String = _bits.get(i, "")
	var ci := floori(n / 4.0)
	if ci >= s.length():
		return false
	var v := "0123456789abcdef".find(s[ci])
	return v >= 0 and (v >> (n % 4)) & 1 == 1


## Bound buttons are sent as InputMap actions, so the game's existing input handling just works.
func _buttons_changed(i: int) -> void:
	if capture_kind.begins_with("btn:"):
		return
	for action: String in buttons.keys():
		var b: Dictionary = buttons[action]
		if not _id_to_index.has(str(b["id"])) or int(_id_to_index[str(b["id"])]) != i:
			continue
		var now := _bit(str(b["id"]), int(b["btn"]))
		var key := "%s:%d" % [b["id"], int(b["btn"])]
		var was: bool = _btn_prev.get(key, false)
		if now != was:
			_btn_prev[key] = now
			if InputMap.has_action(action):
				_send_action(action, now)
			if action in DIRECTION_ACTIONS:
				if now:
					_btn_repeat[action] = Time.get_ticks_msec() * 0.001 + POV_REPEAT_FIRST
				else:
					_btn_repeat.erase(action)


func _send_action(action: String, pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)


## POV angle (degrees, 0 = up, clockwise) -> menu direction.
func pov_action(p: int) -> String:
	if p < 0 or p >= 360:
		return ""
	if p >= 315 or p < 45:
		return "ui_up"
	if p < 135:
		return "ui_right"
	if p < 225:
		return "ui_down"
	return "ui_left"


func _set_pov(p: int, t: float) -> void:
	pov = p
	var act := pov_action(p) if capture_kind == "" else ""
	if act == _pov_action:
		return
	if _pov_action != "":
		_send_action(_pov_action, false)
	_pov_action = act
	if act != "":
		_send_action(act, true)
		_pov_next = t + POV_REPEAT_FIRST


func _pov_step(t: float) -> void:
	if _pov_action == "":
		return
	if not connected or capture_kind != "":
		_set_pov(-1, t)
	elif t >= _pov_next:
		_pov_next = t + POV_REPEAT_NEXT
		_send_action(_pov_action, true)


## Direction buttons held down repeat like the hat switch (released when the link drops or during a capture).
func _button_repeat_step(t: float) -> void:
	if _btn_repeat.is_empty():
		return
	if not connected or capture_kind != "":
		for a: String in _btn_repeat.keys():
			_send_action(a, false)
		_btn_repeat.clear()
		return
	for a: String in _btn_repeat.keys():
		if t >= float(_btn_repeat[a]):
			_btn_repeat[a] = t + POV_REPEAT_NEXT
			_send_action(a, true)


## Drop Godot's own joypad events from bound devices (otherwise the wheel also acts as a gamepad).
func _input(event: InputEvent) -> void:
	if not (event is InputEventJoypadMotion or event is InputEventJoypadButton):
		return
	if not link_enabled or not connected:
		return
	var nm := Input.get_joy_name(event.device).to_lower()
	if nm == "":
		return
	for fn: String in bindings.keys():
		var dn := device_name(str(bindings[fn]["id"])).to_lower()
		if dn != "" and (nm == dn or nm.contains(dn) or dn.contains(nm)):
			get_viewport().set_input_as_handled()
			return


# ------------------------------------------------------------------ assignment (capture)
## kind: "steer" / "throttle" / "brake" / "btn:<action>". Finishes by itself (capture_finished).
func begin_capture(kind: String) -> void:
	capture_kind = kind
	_cap_ext.clear()
	_cap_first = -1.0
	_cap_start = Time.get_ticks_msec() * 0.001
	_cap_base.clear()
	for dv in devices:
		var id := str(dv["id"])
		var arr := PackedFloat32Array()
		arr.resize(8)
		for k in range(8):
			var x := raw_axis(id, k)
			arr[k] = 0.0 if x == INF else x
		_cap_base[id] = arr
	for k in _btn_prev.keys():
		_btn_prev[k] = false
	match kind:
		"steer":
			capture_hint = "Keep the wheel centred, then turn it fully to the RIGHT and back to the centre."
		"throttle":
			capture_hint = "Press the throttle pedal all the way down."
		"brake":
			# load-cell brakes (e.g. Heusinkveld) report force, not travel: a normal press may move only 5-15 % of the axis
			capture_hint = "Press the brake with the force you use for hard braking and hold it for 2 s (that force becomes 100 %)."
		_:
			capture_hint = "Press the button you want to use."


func cancel_capture() -> void:
	if capture_kind != "":
		var k := capture_kind
		capture_kind = ""
		capture_finished.emit(k, false)


func _capture_step(t: float) -> void:
	if t - _cap_start > 20.0:
		cancel_capture()
		return
	if capture_kind.begins_with("btn:"):
		for dv in devices:
			var id := str(dv["id"])
			for n in range(int(dv["nb"])):
				if _bit(id, n):
					var action := capture_kind.substr(4)
					buttons[action] = {"id": id, "btn": n}
					capture_kind = ""
					_btn_prev["%s:%d" % [id, n]] = true
					save_cfg()
					capture_finished.emit("btn:" + action, true)
					return
		return
	# axes: the axis that moved the most from where it was when the capture started
	var best_key := ""
	var best_dev := 0.0
	for dv in devices:
		var id := str(dv["id"])
		var base: PackedFloat32Array = _cap_base.get(id, PackedFloat32Array())
		if base.is_empty():
			continue
		for k in range(8):
			if capture_kind != "steer" and bindings.has("steer") and str(bindings["steer"]["id"]) == id and int(bindings["steer"]["axis"]) == k:
				continue
			var x := raw_axis(id, k)
			if x == INF:
				continue
			var dev := x - base[k]
			var key := "%s:%d" % [id, k]
			if absf(dev) > absf(float(_cap_ext.get(key, 0.0))):
				_cap_ext[key] = dev
			if absf(float(_cap_ext.get(key, 0.0))) > best_dev:
				best_dev = absf(float(_cap_ext[key]))
				best_key = key
	# steering: 10 % of the range; pedals: 4 % (pedal axes are noise free at rest, load cells move little)
	var thr := 0.2 if capture_kind == "steer" else 0.08
	if best_key == "":
		return
	if best_dev > thr and _cap_first < 0.0:
		_cap_first = t
	# after the first movement, follow the extreme for a moment (full lock / full press)
	if _cap_first > 0.0 and t - _cap_first > (1.2 if capture_kind == "steer" else 2.0):
		var parts := best_key.rsplit(":", true, 1)
		var id := parts[0]
		var axis := int(parts[1])
		var base2: PackedFloat32Array = _cap_base[id]
		var ext := float(_cap_ext[best_key])
		if capture_kind == "steer":
			bindings["steer"] = {"id": id, "axis": axis, "center": base2[axis], "sign": 1.0 if ext >= 0.0 else -1.0}
		else:
			bindings[capture_kind] = {"id": id, "axis": axis, "rest": base2[axis], "full": clampf(base2[axis] + ext, -1.0, 1.0)}
		var k2 := capture_kind
		capture_kind = ""
		save_cfg()
		capture_finished.emit(k2, true)


# ------------------------------------------------------------------ force feedback
func steer_device_index() -> int:
	if not bindings.has("steer"):
		return -1
	return int(_id_to_index.get(str(bindings["steer"]["id"]), -1))


func device_has_ffb(id: String) -> bool:
	for dv in devices:
		if str(dv["id"]) == id:
			return int(dv.get("fx", 0)) == 1
	return false


## Why force feedback (and its test) cannot run right now, or "" when it can:
##   "missing" / "link_off" / "connecting" / "no_steer" / "steer_absent" / "no_ffb" / "busy"
func ffb_block_reason() -> String:
	if bridge_missing:
		return "missing"
	if not link_enabled:
		return "link_off"
	if not link_running() or not connected or devices.is_empty():
		return "connecting"
	if not bindings.has("steer"):
		return "no_steer"
	var id := str(bindings["steer"]["id"])
	for dv in devices:
		if str(dv["id"]) == id:
			if int(dv.get("ffb", 0)) != 1:
				return "no_ffb"
			if int(dv.get("fx", 0)) != 1:
				return "busy"
			return "" if steer_active() else "connecting"
	return "steer_absent"


func ffb_available() -> bool:
	return steer_active() and device_has_ffb(str(bindings["steer"]["id"]))


## Send the force feedback for this frame (call every physics frame while driving).
##   constant  -1..1  force on the rim, RIGHT positive (self-aligning torque: negative while turning right)
##   spring     0..1  centering spring (useful at low speed)
##   damper     0..1  resistance to rim speed
##   friction   0..1
##   vibration  0..1  with vibration_ms the period (kerbs, gravel, impacts)
## Overall strength (ffb_gain), direction (ffb_invert) and the user's multipliers are applied here.
## Nothing is sent until the user has confirmed the direction with the FFB test.
func send_ffb(constant: float, spring: float, damper: float, friction: float, vibration: float, vibration_ms: float = 30.0) -> void:
	if not ffb_enabled or not ffb_available() or ffb_test_phase != 0:
		return
	_send_raw(steer_device_index(), -constant if ffb_invert else constant, spring * ffb_spring, damper * ffb_damper, friction,
			vibration * ffb_vibration, vibration_ms, ffb_gain)


func _send_raw(dev: int, con: float, spr: float, dmp: float, fri: float, vib: float, vib_ms: float, gain: float) -> void:
	_send("ffb %d %.3f %.3f %.3f %.3f %.3f %.1f %.3f" % [dev, clampf(con, -1.0, 1.0), clampf(spr, 0.0, 1.0), clampf(dmp, 0.0, 1.0),
			clampf(fri, 0.0, 1.0), clampf(vib, 0.0, 1.0), vib_ms, clampf(gain, 0.0, 1.0)])


## First-time check: gentle spring (3 s) -> push right (0.7 s) -> ask which way it pulled.
func start_ffb_test() -> void:
	if not ffb_available() or ffb_test_phase != 0:
		return
	ffb_test_phase = 1
	_ffb_test_t = 0.0
	ffb_test_changed.emit(ffb_test_phase)


## pulled_right: true = pulled right (direction fine) / false = pulled left (invert) / null = felt nothing.
func finish_ffb_test(pulled_right: Variant) -> void:
	if pulled_right != null:
		ffb_invert = not bool(pulled_right)
		ffb_enabled = true
		ffb_verified = true
		save_cfg()
	ffb_test_phase = 0
	ffb_test_changed.emit(0)


func _test_step(delta: float) -> void:
	if ffb_test_phase == 0:
		return
	if not ffb_available():
		ffb_test_phase = 0
		ffb_test_changed.emit(0)
		return
	_ffb_test_t += delta
	var dev := steer_device_index()
	match ffb_test_phase:
		1:
			_send_raw(dev, 0.0, 0.8, 0.0, 0.0, 0.0, 25.0, 0.2)
			if _ffb_test_t > 3.0:
				ffb_test_phase = 2
				_ffb_test_t = 0.0
				ffb_test_changed.emit(2)
		2:
			_send_raw(dev, 0.8, 0.0, 0.0, 0.0, 0.0, 25.0, 0.15)
			if _ffb_test_t > 0.7:
				ffb_test_phase = 3
				_ffb_test_t = 0.0
				ffb_test_changed.emit(3)
		3:
			_send_raw(dev, 0.0, 0.0, 0.0, 0.0, 0.0, 25.0, 0.0)
			if _ffb_test_t > 30.0:
				finish_ffb_test(null)


# ------------------------------------------------------------------ settings file
func save_cfg() -> void:
	var cf := ConfigFile.new()
	cf.set_value("link", "enabled", _cfg_link)
	cf.set_value("ffb", "enabled", ffb_enabled)
	cf.set_value("ffb", "verified", ffb_verified)
	cf.set_value("ffb", "gain", ffb_gain)
	cf.set_value("ffb", "invert", ffb_invert)
	cf.set_value("ffb", "damper", ffb_damper)
	cf.set_value("ffb", "spring", ffb_spring)
	cf.set_value("ffb", "vibration", ffb_vibration)
	cf.set_value("steer", "wheel_range", wheel_range)
	cf.set_value("steer", "lock_to_lock", lock_to_lock)
	cf.set_value("steer", "gamma", steer_gamma)
	cf.set_value("bind", "axes", bindings)
	cf.set_value("bind", "buttons", buttons)
	cf.save(config_path)


func load_cfg() -> void:
	var cf := ConfigFile.new()
	if cf.load(config_path) != OK:
		return
	link_enabled = cf.get_value("link", "enabled", link_enabled) == true
	ffb_verified = cf.get_value("ffb", "verified", false) == true
	ffb_enabled = ffb_verified and cf.get_value("ffb", "enabled", false) == true
	ffb_gain = clampf(_num(cf, "ffb", "gain", ffb_gain), 0.0, 1.0)
	ffb_invert = cf.get_value("ffb", "invert", false) == true
	ffb_damper = clampf(_num(cf, "ffb", "damper", ffb_damper), 0.0, 2.0)
	ffb_spring = clampf(_num(cf, "ffb", "spring", ffb_spring), 0.0, 2.0)
	ffb_vibration = clampf(_num(cf, "ffb", "vibration", ffb_vibration), 0.0, 2.0)
	wheel_range = clampf(_num(cf, "steer", "wheel_range", wheel_range), 90.0, 2520.0)
	lock_to_lock = clampf(_num(cf, "steer", "lock_to_lock", lock_to_lock), 90.0, 2520.0)
	steer_gamma = clampf(_num(cf, "steer", "gamma", steer_gamma), 0.5, 2.0)
	var b = cf.get_value("bind", "axes", {})
	bindings = {}
	if b is Dictionary:
		for k: String in ["steer", "throttle", "brake"]:
			var e = b.get(k)
			if e is Dictionary and e.has("id") and e.has("axis"):
				bindings[k] = e
	# buttons are kept for any action: games register their actions after this autoload has loaded
	var bb = cf.get_value("bind", "buttons", {})
	buttons = {}
	if bb is Dictionary:
		for k in bb.keys():
			var e = bb[k]
			if e is Dictionary and e.has("id") and e.has("btn"):
				buttons[str(k)] = e


func _num(cf: ConfigFile, section: String, key: String, def: float) -> float:
	var v = cf.get_value(section, key, def)
	return float(v) if (v is float or v is int) else def


## Debug helpers
func debug_report() -> void:
	print("[wheel] link=%s running=%s connected=%s missing=%s devices=%d steer=%.3f throttle=%.2f brake=%.2f pov=%d" % [link_enabled, link_running(), connected, bridge_missing, devices.size(), steer_value(), pedal_value("throttle"), pedal_value("brake"), pov])
	for dv in devices:
		print("  #%d %s id=%s ffb=%s fx=%s buttons=%s" % [int(dv["i"]), dv["n"], dv["id"], dv.get("ffb", 0), dv.get("fx", 0), dv["nb"]])
