extends Node

var manager
var main
var wave_retries = 0
var _elapsed = 0.0
var _samples = 0
var _engaged = 0
var _counts = [0.0, 0.0]
var _halves = [0, 0]
var _ended = false
var _events = {}
var _timing = {}
var _presence = 0
var _watching = false
var _last_health = 0
var _health_loss = 0
var _movement = []
var _segment = {}
var _movement_limited = false
var _full_health = 0
var _below_half = 0
var _health_samples = 0
var _missing_health = 0.0
var _kills_start = -1
var _picked_ids = {}
var _melee_hits = {}
var _late_contacts = {"contacts": 0, "body_contacts": 0}
var _late_samples = 0


func _watch_events() -> void:
	if _watching or main._players.empty():
		return
	_watching = true
	_kills_start = get_node("/root/ProgressData").data.get("enemies_killed", 0)
	_events = {"pickups": 0, "consumables": 0}
	var player = main._players[0]
	if not player is Node:
		return
	# 承伤估计也需要普通角色的实测，不能只给带事件特效的构筑接信号。
	for name in ["contacts", "body_contacts", "hits", "self_hits", "dodges", "protected", "heals", "healed"]:
		_events[name] = 0
	if player is Player:
		manager.attach_battle_movement(main, player, wave_retries)
	for weapon in player.current_weapons:
		if weapon.current_stats is MeleeWeaponStats and not weapon._hitbox.projectiles_on_hit.empty():
			weapon._hitbox.connect("hit_something", self, "_on_melee_hit", [weapon.get_instance_id()])
	_last_health = player.current_stats.health
	player.connect("health_updated", self, "_health_updated")
	player.connect("healed", self, "_healed")
	player.connect("took_damage", self, "_hurt")
	get_tree().connect("node_added", self, "_watch_pickup")
	for node in main._active_golds + main._consumables:
		_watch_pickup(node)


func _watch_pickup(node: Node) -> void:
	if node is Gold or node is Consumable:
		_picked_ids.erase(node.get_instance_id())
		if not node.is_connected("picked_up", self, "_picked"):
			node.connect("picked_up", self, "_picked")


func _picked(node: Node, player: int) -> void:
	if player == 0 and not _ended and not _picked_ids.has(node.get_instance_id()):
		_picked_ids[node.get_instance_id()] = true
		_events["pickups" if node is Gold else "consumables"] += 1
		if node is Gold:
			manager.record_pickup_income()


func _on_melee_hit(target, _damage, weapon_id: int) -> void:
	if not _ended and target.has_method("get_charmed_by_player_index"):
		_melee_hits[weapon_id] = _melee_hits.get(weapon_id, 0) + 1


func _record_movement(moving: bool, seconds: float) -> void:
	if _segment.empty():
		_segment = {"moving": moving, "seconds": seconds}
	elif _segment.moving == moving:
		_segment.seconds += seconds
	else:
		if _movement.size() < 512:
			_movement.append(_segment)
		else:
			_movement_limited = true
		_segment = {"moving": moving, "seconds": seconds}


func settlement_components() -> Dictionary:
	var run = get_node("/root/RunData")
	var keys = get_node("/root/Keys")
	var spawner = main._entity_spawner
	var pacifist = round((spawner.get_all_enemies().size() + spawner.enemies_removed_for_perf) * run.get_player_effect(keys.pacifist_hash, 0) / 100.0)
	if main._is_horde_wave:
		pacifist = int(pacifist / 2.0)
	var special = pacifist + run.current_living_trees * run.get_player_effect(keys.cryptid_hash, 0)
	special += spawner.enemies.size() * run.get_player_effect(keys.materials_per_living_enemy_hash, 0) + main._elite_killed_bonus
	for enemy in spawner.enemies:
		if enemy.get_charmed_by_player_index() != -1:
			special += main.get_gold_value(EntityType.ENEMY, get_node("/root/Utils").default_die_args, enemy.stats.value)
	return {"harvest": get_node("/root/Utils").get_stat(keys.stat_harvesting_hash, 0), "special": special}


func _health_updated(_player, health: int, _maximum: int) -> void:
	_health_loss = max(0, _last_health - health)
	_last_health = health


func _healed(amount: int, player: int) -> void:
	if player == 0 and not _ended and amount > 0:
		_events.heals += 1
		_events.healed += amount


func _hurt(unit, value, _knockback, _critical, dodged, protected, _armor, args, _hit_type, _one_shot) -> void:
	if _ended:
		return
	var self_hit = args.from == unit
	if not self_hit:
		_events.contacts += 1
		var late = main._wave_timer.time_left <= 15.0
		if late:
			_late_contacts.contacts += 1
		if args is TakeDamageArgs and is_instance_valid(args.from) and (args.from is Enemy or args.from is Boss) and args.hitbox == args.from._hitbox:
			_events.body_contacts += 1
			if late:
				_late_contacts.body_contacts += 1
	if dodged:
		_events.dodges += 1
		_stamp("dodges")
	elif protected:
		_events.protected += 1
	elif value > 0 and (_health_loss > 0 or get_node("/root/RunData").get_player_effect(get_node("/root/Keys").materials_as_health_hash, 0)):
		_events["self_hits" if self_hit else "hits"] += 1
		if not self_hit:
			_stamp("hits")
	_health_loss = 0


func _stamp(key: String) -> void:
	var duration = max(1.0, main._wave_timer.wait_time)
	var elapsed = duration - main._wave_timer.time_left
	var moments = _timing.get(key, {"average": 0.0, "opening": 0.0})
	moments.average += max(0.0, 1.0 - elapsed / duration)
	moments.opening += max(0.0, 1.0 - elapsed / min(15.0, duration))
	_timing[key] = moments


func _process(delta: float) -> void:
	if _ended or not is_instance_valid(main) or get_tree().paused:
		return
	var run = get_node("/root/RunData")
	if not run.wave_in_progress or main._players.empty():
		return
	_watch_events()
	_record_movement(main._players[0]._current_movement != Vector2.ZERO, delta)
	_elapsed += delta
	if _elapsed < 0.5:
		return
	_elapsed = 0.0
	var spawner = main._entity_spawner
	var count = spawner.enemies.size() + spawner.bosses.size()
	var half = 0 if main._wave_timer.time_left > main._wave_timer.wait_time / 2.0 else 1
	if main._wave_timer.time_left <= 15.0:
		_late_samples += 1
	_counts[half] += count
	_halves[half] += 1
	_samples += 1
	if count > 0:
		_presence += 1
	var player = main._players[0]
	if player is Node:
		_health_samples += 1
		_full_health += int(player.current_stats.health >= player.max_stats.health)
		_below_half += int(player.current_stats.health < player.max_stats.health / 2.0)
		_missing_health += max(0.0, 1.0 - float(player.current_stats.health) / max(1, player.max_stats.health)) * 100.0
	var engaged = false
	for weapon in main._players[0].current_weapons:
		var target = weapon._current_target
		if not target.empty() and is_instance_valid(target[0]):
			engaged = engaged or (target[1] >= weapon.current_stats.min_range and target[1] <= weapon.current_stats.max_range + 50)
	if main._players[0]._current_movement != Vector2.ZERO and not run.get_player_effect(get_node("/root/Keys").can_attack_while_moving_hash, 0):
		engaged = false
	if engaged:
		_engaged += 1


func finish() -> void:
	if _ended:
		return
	_ended = true
	var run = get_node("/root/RunData")
	var damage = 0.0
	var weapons = []
	for weapon in run.get_player_weapons(0):
		damage += weapon.dmg_dealt_last_wave
		weapons.append(weapon.my_id)
	var prediction = manager.combat_prediction
	var same_build = prediction.get("wave", -1) == run.current_wave and prediction.get("weapons", []) == weapons
	for key in _timing:
		for moment in _timing[key]:
			_timing[key][moment] /= max(1, _events.get(key, 0))
	if not _events.empty():
		_events.timing = _timing
		_events.kills = max(0, get_node("/root/ProgressData").data.get("enemies_killed", 0) - _kills_start) if _kills_start >= 0 else 0
	if not _segment.empty():
		_movement.append(_segment)
	var melee_contacts = {}
	if not main._players.empty() and main._players[0] is Node:
		for weapon in main._players[0].current_weapons:
			if is_instance_valid(weapon) and weapon.current_stats is MeleeWeaponStats and not weapon._hitbox.projectiles_on_hit.empty():
				var family = weapon.weapon_id
				var counts = melee_contacts.get(family, {"swings": 0, "hits": 0})
				counts.swings += weapon._nb_shots_taken
				counts.hits += _melee_hits.get(weapon.get_instance_id(), 0)
				melee_contacts[family] = counts
	manager.battle_observation = {"wave": run.current_wave, "character": run.get_player_character(0).my_id,
		"wave_retries": wave_retries,
		"melee_contacts": melee_contacts,
		"predicted_food_rate": prediction.get("food_rate", 0.0), "predicted_hit_rate": prediction.get("hit_rate", 0.0),
		"movement_segments": _movement, "movement_limited": _movement_limited,
		"full_health_share": float(_full_health) / max(1, _health_samples), "below_half_share": float(_below_half) / max(1, _health_samples), "missing_health": _missing_health / max(1, _health_samples),
		"living_trees": run.current_living_trees, "ledger": manager.income_ledger.duplicate(),
		"events": _events, "enemy_presence": float(_presence) / max(1, _samples),
		"seconds": _samples * 0.5, "engaged": float(_engaged) / max(1, _samples),
		"early_enemies": _counts[0] / max(1, _halves[0]), "late_enemies": _counts[1] / max(1, _halves[1]),
		"late_contacts": _late_contacts, "late_seconds": _late_samples * 0.5,
		"effective_dps": damage / max(1.0, _samples * 0.5), "predicted_clear": prediction.get("clear", 0.0) if same_build else 0.0}
