extends Node
## Captures the README screenshots (docs/*.png). Run windowed:
##   godot --path . res://tools/capture_docs.tscn -- --wheel-fake

func _ready() -> void:
	var demo: Node3D = (load("res://demo/demo.tscn") as PackedScene).instantiate()
	add_child(demo)
	await get_tree().create_timer(1.0).timeout
	Input.action_press("accelerate")
	await get_tree().create_timer(3.0).timeout
	Input.action_press("steer_right", 0.6)
	await get_tree().create_timer(1.6).timeout
	await _shot("res://docs/demo.png")
	Input.action_release("accelerate")
	Input.action_release("steer_right")
	# setup screen with the virtual wheel + pedals and a steering binding
	WheelInput.bindings["steer"] = {"id": "FAKE-0000-WHEEL", "axis": 0, "center": 0.0, "sign": 1.0}
	WheelInput.bindings["throttle"] = {"id": "FAKE-0000-PEDAL", "axis": 0, "rest": -1.0, "full": 1.0}
	WheelInput.bindings["brake"] = {"id": "FAKE-0000-PEDAL", "axis": 1, "rest": -1.0, "full": 1.0}
	var panel: WheelSetupPanel = demo.get("panel")
	panel.open()
	await get_tree().create_timer(2.5).timeout
	await _shot("res://docs/setup.png")
	get_tree().quit()


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path(path))
	print("saved ", path)
