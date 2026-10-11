class_name WheelFFBVehicle
extends RefCounted
## Force feedback for Godot's built-in VehicleBody3D. Call update() every physics frame, then send() (or pass
## the fields to WheelInput.send_ffb yourself).
##
##   constant  self-aligning torque estimated from the steered wheels' slip angle. It grows with the slip angle,
##             then fades past the grip peak (the pneumatic trail collapses), so the wheel goes light at the limit.
##             Sign: pulls the rim back towards straight ahead (negative while turning right).
##   spring    centering at low speed only (fades out by ~9 m/s)
##   damper    heavier at low speed, a little at speed
##   vibration grows with wheel slip (get_skidinfo) and on impacts (note_impact)
##
## If your game has its own tyre model, send the real aligning torque instead: e.g. the sum over the front tyres of
## lateral_force * trail(slip), normalised by the front axle load (see README, "Custom physics").

var constant := 0.0
var spring := 0.0
var damper := 0.0
var friction := 0.03
var vibration := 0.0
var vibration_ms := 30.0

## Slip angle (rad) at which the steered tyres give their peak force. Lower = the wheel loads up faster.
var slip_peak := 0.12
## Overall scale of the aligning torque before the user's strength setting.
var aligning_gain := 1.2

var _sat := 0.0
var _impact := 0.0


## strength 0..1 (e.g. collision impulse / some maximum)
func note_impact(strength: float) -> void:
	_impact = maxf(_impact, clampf(strength, 0.0, 1.0))


func update(body: VehicleBody3D, delta: float) -> void:
	var sum := 0.0
	var n := 0
	var skid := 0.0
	var speed := body.linear_velocity.length()
	for c in body.get_children():
		var w := c as VehicleWheel3D
		if w == null or not w.is_in_contact():
			continue
		skid = maxf(skid, 1.0 - w.get_skidinfo())
		if not w.use_as_steering:
			continue
		# velocity of the contact patch in the wheel's own frame (the wheel basis includes the steering angle).
		# VehicleBody3D drives along +Z; +X is the car's left.
		var b := w.global_transform.basis
		var rel := w.global_position - body.global_position
		var v := body.linear_velocity + body.angular_velocity.cross(rel)
		var v_long := v.dot(b.z.normalized())
		var v_left := v.dot(b.x.normalized())
		var alpha := atan2(v_left, maxf(absf(v_long), 1.0))      # > 0: the patch slides towards the left of the wheel (turning right)
		var s := alpha / maxf(slip_peak, 0.01)
		var force := sin(1.4 * atan(1.6 * s))                     # tyre lateral force, peaks around s = 1
		var trail := cos(clampf(absf(s) / 2.0, 0.0, 1.0) * PI * 0.5)
		sum += force * trail * w.get_skidinfo()
		n += 1
	var target := 0.0
	if n > 0:
		target = -sum / n * aligning_gain * clampf(speed / 4.0, 0.0, 1.0)      # turning right -> pull left (negative)
	_sat = lerpf(_sat, target, 1.0 - exp(-delta / 0.015))
	constant = clampf(_sat, -1.0, 1.0)
	var low := clampf(1.0 - speed / 9.0, 0.0, 1.0)
	spring = 0.55 * low
	damper = 0.10 + 0.30 * low + 0.06 * clampf(speed / 40.0, 0.0, 1.0)
	vibration = clampf((skid - 0.2) * 0.4, 0.0, 0.3) * clampf(speed / 8.0, 0.0, 1.0)
	vibration_ms = 40.0
	if _impact > 0.0:
		vibration = maxf(vibration, 0.85 * _impact)
		vibration_ms = 22.0
		_impact = maxf(_impact - delta * 3.0, 0.0)


func send() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var wi: Node = tree.root.get_node_or_null("WheelInput") if tree != null else null
	if wi != null:
		wi.call("send_ffb", constant, spring, damper, friction, vibration, vibration_ms)
