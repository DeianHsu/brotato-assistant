extends Reference

var settings = {}
var _rs_held = {}
var _captured = {}
const PAD_ACTIONS = {JOY_DPAD_RIGHT: "execute", JOY_DPAD_UP: "preview", JOY_DPAD_DOWN: "log", JOY_DPAD_LEFT: "toggle_auto"}
const ECHO_BUTTONS = {"ui_right": JOY_DPAD_RIGHT, "ui_up": JOY_DPAD_UP, "ui_down": JOY_DPAD_DOWN, "ui_left": JOY_DPAD_LEFT}


func route(event: InputEvent, active: bool, in_run: bool = false) -> String:
	if event is InputEventKey:
		if not event.pressed:
			return ""
		if in_run and _matches_key(event, settings.auto_key):
			return "consume" if event.echo else "toggle_auto"
		if active:
			for action in ["execute", "preview", "log"]:
				var setting = "buy_key" if action == "execute" else action + "_key"
				if _matches_key(event, settings[setting]):
					return "consume" if event.echo else action
		if not event.echo and _matches_key(event, settings.start_key):
			return "start_run"
	elif event is InputEventJoypadButton:
		if event.button_index == JOY_R3:
			_rs_held[event.device] = event.pressed
			return "consume" if active else ""
		var token = str(event.device) + ":" + str(event.button_index)
		if not event.pressed:
			return "consume" if _captured.erase(token) else ""
		if _captured.has(token):
			return "consume"
		if (active or (in_run and event.button_index == JOY_DPAD_LEFT)) and modifier_held(event.device) and PAD_ACTIONS.has(event.button_index):
			_captured[token] = true
			return PAD_ACTIONS[event.button_index]
	elif event is InputEventAction:
		# 游戏自己会把长按十字键转换成重复导航事件，组合键期间只吞掉，不重复执行。
		for action in ECHO_BUTTONS:
			if event.action == action or event.action.begins_with(action + "_"):
				if (active and modifier_held(event.device)) or _captured.has(str(event.device) + ":" + str(ECHO_BUTTONS[action])):
					return "consume"
	elif event is InputEventJoypadMotion and active and modifier_held(event.device):
		if event.axis == JOY_AXIS_2 or event.axis == JOY_AXIS_3:
			return "consume"
	return ""


func modifier_held(device: int) -> bool:
	return _rs_held.get(device, false) or Input.is_joy_button_pressed(device, JOY_R3)


func forget_device(device: int, connected: bool) -> void:
	if connected:
		return
	_rs_held.erase(device)
	for token in _captured.keys():
		if token.begins_with(str(device) + ":"):
			_captured.erase(token)


func _matches_key(event: InputEventKey, binding: String) -> bool:
	var parts = binding.to_lower().split("+")
	var code = OS.find_scancode_from_string(parts[parts.size() - 1])
	return (event.scancode == code or event.physical_scancode == code) and event.control == ("ctrl" in parts) and event.shift == ("shift" in parts) and event.alt == ("alt" in parts) and not event.meta
