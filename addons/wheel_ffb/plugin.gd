@tool
extends EditorPlugin
## Registers the WheelInput autoload while the plugin is enabled.

const AUTOLOAD := "WheelInput"


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD, "res://addons/wheel_ffb/wheel_input.gd")


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD)
