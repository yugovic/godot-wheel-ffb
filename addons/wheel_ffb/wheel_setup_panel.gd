class_name WheelSetupPanel
extends Control
## Wheel / pedals / force feedback setup screen built from plain Godot controls (it follows your project theme).
## Add it to your UI, call open(), and listen for `closed`.
##   var p := WheelSetupPanel.new(); add_child(p); p.open(); p.closed.connect(p.queue_free)

signal closed

const RANGES: Array[int] = [180, 270, 360, 540, 720, 900, 1080, 1260, 1440, 1800, 2520]
const LOCKS: Array[int] = [270, 360, 450, 540, 720, 900]
const SHAPES: Array[String] = ["Linear", "Soft", "Softer"]
const SHAPE_GAMMA: Array[float] = [1.0, 1.2, 1.5]
const LEVELS: Array[String] = ["Off", "Low", "Mid", "High"]
const LEVEL_VALUE: Array[float] = [0.0, 0.5, 1.0, 1.5]

var _status: Label
var _hint: Label
var _link: CheckButton
var _rows := {}                      # kind -> {sub: Label, btn: Button, meter: ProgressBar}
var _range: OptionButton
var _lock: OptionButton
var _shape: OptionButton
var _ffb_on: CheckButton
var _gain: HSlider
var _gain_label: Label
var _invert: CheckButton
var _damper: OptionButton
var _spring: OptionButton
var _vibration: OptionButton
var _test_btn: Button
var _test_note: Label
var _ask: HBoxContainer
var _close: Button
var _test_pending := false
var _test_wait := 0.0                # wall-clock start of the wait (s)
var _refresh_t := 0.0
var _hint_is_capture := false
var _updating := false               # suppress signal handlers while _refresh() writes the controls


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(660, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.13, 0.15, 0.97)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var c := VBoxContainer.new()
	c.add_theme_constant_override("separation", 6)
	panel.add_child(c)
	c.add_child(_title("Steering wheel"))
	_status = _small("")
	c.add_child(_status)
	_hint = _small("")
	_hint.add_theme_color_override("font_color", Color(0.95, 0.78, 0.45))
	c.add_child(_hint)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 520)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	c.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	scroll.add_child(body)

	_link = CheckButton.new()
	_link.text = "Use wheel (starts WheelBridge, reads DirectInput devices)"
	body.add_child(_link)

	body.add_child(_title("Assignment", 15))
	_axis_row(body, "steer", "Steering")
	_axis_row(body, "throttle", "Throttle")
	_axis_row(body, "brake", "Brake")
	for a in WheelInput.button_actions():
		_button_row(body, a)
	var clear := Button.new()
	clear.text = "Clear all assignments"
	clear.pressed.connect(_clear_all)
	body.add_child(clear)

	body.add_child(_title("Steering", 15))
	_range = _option_row(body, "Wheel rotation range", "Set it to the range configured in your wheel's software", _deg_items(RANGES))
	_lock = _option_row(body, "Car lock to lock", "Smaller = quicker steering", _deg_items(LOCKS))
	_shape = _option_row(body, "Centre response", "", SHAPES)

	body.add_child(_title("Force feedback", 15))
	_ffb_on = CheckButton.new()
	_ffb_on.text = "Force feedback (confirm the direction with the test first)"
	body.add_child(_ffb_on)
	var gr := HBoxContainer.new()
	var gl := _small("Strength")
	gl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gr.add_child(gl)
	_gain = HSlider.new()
	_gain.min_value = 10
	_gain.max_value = 100
	_gain.step = 10
	_gain.custom_minimum_size = Vector2(220, 0)
	gr.add_child(_gain)
	_gain_label = _small("")
	_gain_label.custom_minimum_size = Vector2(44, 0)
	gr.add_child(_gain_label)
	body.add_child(gr)
	body.add_child(_small("High-torque direct drives: start low and keep the base's own max torque modest."))
	_invert = CheckButton.new()
	_invert.text = "Invert force direction"
	body.add_child(_invert)
	_damper = _option_row(body, "Damper", "Weight / prevents oscillation", LEVELS)
	_spring = _option_row(body, "Centering", "Low-speed return to centre", LEVELS)
	_vibration = _option_row(body, "Road vibration", "Kerbs, gravel, slides, impacts", LEVELS)
	_test_btn = Button.new()
	_test_btn.text = "FFB test (moves gently - hold the wheel lightly)"
	_test_btn.pressed.connect(_on_test_pressed)
	body.add_child(_test_btn)
	_test_note = _small("")
	body.add_child(_test_note)
	_ask = HBoxContainer.new()
	for item in [["Pulled RIGHT", true], ["Pulled LEFT", false], ["Felt nothing", null]]:
		var b := Button.new()
		b.text = item[0]
		var ans: Variant = item[1]
		b.pressed.connect(func(): WheelInput.finish_ffb_test(ans))
		_ask.add_child(b)
	_ask.visible = false
	body.add_child(_ask)

	_close = Button.new()
	_close.text = "Close"
	_close.pressed.connect(_on_close)
	c.add_child(_close)

	_link.toggled.connect(func(on: bool):
		if not _updating:
			WheelInput.set_link_enabled(on))
	_range.item_selected.connect(func(i: int):
		WheelInput.wheel_range = float(RANGES[i])
		WheelInput.save_cfg())
	_lock.item_selected.connect(func(i: int):
		WheelInput.lock_to_lock = float(LOCKS[i])
		WheelInput.save_cfg())
	_shape.item_selected.connect(func(i: int):
		WheelInput.steer_gamma = SHAPE_GAMMA[i]
		WheelInput.save_cfg())
	_ffb_on.toggled.connect(_on_ffb_toggled)
	_gain.value_changed.connect(func(v: float):
		_gain_label.text = "%d%%" % int(v)
		if not _updating:
			WheelInput.ffb_gain = v / 100.0
			WheelInput.save_cfg())
	_invert.toggled.connect(func(on: bool):
		if not _updating:
			WheelInput.ffb_invert = on
			WheelInput.save_cfg())
	_damper.item_selected.connect(func(i: int):
		WheelInput.ffb_damper = LEVEL_VALUE[i]
		WheelInput.save_cfg())
	_spring.item_selected.connect(func(i: int):
		WheelInput.ffb_spring = LEVEL_VALUE[i]
		WheelInput.save_cfg())
	_vibration.item_selected.connect(func(i: int):
		WheelInput.ffb_vibration = LEVEL_VALUE[i]
		WheelInput.save_cfg())
	WheelInput.capture_finished.connect(func(_k, _ok): _refresh())
	WheelInput.devices_changed.connect(_refresh)
	WheelInput.ffb_test_changed.connect(func(_p): _refresh())


func _title(text: String, size: int = 18) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l


func _small(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.7, 0.74, 0.78))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _deg_items(a: Array[int]) -> Array[String]:
	var r: Array[String] = []
	for v in a:
		r.append("%d°" % v)
	return r


func _option_row(parent: Control, label: String, sub: String, items: Array[String]) -> OptionButton:
	var row := HBoxContainer.new()
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := Label.new()
	l.text = label
	left.add_child(l)
	if sub != "":
		left.add_child(_small(sub))
	row.add_child(left)
	var ob := OptionButton.new()
	ob.custom_minimum_size = Vector2(170, 0)
	for it in items:
		ob.add_item(it)
	row.add_child(ob)
	parent.add_child(row)
	return ob


func _axis_row(parent: Control, kind: String, label: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := Label.new()
	l.text = label
	left.add_child(l)
	var sub := _small("")
	left.add_child(sub)
	row.add_child(left)
	var meter := ProgressBar.new()
	meter.custom_minimum_size = Vector2(150, 10)
	meter.show_percentage = false
	meter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if kind == "steer":
		meter.min_value = -1.0
	meter.max_value = 1.0
	meter.step = 0.001
	row.add_child(meter)
	var b := Button.new()
	b.text = "Assign"
	b.custom_minimum_size = Vector2(100, 0)
	b.pressed.connect(func(): _begin(kind))
	row.add_child(b)
	parent.add_child(row)
	_rows[kind] = {"sub": sub, "btn": b, "meter": meter}


func _button_row(parent: Control, action: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var info: Array = WheelInput.action_labels.get(action, [action, ""])
	var l := Label.new()
	l.text = str(info[0]) + ("   " + str(info[1]) if str(info[1]) != "" else "")
	left.add_child(l)
	var sub := _small("")
	left.add_child(sub)
	row.add_child(left)
	var b := Button.new()
	b.text = "Assign"
	b.custom_minimum_size = Vector2(100, 0)
	b.pressed.connect(func(): _begin("btn:" + action))
	row.add_child(b)
	parent.add_child(row)
	_rows["btn:" + action] = {"sub": sub, "btn": b, "meter": null}


func _begin(kind: String) -> void:
	if not WheelInput.link_enabled:
		_hint.text = "The wheel link is off. Turn on \"Use wheel\" first."
		return
	if not WheelInput.connected:
		_hint.text = WheelInput.link_problem if WheelInput.link_problem != "" else "Connecting to the wheel... try again in a moment."
		return
	if WheelInput.devices.is_empty():
		_hint.text = "No devices found. Check the wheel / pedals power and USB."
		return
	WheelInput.begin_capture(kind)
	_refresh()


func _clear_all() -> void:
	WheelInput.cancel_capture()
	WheelInput.bindings.clear()
	WheelInput.buttons.clear()
	WheelInput.save_cfg()
	_refresh()


func _on_ffb_toggled(on: bool) -> void:
	if _updating:
		return
	if on and not WheelInput.ffb_verified:
		_updating = true
		_ffb_on.button_pressed = false
		_updating = false
		_hint.text = "Run the FFB test below first to confirm the force direction (it turns force feedback on)."
		return
	WheelInput.ffb_enabled = on
	WheelInput.save_cfg()


func _reason_text(r: String) -> String:
	match r:
		"":
			return "Ready - a gentle centering spring (3 s), then a light push to the right."
		"missing":
			return "WheelBridge.exe not found (addons/wheel_ffb/bin, or next to the exported game)."
		"link_off":
			return "The wheel link is off - pressing the test turns it on and starts once the wheel is found."
		"connecting":
			return "Connecting to the wheel..."
		"no_steer":
			return "Steering is not assigned - use \"Assign\" next to Steering first."
		"steer_absent":
			return "The assigned steering device is not connected (check power / USB)."
		"no_ffb":
			return "The device assigned to steering has no force feedback."
		"busy":
			return "Force feedback unavailable - another program (e.g. the wheel's own software) may be using the wheel exclusively. Close it, then turn the link off and on."
	return r


## The test button always works: it fills in what is missing (turns the link on, waits for the wheel)
## or says what to do next.
func _on_test_pressed() -> void:
	if WheelInput.ffb_test_phase != 0:
		return
	var r := WheelInput.ffb_block_reason()
	match r:
		"":
			_test_pending = false
			WheelInput.start_ffb_test()
		"link_off":
			WheelInput.set_link_enabled(true)
			_test_pending = true
			_test_wait = Time.get_ticks_msec() * 0.001
			_hint.text = "Wheel link turned on. The test starts as soon as the wheel is found..."
		"connecting":
			_test_pending = true
			_test_wait = Time.get_ticks_msec() * 0.001
			_hint.text = "Connecting to the wheel. The test starts as soon as it is ready..."
		"no_steer":
			_hint.text = "Assign the steering first (turn the wheel right and back)."
			(_rows["steer"]["btn"] as Button).grab_focus()
		_:
			_hint.text = _reason_text(r)
	_refresh()


func _binding_text(kind: String) -> String:
	if kind.begins_with("btn:"):
		var b = WheelInput.buttons.get(kind.substr(4))
		if b == null:
			return "not assigned"
		return "%s - button %d" % [_dev_name(str(b["id"])), int(b["btn"]) + 1]
	var e = WheelInput.bindings.get(kind)
	if e == null:
		return "not assigned"
	return "%s - %s axis" % [_dev_name(str(e["id"])), WheelInput.AXIS_NAMES[clampi(int(e["axis"]), 0, 7)]]


func _dev_name(id: String) -> String:
	var n := WheelInput.device_name(id)
	return n if n != "" else "(device not connected)"


func _nearest(a: Array, v: float) -> int:
	var best := 0
	for i in range(a.size()):
		if absf(float(a[i]) - v) < absf(float(a[best]) - v):
			best = i
	return best


func _refresh() -> void:
	_updating = true
	var st := ""
	if WheelInput.bridge_missing:
		st = "WheelBridge.exe not found (addons/wheel_ffb/bin, or next to the exported game)."
	elif not WheelInput.link_enabled:
		st = "Wheel link is off."
	elif WheelInput.link_problem != "":
		st = WheelInput.link_problem
	elif not WheelInput.link_running():
		st = "Starting the bridge..."
	elif not WheelInput.connected and WheelInput.devices.is_empty():
		st = "Connecting to the wheel..."
	elif WheelInput.devices.is_empty():
		st = "No devices connected. Check the wheel / pedals power and USB."
	else:
		var names := []
		for dv in WheelInput.devices:
			names.append("%s%s" % [dv["n"], " [FFB]" if int(dv.get("fx", 0)) == 1 else ""])
		st = "Found: " + " / ".join(names)
	_status.text = st
	for kind: String in _rows.keys():
		var r: Dictionary = _rows[kind]
		(r["sub"] as Label).text = _binding_text(kind)
		(r["btn"] as Button).text = "Waiting..." if WheelInput.capture_kind == kind else "Assign"
	if WheelInput.capture_kind != "":
		_hint.text = WheelInput.capture_hint
		_hint_is_capture = true
	elif _hint_is_capture:
		_hint.text = ""
		_hint_is_capture = false
	var ph := WheelInput.ffb_test_phase
	_test_btn.disabled = ph != 0
	_ask.visible = ph == 3
	_test_note.text = "" if ph != 0 else _reason_text(WheelInput.ffb_block_reason())
	match ph:
		1:
			_hint.text = "Centering test: turn the wheel a little - it should pull back to the centre (3 s)."
		2:
			_hint.text = "Hold the wheel lightly. Pushing to the right..."
		3:
			_hint.text = "Which way did the wheel pull?"
	_link.button_pressed = WheelInput.link_enabled
	_ffb_on.button_pressed = WheelInput.ffb_enabled
	_invert.button_pressed = WheelInput.ffb_invert
	_gain.value = roundf(WheelInput.ffb_gain * 10.0) * 10.0
	_gain_label.text = "%d%%" % int(_gain.value)
	_range.select(_nearest(RANGES, WheelInput.wheel_range))
	_lock.select(_nearest(LOCKS, WheelInput.lock_to_lock))
	_shape.select(_nearest(SHAPE_GAMMA, WheelInput.steer_gamma))
	_damper.select(_nearest(LEVEL_VALUE, WheelInput.ffb_damper))
	_spring.select(_nearest(LEVEL_VALUE, WheelInput.ffb_spring))
	_vibration.select(_nearest(LEVEL_VALUE, WheelInput.ffb_vibration))
	_updating = false


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_t += delta
	if _refresh_t > 0.5:
		_refresh_t = 0.0
		_refresh()
	for kind: String in ["steer", "throttle", "brake"]:
		var m := _rows[kind]["meter"] as ProgressBar
		m.value = (WheelInput.steer_value() if kind == "steer" else WheelInput.pedal_value(kind)) if WheelInput.has_binding(kind) else 0.0
	if _test_pending:
		var r := WheelInput.ffb_block_reason()
		if r == "":
			_test_pending = false
			WheelInput.start_ffb_test()
			_refresh()
		elif r != "connecting" or Time.get_ticks_msec() * 0.001 - _test_wait > 8.0:
			_test_pending = false
			_hint.text = _reason_text(r) if r != "connecting" else "No wheel found (check power / USB)."
			_refresh()


func open() -> void:
	visible = true
	_refresh()
	await get_tree().process_frame
	(_rows["steer"]["btn"] as Button).grab_focus()   # not the link toggle: a stray left/right must not switch the link off


func _on_close() -> void:
	WheelInput.cancel_capture()
	_test_pending = false
	WheelInput.save_cfg()
	visible = false
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event.is_action_pressed("ui_cancel"):
		return
	if WheelInput.capture_kind != "":
		WheelInput.cancel_capture()
	elif _test_pending:
		_test_pending = false
		_refresh()
	elif WheelInput.ffb_test_phase != 0:
		WheelInput.finish_ffb_test(null)
	else:
		_on_close()
	get_viewport().set_input_as_handled()
