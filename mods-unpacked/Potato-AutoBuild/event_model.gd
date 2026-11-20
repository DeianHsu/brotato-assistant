extends Reference

const Combat = preload("res://mods-unpacked/Potato-AutoBuild/combat_model.gd")

static func contact_rate(observed: Dictionary, reference: float, late: bool = false) -> float:
	var history = observed.get("late_contacts" if late else "events", {})
	var seconds = observed.get("late_seconds" if late else "seconds", 0.0)
	if seconds < (10.0 if late else 20.0) or not history.has("contacts"):
		return reference
	var previous = observed.get("predicted_hit_rate", 0.0)
	var ratio = reference / previous if previous > 0.0 else 1.0
	# 移动和减速改变贴身接触的估计；弹幕、持续伤害沿用各自的观测频率。
	var body = history.get("body_contacts", history.contacts)
	var contacts = body * ratio + history.contacts - body
	return clamp(contacts / seconds, 0.0, 5.0)


# 活动频率是有界估计；原生伤害、概率、取整由效果参数决定，不建立角色专用评分器。
static func rates(context: Dictionary, defense: Dictionary, activity: Dictionary, effects: Dictionary) -> Dictionary:
	var seconds = max(1.0, context.get("wave_duration", 60.0))
	var observed = context.get("battle_observation", {})
	var history = observed.get("events", {})
	var contacts = contact_rate(observed, defense.get("hit_rate", 0.2))
	var dodge = defense.get("dodge", 0.0) / 100.0
	var invincibility = clamp(defense.get("mean_hit", 1.0) / max(1.0, defense.max_hp) * 0.4 / 0.15, 0.2, 0.4)
	contacts = min(contacts, 1.0 / invincibility)
	var hits = max(0.0, contacts * (1.0 - dodge) * seconds - defense.get("protection", 0.0))
	var self_hits = seconds if effects.get("lose_hp_per_second", 0.0) > 0 else 0.0
	if defense.get("mean_hit", 1.0) >= defense.get("health_resource", defense.opening_hp):
		hits = min(hits, 1.0)
	if effects.get("lose_hp_per_second", 0.0) >= defense.get("health_resource", defense.opening_hp):
		self_hits = min(self_hits, 1.0)
	var self_loss = self_hits * max(0.0, effects.get("lose_hp_per_second", 0.0))
	var support = max(0.0, defense.get("health_resource", defense.opening_hp) - 1.0) + defense.get("gross_recovery", 0.0) * seconds
	# 不能假设角色死亡后还能继续受击叠层、爆炸或治疗。
	var loss = hits * defense.get("mean_hit", 1.0) + self_loss
	var alive_share = min(1.0, support / max(1.0, loss))
	if context.get("resources", {}).get("die_in_one_hit", false):
		hits = 0.0
		self_hits = 0.0
		loss = 0.0
	var heals = valid_heals(defense.get("heal_rate", 0.0), defense.get("gross_recovery", 0.0),
		(loss + max(0.0, defense.max_hp - defense.opening_hp)) / seconds, seconds,
		context.get("no_heal", false) or context.get("resources", {}).get("materials_as_health", false))
	var pickups = activity.get("pickups", 0.0)
	var consumables = defense.get("food_rate", 0.0) * seconds
	if observed.get("seconds", 0.0) >= 20:
		if history.has("pickups"):
			pickups = history.pickups * seconds / observed.seconds * activity.get("pickup_ratio", 1.0)
		if history.has("consumables"):
			consumables = history.consumables * seconds / observed.seconds
			if observed.get("predicted_food_rate", 0.0) > 0:
				consumables *= defense.get("food_rate", 0.0) / observed.predicted_food_rate
	var availability = observed.get("enemy_presence", 0.65) if observed.get("seconds", 0.0) >= 20 else 0.65
	var spawns = context.get("combat_profile", {}).get("spawns", activity.get("kills", 0.0))
	var kills = activity.get("kills", 0.0) if observed.get("seconds", 0) >= 20 and history.has("kills") else spawns * activity.get("kill_coverage", 0.0)
	return {"timing": history.get("timing", {}), "hits": hits * alive_share, "self_hits": self_hits * alive_share,
		"kills": min(max(0.0, spawns - 1.0), kills) * alive_share,
		"dodges": contacts * dodge * seconds * alive_share, "heals": heals * alive_share,
		"pickups": max(0.0, pickups), "consumables": max(0.0, consumables), "seconds": seconds,
		"availability": clamp(availability, 0.0, 1.0), "alive_share": alive_share}


static func valid_heals(event_rate: float, amount_rate: float, missing_rate: float, seconds: float, blocked: bool = false) -> float:
	if blocked or event_rate <= 0 or amount_rate <= 0 or missing_rate <= 0:
		return 0.0
	return min(missing_rate, event_rate * min(1.0, missing_rate / amount_rate)) * seconds


static func stat_damage(stat: float, ratio: float, damage_percent: float) -> int:
	# main.handle_stat_damages：先向下取整来源，再应用百分比并四舍五入；允许最终为零。
	return int(max(0, round(floor(max(1.0, stat * ratio)) * (1.0 + damage_percent / 100.0))))


static func has_growth(context: Dictionary, state: Dictionary) -> bool:
	if not context.get("full_health_growth", []).empty():
		return true
	for condition in context.get("conditional", []):
		if condition.when in ["temp_stats_on_hit", "temp_stats_on_dodge"]:
			return true
	for item in state.get("items", []):
		if not item.get("full_health_growth", []).empty():
			return true
		for condition in item.get("conditional", []):
			if condition.when in ["temp_stats_on_hit", "temp_stats_on_dodge"]:
				return true
	return false


static func stacks(condition: Dictionary, events: Dictionary, portion: float = 1.0) -> float:
	var key = "hits" if condition.when == "temp_stats_on_hit" else "dodges"
	var timing = events.get("timing", {}).get(key, {})
	var average = timing.get("opening" if portion < 1.0 else "average", clamp(portion, 0.0, 1.0) * 0.5)
	return events.get(key, 0.0) * average + (events.get("self_hits", 0.0) * portion * 0.5 if key == "hits" else 0.0)


static func count(trigger: String, events: Dictionary) -> float:
	match trigger:
		"dmg_when_pickup_gold": return events.get("pickups", 0.0)
		"dmg_when_heal": return events.get("heals", 0.0)
		"dmg_on_dodge": return events.get("dodges", 0.0)
		"dmg_when_death": return events.get("kills", 0.0)
		"explode_on_hit": return events.get("hits", 0.0) + events.get("self_hits", 0.0)
		"explode_on_consumable": return events.get("consumables", 0.0)
	return 0.0


static func output(planner, profiles: Array, events: Dictionary, delta: Dictionary, bonuses: Dictionary, future: Dictionary = {}, ramp: float = 0.0) -> Dictionary:
	var context = planner._context
	var profile = context.get("combat_profile", {})
	var density = profile.get("density", 2.0)
	var availability = events.get("availability", 0.65)
	var clear = 0.0
	var boss = 0.0
	var death_shots = 0.0
	var grouped = {}
	for effect in profiles:
		if effect.trigger in ["projectiles_on_death", "alien_eyes"]:
			# 环射按附近目标的角宽折算；定时齐射也能命中单独的首领。
			var reach = max(0.0, effect.reach + delta.get("range", 0.0) + future.get("range", 0.0))
			var nearby = density * min(1.0, pow(reach / 250.0, 2))
			var hit = min(1.0, nearby)
			if not effect.aimed:
				hit *= Combat.hit_chance(1.0 - PI, min(reach, 180.0), 18.0, max(0.0, nearby - 1.0))
			var damage = planner.projected_damage(effect.model, delta, future, ramp, bonuses)
			var per_shot = planner._effective_hit(effect.model, damage, delta, bonuses, future)
			per_shot += planner._projectile_chain_damage(effect.model, damage, delta, bonuses, future)
			var seconds = max(1.0, events.get("seconds", 60.0))
			if effect.trigger == "alien_eyes":
				var shots = floor(seconds / effect.cooldown) * effect.count / seconds * availability
				clear += shots * hit * per_shot
				var boss_hit = 1.0 if effect.aimed else Combat.hit_chance(1.0 - PI, min(reach, 180.0), 36.0)
				boss += shots * boss_hit * planner._expected_hit(effect.model, damage, delta, bonuses, future)
			else:
				death_shots += events.get("kills", 0.0) / seconds * effect.count * availability * hit * per_shot
			continue
		var rate = count(effect.trigger, events) / max(1.0, events.get("seconds", 60.0))
		if rate <= 0 or effect.chance <= 0:
			continue
		if effect.has("model"):
			# 缺血爆炸另有动态半径，目前不把未知的缺血轨迹当成确定收益。
			if effect.get("missing_health", false):
				continue
			var damage = planner.projected_damage(effect.model, delta, future, ramp, bonuses)
			var radius = effect.scale * max(0.1, 1.0 + (context.get("explosion_size", 0.0) + bonuses.get("explosion_size", 0.0)) / 100.0)
			var cover = 1.0 + density * min(1.0, radius * radius * 0.25)
			clear += rate * effect.chance * availability * cover * planner._effective_hit(effect.model, damage, delta, bonuses, future)
			boss += rate * effect.chance * availability * planner._expected_hit(effect.model, damage, delta, bonuses, future) * min(1.0, cover / (1.0 + density))
		else:
			var stat = context.stats.get(effect.stat, 0.0) + delta.get(effect.stat, 0.0) + future.get(effect.stat, 0.0)
			var pct = context.stats.percent_damage + delta.get("percent_damage", 0.0) + future.get("percent_damage", 0.0) + ramp
			var damage = stat_damage(stat, effect.ratio, pct)
			if effect.trigger == "dmg_on_dodge":
				damage = max(1, damage)
			# 同一次事件先合计全部效果，随后只受一次目标护甲。分布超过 64 项时合并为期望，限制开销。
			var distribution = grouped.get(effect.trigger, {0: 1.0})
			var next = {}
			for value in distribution:
				next[value] = next.get(value, 0.0) + distribution[value] * (1.0 - effect.chance)
				next[value + damage] = next.get(value + damage, 0.0) + distribution[value] * effect.chance
			if next.size() > 64:
				var mean = 0.0
				for value in next:
					mean += value * next[value]
				next = {mean: 1.0}
			grouped[effect.trigger] = next
	for trigger in grouped:
		var rate = count(trigger, events) / max(1.0, events.get("seconds", 60.0)) * availability
		for damage in grouped[trigger]:
			if damage <= 0:
				continue
			var probability = grouped[trigger][damage]
			clear += rate * probability * planner._effective_hit({"can_crit": false}, damage, {}, bonuses, {})
			if trigger != "dmg_when_death":
				boss += rate * probability * damage / (1.0 + density)
	return {"clear": clear + death_shots, "boss": boss, "death_shots": death_shots}
