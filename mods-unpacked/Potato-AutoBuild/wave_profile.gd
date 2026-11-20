extends Reference

const BAIT_GROUP = preload("res://zones/common/bait/group_bait.tres")
const OPENING_SECONDS = 10

static func build(adapter, zone, wave, threat: String) -> Dictionary:
	if wave == null:
		return {}
	var run = adapter.run
	var next = run.get_next_wave()
	var duration = float(wave.wave_duration)
	var groups = []
	for group in zone.groups_data_in_all_waves + wave.groups_data:
		groups.append([group, 1.0])
	for alternatives in wave.conditional_groups_data:
		for group in alternatives:
			groups.append([group, 1.0 / alternatives.size()])
	if threat == "horde":
		for group in zone.horde_groups:
			if next >= group.min_wave and next <= group.max_wave:
				groups.append([group, 1.0, true])
	for id in run.get_node("/root/ProgressData").dlc_ids:
		if id in run.active_update_data_ids:
			var dlc = adapter.items.get_dlc_data_by_id(id)
			if dlc != null:
				for group in dlc.groups_in_all_zones:
					groups.append([group, 1.0])
	var effects = run.get_player_effects(adapter.player)
	var extra = effects.get(adapter.keys.generate_hash("extra_enemies_next_wave"), []).duplicate()
	extra.append_array(effects.get(adapter.keys.generate_hash("extra_enemies_at_wave"), {}).get(str(next), []))
	for entry in extra:
		var group = load(entry[0])
		if group != null:
			groups.append([group, float(entry[1])])
	# 原生危险等级、辅助设置和无尽倍率；角色及候选的敌人生命倍率留给评分器。
	var curse = max(0.0, adapter.utils.get_stat(adapter.keys.stat_curse_hash, adapter.player))
	var factor = max(0.01, 1.0 + adapter.effect("danger_enemy_health") / 100.0) * run.current_run_accessibility_settings.health
	factor *= max(0.01, 1.0 + run.get_endless_factor(next) * 2.25 * (1.0 + sqrt(curse) / 10.0))
	var bins = []
	bins.resize(int(ceil(duration)))
	for i in range(bins.size()):
		bins[i] = 0.0
	var health_counts = {}
	var count = 0.0
	var horde_count = 0.0
	var speed_total = 0.0
	var total = 0.0
	var boss_health = 0.0
	var opening_bait = 0.0
	for entry in groups:
		var group = entry[0]
		if group.is_neutral or run.current_difficulty < group.min_difficulty or run.current_difficulty > group.max_difficulty:
			continue
		if (threat == "elite" and group.prevent_if_elite) or (threat == "horde" and group.prevent_if_horde):
			continue
		var spawns = schedule(group, duration)
		for unit in group.wave_units_data:
			if not unit.type in [EntityType.ENEMY, EntityType.BOSS]:
				continue
			var stats = adapter._scene_stats(unit.unit_scene)
			if stats == null:
				continue
			var hp = max(1.0, round(stats.get_base_health(next) * factor))
			var target = Vector2(hp, round(stats.armor + stats.armor_increase_each_wave * (next - 1)))
			var number = unit.spawn_chance * (unit.min_number + unit.max_number) / 2.0 * entry[1]
			if unit.type == EntityType.BOSS:
				boss_health += hp * number
				continue
			for spawn in spawns:
				var amount = spawn[1] * number
				count += amount
				speed_total += stats.speed * amount
				if entry.size() > 2:
					horde_count += amount
				total += hp * amount
				if group == BAIT_GROUP and spawn[0] < OPENING_SECONDS:
					opening_bait += amount
				health_counts[target] = health_counts.get(target, 0.0) + amount
				bins[min(bins.size() - 1, int(spawn[0]))] += hp * amount
	# 精英/最终首领由原生运行数据选择，不从随机池提前抽样。
	var zones = run.get_node("/root/ZoneService")
	var elite_ids = []
	for spawn in run.elites_spawn:
		if spawn[0] == next and spawn[1] == 0:
			elite_ids.append(spawn[2])
	for entry in extra:
		if entry.size() > 2 and load(entry[0]).is_boss:
			elite_ids.append(entry[2])
	for boss in zones.get_elites_from_zone(run.current_zone):
		if boss.my_id_hash in elite_ids:
			var stats = adapter._scene_stats(boss.scene)
			if stats != null:
				boss_health += round(stats.get_base_health(next) * factor) * elite_ids.count(boss.my_id_hash)
	if next == run.nb_of_waves:
		for boss in zones.get_bosses_from_zone(run.current_zone):
			if boss.my_id in run.bosses_spawn:
				var stats = adapter._scene_stats(boss.scene)
				if stats != null:
					boss_health += round(stats.get_base_health(next) * factor)
	# 普通鱼饵已排队的敌群在 extra 中。持有强化鱼饵的持续敌群由游戏在开波时另行生成。
	var lampreys = BAIT_GROUP.wave_units_data[0]
	var lamprey_stats = adapter._scene_stats(lampreys.unit_scene)
	var hp = max(1.0, round(lamprey_stats.get_base_health(next) * factor))
	var damage_factor = max(0.01, 1.0 + adapter.effect("danger_enemy_damage") / 100.0) * run.current_run_accessibility_settings.damage
	var bait_damage = max(1.0, round(lamprey_stats.get_base_damage(next) * damage_factor))
	var upgraded = run.get_player_effect_bool(adapter.keys.upgraded_baits_hash, adapter.player)
	var owned = run.get_nb_item(adapter.keys.item_bait_hash, adapter.player) if upgraded else 0
	var armor = round(lamprey_stats.armor + lamprey_stats.armor_increase_each_wave * (next - 1))
	var bait = {"base_bins": bins.duplicate(), "hp": hp, "armor": armor, "ordinary": (lampreys.min_number + lampreys.max_number) * 0.5,
		"upgraded": upgraded, "owned": owned, "profiles": {}}
	var recurring = _add_bait_enemies(bins, bait, 0, owned)
	bait.recurring = recurring
	if recurring > 0:
		var target = Vector2(hp, armor)
		health_counts[target] = health_counts.get(target, 0.0) + recurring
		count += recurring
		speed_total += lamprey_stats.speed * recurring
		total += hp * recurring
	var peak = _peak(bins)
	var opening_health = 0.0
	var opening_seconds = min(OPENING_SECONDS, bins.size())
	for second in range(opening_seconds):
		opening_health += bins[second]
	var opening = {"seconds": opening_seconds, "health": opening_health, "bait_count": opening_bait, "bait_hp": hp, "bait_damage": bait_damage}
	var targets = []
	var largest = 1.0
	for target in health_counts:
		if count > 0:
			targets.append({"hp": target.x, "armor": target.y, "weight": health_counts[target] / count})
			largest = max(largest, target.x)
	return {"clear": max(1.0, max(total / duration, peak)), "mean": total / duration, "peak": peak,
		"boss": max(1.0, boss_health / min(30.0, duration) if boss_health > 0 else largest / 3.0), "boss_health": boss_health,
		"targets": targets, "spawns": count, "horde_spawns": horde_count, "average_enemy_speed": speed_total / max(1.0, count),
		"density": clamp(count / duration * 1.5, 0.0, 6.0), "duration": duration, "bait": bait, "opening": opening}


static func with_bait(profile: Dictionary, groups: int, copies: int) -> Dictionary:
	var bait = profile.bait
	var held = bait.owned + copies if bait.upgraded else 0
	var key = Vector2(groups, held)
	if bait.profiles.has(key):
		return bait.profiles[key]
	var bins = bait.base_bins.duplicate()
	var added = _add_bait_enemies(bins, bait, groups, held) - bait.recurring
	if added <= 0:
		return profile
	var count = profile.spawns + added
	var targets = []
	for t in profile.targets:
		targets.append({"hp": t.hp, "armor": t.armor, "weight": t.weight * profile.spawns / count})
	targets.append({"hp": bait.hp, "armor": bait.armor, "weight": added / count})
	var peak = _peak(bins)
	var mean = profile.mean + bait.hp * added / profile.duration
	var opening = profile.opening.duplicate()
	if BAIT_GROUP.spawn_timing < opening.seconds:
		opening.bait_count += groups * bait.ordinary
		opening.health += groups * bait.ordinary * bait.hp
	var projected = {"clear": max(1.0, max(mean, peak)), "peak": peak, "mean": mean,
		"spawns": count, "density": clamp(count / profile.duration * 1.5, 0.0, 6.0), "duration": profile.duration,
		"targets": targets, "boss_health": profile.boss_health, "boss": profile.boss if profile.boss_health > 0 else max(profile.boss, bait.hp / 3.0),
		"bait_key": key, "opening": opening}
	bait.profiles[key] = projected
	return projected


static func _add_bait_enemies(bins: Array, bait: Dictionary, groups: int, held: int) -> float:
	var total = 0.0
	var onset = BAIT_GROUP.spawn_timing
	if groups > 0 and onset < bins.size():
		total = groups * bait.ordinary
		bins[onset] += total * bait.hp
	if held == 0:
		return total
	var group_count = max(1, int(held / 10.0))
	var bonus = int(held / 15.0)
	# 原生组内下限是 1+bonus，上限平均是 1.5+2*bonus，每组固定一个取整后的随机间隔。
	var count = 1.25 + 1.5 * bonus
	for i in range(group_count):
		var start = max(15, int(i * 50.0 / group_count + 1))
		for interval in [6, 7, 8]:
			var expected = count * (0.5 if interval == 7 else 0.25)
			for second in range(start, bins.size(), interval):
				bins[second] += bait.hp * expected
				total += expected
	return total


static func _peak(bins: Array) -> float:
	var peak = 0.0
	var rolling = 0.0
	var window = min(10, bins.size())
	for i in range(bins.size()):
		rolling += bins[i]
		if i >= window:
			rolling -= bins[i - window]
		peak = max(peak, rolling / max(1, window))
	return peak


static func schedule(group, duration: float) -> Array:
	var time = 0.0 if group.is_boss else float(group.spawn_timing)
	var result = [[time, group.spawn_chance]] if time < duration else []
	var interval = float(group.repeating_interval)
	time += interval
	for _i in range(group.repeating):
		if time >= duration:
			break
		result.append([time, 1.0])
		interval = max(group.min_repeating_interval, interval - group.reduce_repeating_interval)
		time += interval
	return result
