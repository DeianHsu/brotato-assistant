extends CanvasLayer

const END_SCENE = "res://ui/menus/run/end_run.tscn"
const HISTORY_PATH = "user://potato_played_characters.cfg"
const DANGER = 5
const Coverage = preload("res://mods-unpacked/Potato-AutoBuild/mechanism_coverage.gd")
onready var manager = get_parent()
onready var run = get_node("/root/RunData")
onready var progress = get_node("/root/ProgressData")
onready var items = get_node("/root/ItemService")
onready var menus = get_node("/root/MenuData")
var history = ConfigFile.new()
var expected_scenes = []
var unavailable = []
var character_id = ""
var end_screen
var end_info = ""
var end_timer = Timer.new()
var rotation_stop_reason = ""
var last_character_id = OS.get_environment("POTATO_LAST_CHARACTER")
onready var _status = Label.new()


func _ready() -> void:
	history.load(HISTORY_PATH)
	layer = 21
	_status.text = "自动开局已开启"
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.hide()
	var font = DynamicFont.new()
	font.font_data = preload("res://resources/fonts/raw/NotoSansSC-Medium.otf")
	font.size = 22
	_status.add_font_override("font", font)
	_status.add_color_override("font_color", Color("#c9ffc9"))
	var background = StyleBoxFlat.new()
	background.bg_color = Color(0.04, 0.09, 0.06, 0.94)
	background.border_color = Color("#78de84")
	background.border_width_left = 3
	background.set_corner_radius_all(4)
	background.content_margin_left = 12
	background.content_margin_right = 10
	background.content_margin_top = 3
	background.content_margin_bottom = 3
	_status.add_stylebox_override("normal", background)
	add_child(_status)
	_status.set_anchors_and_margins_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 10)
	end_timer.one_shot = true
	add_child(end_timer)
	end_timer.connect("timeout", self, "_begin")
	manager.connect("automation_changed", self, "_mode_changed")


func _profile() -> String:
	return "%s_%d" % [progress.SAVE_DIR.get_file(), progress.current_profile_id]


func remember_automatic_run() -> void:
	history.set_value("automatic_runs", _profile(), manager._run_key(run))
	history.save(HISTORY_PATH)


func is_automatic_run() -> bool:
	return run.get_player_character(0) != null and history.get_value("automatic_runs", _profile(), "") == manager._run_key(run)


func start_from_shortcut() -> bool:
	var scene = get_tree().current_scene
	if scene == null or run.is_coop_run or get_tree().paused or get_viewport().get_modal_stack_top() != null or not expected_scenes.empty():
		return false
	if scene.filename == menus.title_screen_scene:
		var button = scene._main_menu.start_button
		if not button.is_visible_in_tree() or button.disabled:
			return false
		manager.set_automation_enabled(true)
		unavailable.clear()
		expected_scenes = [menus.character_selection_scene]
		scene._main_menu._on_StartButton_pressed()
	elif scene.filename == menus.character_selection_scene:
		manager.set_automation_enabled(true)
		unavailable.clear()
		_choose_character(scene)
	elif scene.filename == END_SCENE and scene == end_screen:
		manager.set_automation_enabled(true)
		end_timer.stop()
		_begin(true)
	else:
		return false
	return true


func record_character() -> void:
	var character = run.get_player_character(0)
	if run.is_coop_run or character == null:
		return
	var profile = _profile()
	var started = int(progress.data.get("run_started", 0))
	var last = history.get_value(profile, character.my_id, -1)
	if history.has_section_key("replace_after_loss", profile) and (history.get_value("replace_after_loss", profile) != character.my_id or last != started):
		history.erase_section_key("replace_after_loss", profile)
	elif last == started:
		return
	history.set_value(profile, character.my_id, started)
	history.save(HISTORY_PATH)


func record_failed_character() -> void:
	history.set_value("replace_after_loss", _profile(), run.get_player_character(0).my_id)
	history.save(HISTORY_PATH)


func handles_input() -> bool:
	return is_instance_valid(end_screen) and end_screen.is_inside_tree() or not expected_scenes.empty()


func _mode_changed() -> void:
	_update_status(get_tree().current_scene)
	expected_scenes.clear()
	unavailable.clear()
	end_timer.stop()
	if is_instance_valid(end_screen) and end_screen.is_inside_tree():
		end_screen._run_info.text = end_info
		if manager.auto_enabled and is_automatic_run():
			end_timer.start(1.5)


func scene_entered(scene) -> void:
	if not is_instance_valid(scene) or scene != get_tree().current_scene:
		return
	rotation_stop_reason = ""
	if scene.filename == END_SCENE and not run.is_coop_run:
		record_character()
		end_screen = scene
		end_info = scene._run_info.text
		_mode_changed()
		return
	_update_status(scene)
	var expected = scene.filename in expected_scenes
	expected_scenes.clear()
	if not expected or not manager.auto_enabled or run.is_coop_run or get_tree().paused:
		return
	if scene.filename == menus.character_selection_scene:
		_choose_character(scene)
		return
	elif run.get_player_character(0) != null and run.get_player_character(0).my_id == character_id:
		if scene.filename == menus.weapon_selection_scene:
			var button = _option(scene)
			if button != null:
				expected_scenes = [menus.difficulty_selection_scene]
				var picks = scene._get_required_pick_count(0) if scene.has_method("_get_required_pick_count") else 1
				for _pick in range(picks):
					scene._on_element_pressed(button, 0)
				return
			unavailable.append(character_id)
			expected_scenes = [menus.character_selection_scene]
			scene._on_BackButton_pressed()
			return
		elif scene.filename == menus.difficulty_selection_scene:
			var danger = _danger_five()
			var button = _option(scene, danger.my_id) if danger != null else null
			if button != null:
				var starts = progress.data.run_started
				scene._on_element_pressed(button, 0)
				if progress.data.run_started > starts:
					remember_automatic_run()
				return
	# 原生候选在切页后发生变化时，把当前页留给玩家。
	_show_hint(scene, "自动开局已停止，请手动选择。")


func _choose_character(scene) -> void:
	var zone = progress.settings.zone_selected if progress.settings.zone_is_random else run.current_zone
	var character = _candidate(zone, scene)
	if character == null:
		_stop_rotation(scene)
		return
	character_id = character.my_id
	expected_scenes = [menus.weapon_selection_scene, menus.difficulty_selection_scene]
	scene._on_element_pressed(_option(scene, character_id), 0)


func _show_hint(scene, message: String) -> void:
	var parent = scene._back_button.get_parent()
	var hint = parent.get_node_or_null("PotatoStartHint")
	if hint == null:
		hint = Label.new()
		hint.name = "PotatoStartHint"
		parent.add_child(hint)
	hint.text = message


func _update_status(scene) -> void:
	_status.visible = is_instance_valid(scene) and scene.filename in [menus.game_scene, menus.shop_scene, END_SCENE] and manager.auto_enabled and not run.is_coop_run and is_automatic_run()


func _begin(from_shortcut: bool = false) -> void:
	if not is_instance_valid(end_screen) or end_screen != get_tree().current_scene or end_screen._button_pressed or not manager.auto_enabled or run.is_coop_run:
		return
	# 倒计时到点时重新核对本局；手动局只接受玩家此刻按下的开局快捷键。
	if not from_shortcut and not is_automatic_run():
		return
	if get_tree().paused or end_screen._new_run_button.disabled:
		if not from_shortcut:
			end_timer.start(0.25)
		return
	if _candidate(run.current_zone) == null:
		_stop_rotation(end_screen)
		return
	expected_scenes = [menus.character_selection_scene]
	end_screen._on_NewRunButton_pressed()


func _danger_five():
	for difficulty in items.difficulties:
		if difficulty.value == DANGER:
			return difficulty
	return null


func _stop_rotation(scene) -> void:
	rotation_stop_reason = _no_candidate_hint()
	if scene == end_screen:
		scene._run_info.text = end_info + "\n" + rotation_stop_reason
		_status.hide()
	else:
		_show_hint(scene, rotation_stop_reason)


func _no_candidate_hint() -> String:
	if all_characters_cleared():
		return "所有角色均已通关，自动循环已停止。"
	if _defer_last_character(_cleared_characters()):
		return "暂无其他可选角色。指定角色将留到其余角色通关后。"
	if history.has_section_key("replace_after_loss", _profile()):
		return "五连败后暂无其他可选角色（须尚未通关、解锁难度 5，并支持自动操作）。"
	return "当前没有可自动开局的未通关角色（须解锁难度 5，并支持自动操作）。"


func _cleared_characters() -> Dictionary:
	var cleared = {}
	for info in progress.difficulties_unlocked:
		for record in info.zones_difficulty_info:
			if record.max_difficulty_beaten.difficulty_value >= 0:
				cleared[info.character_id] = true
				break
	return cleared


func all_characters_cleared() -> bool:
	var cleared = _cleared_characters()
	for character in items.characters:
		if not cleared.has(character.my_id):
			return false
	return not items.characters.empty()


func _defer_last_character(cleared: Dictionary) -> bool:
	if last_character_id == "" or cleared.has(last_character_id):
		return false
	var deferred_exists = false
	var others_uncleared = false
	for character in items.characters:
		if character.my_id == last_character_id:
			deferred_exists = true
		elif not cleared.has(character.my_id):
			others_uncleared = true
	return deferred_exists and others_uncleared


func _candidate(zone: int, selection = null):
	var danger = _danger_five()
	if danger == null:
		return null
	var cleared = _cleared_characters()
	var defer_last = _defer_last_character(cleared)
	var played = {}
	for info in progress.difficulties_unlocked:
		for record in info.zones_difficulty_info:
			if record.difficulty_selected_value > 0 or record.max_endless_wave_beaten.difficulty_value >= 0:
				played[info.character_id] = true
				break
	var debug = get_node("/root/DebugService")
	var previously_viewed = null
	var profile = _profile()
	var failed = history.get_value("replace_after_loss", profile, "")
	var alternate = null
	var earliest = INF
	for character in items.characters:
		if cleared.has(character.my_id) or character.my_id == failed or character.my_id in unavailable:
			continue
		if defer_last and character.my_id == last_character_id:
			continue
		if not debug.unlock_all_chars and not character.my_id_hash in progress.characters_unlocked:
			continue
		if items.has_method("get_disabled_required_update") and items.get_disabled_required_update(character) != null:
			continue
		if not danger.unlocked_by_default and not debug.unlock_all_difficulties and progress.get_character_difficulty_info(character.my_id_hash, zone).max_selectable_difficulty < DANGER:
			continue
		if selection == null:
			if not Coverage.inspect(character, {}).automatic:
				continue
		elif _option(selection, character.my_id) == null:
			continue
		if played.has(character.my_id) or history.has_section_key(profile, character.my_id):
			# 旧版历史仅保存布尔值，按未记录最近局次处理。
			var last = history.get_value(profile, character.my_id, 0)
			if typeof(last) == TYPE_BOOL:
				last = 0
			if last < earliest:
				alternate = character
				earliest = last
			continue
		# 原生角色计数在菜单预览时也会增长，只用于优先挑选从未查看的角色。
		if not progress.items_bought.has(character.my_id_hash):
			return character
		if previously_viewed == null:
			previously_viewed = character
	return previously_viewed if previously_viewed != null else alternate


func _option(scene, id: String = ""):
	for button in scene._get_inventories()[0].get_children():
		if button.is_special or button.is_random or button.item == null or button.item.is_locked or button.disabled or not button.is_visible_in_tree():
			continue
		if id != "" and button.item.my_id != id:
			continue
		if scene.filename == menus.character_selection_scene and not Coverage.inspect(button.item, {}).automatic:
			continue
		return button
	return null
