extends Node3D
## Wheel FFB demo: a VehicleBody3D on a flat ground, driven by the wheel (or the keyboard), with force feedback.
##   F1 / Tab ........ wheel setup (assign steering / pedals / buttons, FFB test)
##   W A S D / arrows  keyboard fallback       R  reset the car
## Everything is built in code so the demo has no asset dependencies.

const MAX_STEER := deg_to_rad(32.0)
const ENGINE_FORCE := 2600.0
const BRAKE_FORCE := 40.0

var car: VehicleBody3D
var cam: Camera3D
var ffb := WheelFFBVehicle.new()
var panel: WheelSetupPanel
var info: Label
var _in := Vector3.ZERO              # steer, throttle, brake actually applied (for the info line)


func _ready() -> void:
	_actions()
	# Let wheel buttons trigger the demo's own actions (they appear in the setup screen)
	WheelInput.register_action("demo_reset", "Reset car", "R")
	WheelInput.register_action("demo_setup", "Open wheel setup", "F1")
	_world()
	car = _car()
	add_child(car)
	cam = Camera3D.new()
	cam.fov = 70.0
	add_child(cam)
	cam.current = true
	var layer := CanvasLayer.new()
	add_child(layer)
	info = Label.new()
	info.position = Vector2(16, 12)
	info.add_theme_font_size_override("font_size", 14)
	layer.add_child(info)
	panel = WheelSetupPanel.new()
	panel.visible = false
	layer.add_child(panel)


func _actions() -> void:
	for a: Array in [["accelerate", [KEY_W, KEY_UP]], ["brake", [KEY_S, KEY_DOWN]], ["steer_left", [KEY_A, KEY_LEFT]],
			["steer_right", [KEY_D, KEY_RIGHT]], ["demo_reset", [KEY_R]], ["demo_setup", [KEY_F1, KEY_TAB]]]:
		if InputMap.has_action(a[0]):
			continue
		InputMap.add_action(a[0])
		for k: int in a[1]:
			var e := InputEventKey.new()
			e.physical_keycode = k as Key
			InputMap.action_add_event(a[0], e)


func _world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.62, 0.7)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.62, 0.66)
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(800, 1, 800)
	shape.shape = box
	shape.position.y = -0.5
	ground.add_child(shape)
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(800, 800)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.35, 0.33)
	pm.material = mat
	mi.mesh = pm
	ground.add_child(mi)
	add_child(ground)
	# cones to steer around
	for i in range(24):
		var cone := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.05
		cm.bottom_radius = 0.3
		cm.height = 0.7
		var cmat := StandardMaterial3D.new()
		cmat.albedo_color = Color(0.95, 0.45, 0.1)
		cm.material = cmat
		cone.mesh = cm
		cone.position = Vector3(sin(i * 0.5) * 6.0, 0.35, 20.0 + i * 12.0)
		add_child(cone)


func _car() -> VehicleBody3D:
	var v := VehicleBody3D.new()
	v.mass = 1200.0
	v.position = Vector3(0, 1.0, 0)
	var col := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(1.7, 0.6, 4.0)
	col.shape = bs
	col.position.y = 0.45
	v.add_child(col)
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.7, 0.6, 4.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.45, 0.4)
	bm.material = mat
	body.mesh = bm
	body.position.y = 0.45
	v.add_child(body)
	for i in range(4):
		var w := VehicleWheel3D.new()
		var front := i < 2
		w.position = Vector3(0.8 if i % 2 == 0 else -0.8, 0.3, 1.35 if front else -1.35)
		w.use_as_steering = front
		w.use_as_traction = not front
		w.wheel_radius = 0.34
		w.suspension_travel = 0.2
		w.suspension_stiffness = 40.0
		w.damping_compression = 0.9
		w.damping_relaxation = 1.2
		w.wheel_friction_slip = 2.6
		w.suspension_max_force = 12000.0
		var wm := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.34
		cm.bottom_radius = 0.34
		cm.height = 0.24
		wm.mesh = cm
		wm.rotation_degrees.z = 90.0
		w.add_child(wm)
		v.add_child(w)
	return v


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("demo_setup") and not panel.visible:
		panel.open()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("demo_reset"):
		car.global_transform = Transform3D(Basis(), Vector3(0, 1.0, 0))
		car.linear_velocity = Vector3.ZERO
		car.angular_velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	var steer := 0.0
	var throttle := 0.0
	var brake := 0.0
	var driving := not panel.visible
	if WheelInput.steer_active():
		steer = WheelInput.steer_value()                 # -1..1, right positive, applied 1:1
	else:
		steer = Input.get_action_strength("steer_right") - Input.get_action_strength("steer_left")
	if WheelInput.has_pedals():
		throttle = WheelInput.pedal_value("throttle")
		brake = WheelInput.pedal_value("brake")
	else:
		throttle = Input.get_action_strength("accelerate")
		brake = Input.get_action_strength("brake")
	if not driving:
		throttle = 0.0
	# VehicleBody3D: positive steering turns left
	_in = Vector3(steer, throttle, brake)
	car.steering = -steer * MAX_STEER
	car.engine_force = throttle * ENGINE_FORCE
	car.brake = brake * BRAKE_FORCE
	ffb.update(car, delta)
	if driving:
		ffb.send()


func _process(_delta: float) -> void:
	var fwd := car.global_transform.basis.z
	var target := car.global_position - fwd * 7.0 + Vector3.UP * 2.6
	cam.global_position = cam.global_position.lerp(target, 0.1)
	cam.look_at(car.global_position + Vector3.UP * 0.8)
	var src := "wheel" if WheelInput.steer_active() else "keyboard"
	info.text = "Wheel FFB demo      F1 / Tab: wheel setup      R: reset\n" + \
		"input: %s   speed %3d km/h   steer %+.2f   throttle %.2f   brake %.2f\n" % [src, int(car.linear_velocity.length() * 3.6), _in.x, _in.y, _in.z] + \
		"FFB: %s   constant %+.2f   spring %.2f   damper %.2f   vibration %.2f" % ["on" if WheelInput.ffb_enabled else "off (run the FFB test in setup)", ffb.constant, ffb.spring, ffb.damper, ffb.vibration]
