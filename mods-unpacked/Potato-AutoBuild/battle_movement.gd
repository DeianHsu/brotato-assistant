extends MovementBehavior

const Steering = preload("res://mods-unpacked/Potato-AutoBuild/battle_steering.gd")
const REPLAN_FRAMES = 4

var manager
var main
var native_movement
var steering = Steering.new()
var arbiter_active = false
var last_plan_usec = 0
var _next_frame = 0
var _direction = Vector2.ZERO
var _bull_retry = false
var _character = ""


func attach(player: Player, scene: Node, assistant, retries: int) -> void:
	manager = assistant
	main = scene
	native_movement = player._movement_behavior
	var character = RunData.get_player_character(0)
	_character = character.my_id if character != null else ""
	_bull_retry = _character == "character_bull" and retries > 0 and manager.next_run.is_automatic_run()
	name = "PotatoBattleMovement"
	init(player)
	player.add_child(self)
	player._movement_behavior = self
	if player._current_movement_behavior == native_movement:
		player._current_movement_behavior = self


func get_movement() -> Vector2:
	var enabled = manager.auto_enabled and manager.battle_movement and not get_tree().paused and RunData.wave_in_progress
	var manual = Vector2.ZERO
	if not enabled or not ProgressData.settings.mouse_only or Input.is_mouse_button_pressed(BUTTON_LEFT):
		manual = native_movement.get_movement()
	if not enabled or manual != Vector2.ZERO:
		if arbiter_active:
			Utils._manual_aim_cache[0] = null
		arbiter_active = false
		_next_frame = 0
		_direction = Vector2.ZERO
		return manual
	# 武器读取的是本帧瞄准缓存。接管时使用原生自动瞄准，保留玩家的选项。
	Utils._manual_aim_cache[0] = false
	arbiter_active = true
	var frame = Engine.get_physics_frames()
	if frame >= _next_frame:
		var started = OS.get_ticks_usec()
		_direction = steering.choose(main, _parent, _character, _bull_retry and main._is_horde_wave, _direction)
		last_plan_usec = OS.get_ticks_usec() - started
		_next_frame = frame + REPLAN_FRAMES
	return _direction
