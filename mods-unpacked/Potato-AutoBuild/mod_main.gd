extends Node

signal automation_changed

const Controller = preload("res://mods-unpacked/Potato-AutoBuild/shop_controller.gd")
const UpgradeController = preload("res://mods-unpacked/Potato-AutoBuild/upgrade_controller.gd")
const InputRouter = preload("res://mods-unpacked/Potato-AutoBuild/input_router.gd")
const WaveObserver = preload("res://mods-unpacked/Potato-AutoBuild/wave_observer.gd")
const BattleMovement = preload("res://mods-unpacked/Potato-AutoBuild/battle_movement.gd")
var next_run = preload("res://mods-unpacked/Potato-AutoBuild/next_run.gd").new()
const LOG_NAME = "Potato-AutoBuild"
const SETTINGS_PATH = "user://potato_autobuy.cfg"
const WAVE_DEATH_LIMIT = 5
var previous_route = ""
var _character_id = ""
var _observed_run = ""
var _last_wave = -1
var settings = {"buy_key": "Alt+1", "preview_key": "Alt+2", "log_key": "Alt+3", "auto_key": "Alt+4", "start_key": "Alt+5"}
var input_router = InputRouter.new()
var log_visible = false
var auto_enabled = true
var battle_movement = true
var _retry_menu
var _retry_wave_key = []
var _retries_at_wave_start = 0
var _shop_controller
var _upgrade_controller
var auto_locks = {}
var released_locks = {}
var _lock_run = ""
var _lock_page = -1
var _saved_lock_state = {}
const LOCK_STATE_PATH = "user://potato_assistant_locks.cfg"
var _last_shop_wave = -1
var version = "未知"
var income_wave = -1
var wave_income = 0
var wave_activity_income = 0
var income_ledger = {}
var _settlement_parts = {}
var _last_gain = 0
var _last_gain_frame = -1
var _wave_observer
var _income_wave_start
var _last_gold = -1
var xp_wave = -1
var wave_base_xp = 0.0
var wave_harvest_xp = 0.0
var _ended_xp_wave
var _xp_wave_start
var _last_xp = 0.0
var _xp_level = 0
var battle_observation = {}
var combat_prediction = {}


func _ready() -> void:
	pause_mode = Node.PAUSE_MODE_PROCESS
	_load_settings()
	_load_lock_state()
	var manifest = File.new()
	if manifest.open("res://mods-unpacked/Potato-AutoBuild/manifest.json", File.READ) == OK:
		var metadata = parse_json(manifest.get_as_text())
		manifest.close()
		if metadata is Dictionary:
			version = str(metadata.get("version_number", "未知"))
	get_node("/root/RunData").connect("gold_changed", self, "_on_gold_changed")
	get_node("/root/RunData").connect("xp_added", self, "_on_xp_added")
	get_node("/root/RunData").connect("stat_added", self, "_on_income_stat")
	input_router.settings = settings
	add_child(next_run)
	Input.connect("joy_connection_changed", input_router, "forget_device")
	get_tree().connect("node_added", self, "_on_node_added")
	_scan(get_tree().root)
	ModLoaderLog.info("已加载版本 " + version + "：" + shortcut_hint(), LOG_NAME)


func _on_gold_changed(value: int, player: int) -> void:
	if player != 0:
		return
	var run = get_node("/root/RunData")
	if run.wave_in_progress:
		var starts = run.start_wave_state.get("players_data", [])
		var start = starts[0] if not starts.empty() else null
		var first = income_wave != run.current_wave or start != _income_wave_start
		if first:
			income_wave = run.current_wave
			wave_income = 0
			wave_activity_income = 0
			income_ledger = {"pickup": 0, "standing": 0, "start": 0, "harvest": 0, "special": 0, "cleanup": 0, "conversion": 0, "mixed": 0, "loss": 0}
			_settlement_parts.clear()
			_income_wave_start = start
		if _last_gold >= 0:
			var gained = max(0, value - _last_gold)
			_last_gain = gained
			_last_gain_frame = Engine.get_physics_frames()
			wave_income += gained
			# 波初利息和波末结算另算；避免把它们复制为下一波的拾取收入。
			var start_gain = 0
			if first and start != null:
				start_gain = max(0, int(start.gold * run.get_player_effect(get_node("/root/Keys").gain_pct_gold_start_wave_hash, 0) / 100.0))
				income_ledger.start = int(start.gold * run.get_player_effect(get_node("/root/Keys").gain_pct_gold_start_wave_hash, 0) / 100.0)
			var at_conversion = is_instance_valid(_wave_observer) and not _wave_observer._ended and _wave_observer.main._wave_timer.time_left <= 0 and not run.get_player_effect(get_node("/root/Keys").convert_stats_end_of_wave_hash, 0).empty()
			if at_conversion:
				income_ledger.conversion += value - _last_gold
			elif start == null or start != _ended_xp_wave:
				wave_activity_income += max(0, gained - start_gain)
				income_ledger.mixed += max(0, gained - start_gain)
				income_ledger.loss += max(0, _last_gold - value - max(0, -income_ledger.start if first else 0))
			elif not _settlement_parts.empty():
				income_ledger.harvest += _settlement_parts.harvest
				income_ledger.special += _settlement_parts.special
				income_ledger.cleanup += value - _last_gold - _settlement_parts.harvest - _settlement_parts.special
				_settlement_parts.clear()
			else:
				income_ledger.cleanup += value - _last_gold
	_last_gold = value


func _on_income_stat(stat: int, value: float, db: float, player: int) -> void:
	if player == 0 and stat == get_node("/root/Keys").stat_materials_hash and db == -15.0 and not income_ledger.empty() and get_node("/root/RunData").wave_in_progress:
		var amount = min(int(value), income_ledger.mixed)
		income_ledger.standing += amount
		income_ledger.mixed -= amount
		wave_activity_income = max(0, wave_activity_income - amount)
		_last_gain = 0


func record_pickup_income() -> void:
	# 原生拾取处理先加材料再发给此观察者；无法归属的收入继续保留为 mixed。
	if income_ledger.empty() or _last_gain_frame != Engine.get_physics_frames():
		return
	var amount = min(_last_gain, income_ledger.mixed)
	income_ledger.pickup += amount
	income_ledger.mixed -= amount
	_last_gain = 0


func _on_xp_added(current: float, _needed: float, player: int) -> void:
	var run = get_node("/root/RunData")
	if player != 0 or not run.wave_in_progress:
		return
	var starts = run.start_wave_state.get("players_data", [])
	if starts.empty():
		return
	var start = starts[0]
	if start != _xp_wave_start:
		_xp_wave_start = start
		xp_wave = run.current_wave
		wave_base_xp = 0.0
		wave_harvest_xp = 0.0
		_last_xp = start.current_xp
		_xp_level = start.current_level
	var level = run.get_player_level(player)
	var multiplier = 1.0 + get_node("/root/Utils").get_stat(get_node("/root/Keys").xp_gain_hash, player) / 100.0
	# 原生先发经验增加信号，再在跨级后发一次。后者只更新起点，不重复计收入。
	if level == _xp_level and multiplier > 0.0:
		var added = max(0.0, current - _last_xp) / multiplier
		wave_base_xp += added
		if start == _ended_xp_wave:
			# 波末还可能有和平主义等经验，只分离收获本身，保留其他实测奖励。
			wave_harvest_xp += min(added, max(0.0, get_node("/root/Utils").get_stat(get_node("/root/Keys").stat_harvesting_hash, player)))
	_last_xp = current
	_xp_level = level


func _on_wave_ended() -> void:
	var starts = get_node("/root/RunData").start_wave_state.get("players_data", [])
	_ended_xp_wave = starts[0] if not starts.empty() else null
	if is_instance_valid(_wave_observer):
		_settlement_parts = _wave_observer.settlement_components()
		if _settlement_parts.harvest + _settlement_parts.special == 0:
			_settlement_parts.clear()


func _load_settings(path: String = SETTINGS_PATH) -> void:
	var config = ConfigFile.new()
	if config.load(path) == OK:
		var old_f = config.get_value("keys", "buy_key", "") == "F7" and config.get_value("keys", "preview_key", "") == "F8" and config.get_value("keys", "log_key", "") == "F9"
		var old_chord = config.get_value("keys", "buy_key", "") == "Ctrl+Shift+1" and config.get_value("keys", "preview_key", "") == "Ctrl+Shift+2" and config.get_value("keys", "log_key", "") == "Ctrl+Shift+3"
		for key in settings:
			if not old_f and not old_chord:
				settings[key] = str(config.get_value("keys", key, settings[key]))
	for key in settings:
		config.set_value("keys", key, settings[key])
	auto_enabled = config.get_value("automation", "enabled", true)
	battle_movement = config.get_value("automation", "battle_movement", true)
	config.set_value("automation", "enabled", auto_enabled)
	config.save(path)


func shortcut_hint() -> String:
	return "%s 执行 | %s 预览 | %s 日志 | %s 自动%s | %s 自动开局\n手柄按住 RS：→ 执行 | ↑ 预览 | ↓ 日志 | ← 切换自动" % [settings.buy_key, settings.preview_key, settings.log_key, settings.auto_key, "开" if auto_enabled else "关", settings.start_key]


func set_automation_enabled(enabled: bool) -> void:
	if auto_enabled == enabled:
		return
	auto_enabled = enabled
	var config = ConfigFile.new()
	config.load(SETTINGS_PATH)
	config.set_value("automation", "enabled", enabled)
	config.save(SETTINGS_PATH)
	emit_signal("automation_changed")


func _input(event: InputEvent) -> void:
	if is_instance_valid(_wave_observer) and event is InputEventKey and event.pressed and event.shift and not event.control and not event.alt and not event.meta and event.scancode == KEY_SPACE:
		get_tree().set_input_as_handled()
		if not event.echo:
			battle_movement = not battle_movement
			var config = ConfigFile.new()
			config.load(SETTINGS_PATH)
			config.set_value("automation", "battle_movement", battle_movement)
			config.save(SETTINGS_PATH)
		return
	var controller = _active_controller()
	var in_run = controller != null or is_instance_valid(_wave_observer) or is_instance_valid(_shop_controller) or next_run.handles_input()
	var action = input_router.route(event, controller != null, in_run)
	if action == "start_run":
		if next_run.start_from_shortcut():
			get_tree().set_input_as_handled()
		return
	if action == "":
		return
	get_tree().set_input_as_handled()
	if action == "toggle_auto":
		set_automation_enabled(not auto_enabled)
		return
	if action == "consume" or controller == null:
		return
	if action == "log":
		controller.toggle_log()
	elif action == "preview" and controller == _shop_controller:
		controller.call_deferred(action, true)
	else:
		controller.call_deferred(action)


func _active_controller():
	if is_instance_valid(_upgrade_controller) and _upgrade_controller.is_active():
		return _upgrade_controller
	if is_instance_valid(_shop_controller) and _shop_controller.is_active():
		return _shop_controller
	return null


func _scan(node: Node) -> void:
	_on_node_added(node)
	for child in node.get_children():
		_scan(child)


func _on_node_added(node: Node) -> void:
	if node.filename != "" and node.get_parent() == get_tree().root:
		next_run.call_deferred("scene_entered", node)
	if node.has_signal("end_of_the_wave") and not node.is_connected("end_of_the_wave", self, "_on_wave_ended"):
		node.connect("end_of_the_wave", self, "_on_wave_ended")
		call_deferred("_observe_wave", node)
	if node.filename == "res://ui/menus/shop/shop.tscn":
		call_deferred("_attach", node)
	elif node.filename == "res://ui/menus/ingame/upgrades_ui.tscn":
		call_deferred("_attach_upgrades", node)


func _observe_wave(main: Node) -> void:
	if not is_instance_valid(main) or main.has_node("PotatoWaveObserver") or get_node("/root/RunData").is_coop_run:
		return
	var run = get_node("/root/RunData")
	_sync_run(run)
	var wave_key = [next_run._profile(), _observed_run, run.current_wave]
	if wave_key != _retry_wave_key:
		_retry_wave_key = wave_key
		_retries_at_wave_start = run.retries
	next_run.record_character()
	var observer = WaveObserver.new()
	observer.wave_retries = max(0, run.retries - _retries_at_wave_start)
	observer.name = "PotatoWaveObserver"
	observer.manager = self
	observer.main = main
	main.add_child(observer)
	_wave_observer = observer
	_retry_menu = main.get_node_or_null("UI/RetryWave")
	main.connect("end_of_the_wave", observer, "finish")


func attach_battle_movement(main: Node, player: Player, retries: int) -> void:
	if not player.has_node("PotatoBattleMovement"):
		var movement = BattleMovement.new()
		movement.attach(player, main, self, retries)


func _process(_delta: float) -> void:
	if not auto_enabled or not is_instance_valid(_retry_menu) or not _retry_menu.is_visible_in_tree() or get_tree().paused:
		return
	var run = get_node("/root/RunData")
	if run.is_coop_run or run.run_won or not _wave_observer.main._is_wave_failed or not next_run.is_automatic_run() or run.start_wave_state.get("current_wave", -1) != run.current_wave:
		return
	if _retry_menu.confirm_button_pressed or _retry_menu.cancel_button_pressed:
		return
	# 游戏累计整局的重试次数，停在死亡页的这一次还没计入。
	var deaths = run.retries - _retries_at_wave_start + 1
	if deaths >= WAVE_DEATH_LIMIT:
		next_run.record_failed_character()
		ModLoaderLog.info("第 %d 波连续阵亡 %d 次，结束本局。" % [run.current_wave, deaths], LOG_NAME)
		_retry_menu._on_CancelButton_pressed()
	elif not _retry_menu._confirm_button.disabled:
		_retry_menu._on_ConfirmButton_pressed()


func _attach(shop: Node) -> void:
	if not is_instance_valid(shop) or shop.has_node("PotatoAutoBuild"):
		return
	var run = get_node("/root/RunData")
	if run.is_coop_run:
		return
	_sync_run(run)
	prepare_locks(run, shop._reroll_count[0])
	var controller = Controller.new()
	controller.name = "PotatoAutoBuild"
	controller.manager = self
	controller.shop = shop
	shop.add_child(controller)
	_shop_controller = controller


func _attach_upgrades(ui: Node) -> void:
	if not is_instance_valid(ui) or ui.has_node("PotatoUpgradeAssist") or get_node("/root/RunData").is_coop_run:
		return
	_sync_run(get_node("/root/RunData"))
	var controller = UpgradeController.new()
	controller.name = "PotatoUpgradeAssist"
	controller.manager = self
	controller.ui = ui
	ui.add_child(controller)
	_upgrade_controller = controller


func _sync_run(run) -> void:
	var id = run.get_player_character(0).my_id
	var run_key = _run_key(run)
	if run_key != _observed_run or id != _character_id or run.current_wave < _last_wave:
		previous_route = ""
		# 锁定归属由 prepare_locks 的独立局标识维护，观察样本重置不能抹掉本店锁状态。
		var starts = run.start_wave_state.get("players_data", [])
		if starts.empty() or starts[0] != _income_wave_start:
			income_wave = -1
			wave_income = 0
			wave_activity_income = 0
			income_ledger.clear()
			_settlement_parts.clear()
		battle_observation = {}
		combat_prediction = {}
	_character_id = id
	_observed_run = run_key
	_last_wave = run.current_wave
	_last_gold = run.get_player_gold(0)


func _run_key(run) -> String:
	# 原生总开局次数在继续游戏时不变；不向真实存档写入额外标识。
	return str([get_node("/root/ProgressData").data.get("run_started", 0), run.get_player_character(0).my_id, run.current_zone, run.current_difficulty])


func prepare_locks(run, reroll_count: int) -> void:
	var run_key = _run_key(run)
	if _lock_run == "":
		if _saved_lock_state.get("run", "") == run_key and _saved_lock_state.get("wave", -1) <= run.current_wave:
			auto_locks = _saved_lock_state.get("locks", {})
			if _saved_lock_state.get("wave", -1) == run.current_wave and _saved_lock_state.get("page", -1) == reroll_count:
				released_locks = _saved_lock_state.get("released", {})
		_saved_lock_state.clear()
	elif _lock_run != run_key or run.current_wave < _last_shop_wave:
		auto_locks.clear()
		released_locks.clear()
	if _lock_run != "" and (run.current_wave != _last_shop_wave or reroll_count != _lock_page):
		released_locks.clear()
	_lock_run = run_key
	_last_shop_wave = run.current_wave
	_lock_page = reroll_count


func _load_lock_state(path: String = LOCK_STATE_PATH) -> void:
	var config = ConfigFile.new()
	if config.load(path) == OK:
		var saved = config.get_value("assistant", "state", {})
		if saved is Dictionary and saved.get("locks", {}) is Dictionary and saved.get("released", {}) is Dictionary:
			_saved_lock_state = saved


func save_locks(path: String = LOCK_STATE_PATH) -> void:
	if _lock_run == "":
		return
	var config = ConfigFile.new()
	config.set_value("assistant", "state", {"run": _lock_run, "wave": _last_shop_wave, "page": _lock_page, "locks": auto_locks, "released": released_locks})
	config.save(path)
