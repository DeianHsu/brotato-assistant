extends Reference

static func needs_movement(context: Dictionary, state: Dictionary) -> bool:
	if not context.get("can_attack_while_moving", true):
		return true
	for condition in context.get("conditional", []):
		if condition.when in ["temp_stats_while_not_moving", "temp_stats_while_moving"]:
			return true
	for item in state.get("items", []):
		for condition in item.get("conditional", []):
			if condition.when in ["temp_stats_while_not_moving", "temp_stats_while_moving"]:
				return true
	return false


static func blend(left: Dictionary, right: Dictionary, weight: float) -> Dictionary:
	var result = left.duplicate()
	for key in result:
		if not right.has(key):
			continue
		if result[key] is int or result[key] is float:
			result[key] = lerp(left[key], right[key], weight)
		elif result[key] is Dictionary and right[key] is Dictionary:
			result[key] = blend(left[key], right[key], weight)
	return result

# 只保存连续状态段，不模拟玩家路径。无观测时的 15% 站定是假设，不是角色指令。
static func behavior(context: Dictionary) -> Dictionary:
	var duration = max(1.0, context.get("wave_duration", 60.0))
	var observed = context.get("battle_observation", {})
	var segments = observed.get("movement_segments", [])
	var sampled = observed.get("seconds", 0.0) >= 20 and not segments.empty() and not observed.get("movement_limited", false)
	if not sampled:
		var share = clamp(context.get("still_share", 0.15), 0.0, 1.0)
		segments = []
		var elapsed = 0.0
		while elapsed < duration:
			var window = min(10.0, duration - elapsed)
			segments.append({"moving": false, "seconds": window * share})
			segments.append({"moving": true, "seconds": window * (1.0 - share)})
			elapsed += window
	var result = []
	var total = 0.0
	var still = 0.0
	var moving = 0.0
	var late_still = 0.0
	var index = 0
	while total < duration and index < 2048:
		var segment = segments[index % segments.size()]
		var seconds = min(max(0.0, segment.seconds), duration - total)
		result.append({"moving": segment.moving, "seconds": seconds})
		total += seconds
		if segment.moving:
			moving += seconds
		else:
			still += seconds
			late_still += clamp(total - duration * 0.5, 0.0, seconds)
		index += 1
	var combat_still = still
	if sampled and context.get("automatic_battle", false) and context.get("can_attack_while_moving", true) and context.get("threat", "") in ["elite", "horde"]:
		# 精英或暴走前按后半波的站定机会估计战斗收益，连续状态段仍用于原生计时效果。
		combat_still = min(still, late_still * 2.0)
	return {"segments": result, "still": still / duration, "moving": moving / duration, "combat_still": combat_still / duration, "observed": sampled}


static func gold_ticks(wallet: float, segments: Array, rules: Array, base_income: float = 0.0, interval: float = 1.0) -> Dictionary:
	var duration = 0.0
	for segment in segments:
		duration += segment.seconds
	var base_rate = max(0.0, base_income) / max(1.0, duration)
	var received = 0.0
	var accrued = 0.0
	var income = 0
	var area = 0.0
	wallet = int(max(0.0, wallet))
	for segment in segments:
		var elapsed = 0.0
		var ticks = int(floor((segment.seconds + 0.000001) / interval))
		for tick in range(ticks + 1):
			var until = min(segment.seconds, (tick + 1) * interval)
			area += wallet * (until - elapsed)
			accrued += base_rate * (until - elapsed)
			wallet += int(accrued) - int(received)
			received = accrued
			elapsed = until
			if tick >= ticks:
				break
			for rule in rules:
				if rule.moving != segment.moving:
					continue
				var value = wallet * rule.percent / 100.0
				var amount = int(min(rule.get("cap", INF), max(1.0, abs(value))))
				amount = -min(wallet, amount) if value < 0 else amount
				wallet += amount
				income += amount
	return {"income": income, "wallet": wallet, "average_wallet": area / max(1.0, duration)}


static func settlement(effects: Dictionary, enemies: float, trees: float, horde: bool = false) -> float:
	var pacifist = round(max(0.0, enemies) * effects.get("pacifist", 0.0) / 100.0)
	if horde:
		pacifist = int(pacifist / 2.0)
	return pacifist + max(0.0, trees) * effects.get("cryptid", 0.0) + max(0.0, enemies) * effects.get("materials_per_living_enemy", 0.0)


static func carry_share(segments: Array, lifetime: float) -> float:
	var moving = 0.0
	var carried = 0.0
	var previous_still = false
	for segment in segments:
		if segment.moving:
			moving += segment.seconds
			if previous_still:
				carried += min(segment.seconds, max(0.0, lifetime) * 0.5)
		previous_still = not segment.moving and segment.seconds > 0
	return carried / max(0.001, moving)


static func first_seconds(segments: Array, seconds: float) -> Array:
	var result = []
	for segment in segments:
		if seconds <= 0:
			break
		var count = min(seconds, segment.seconds)
		result.append({"moving": segment.moving, "seconds": count})
		seconds -= count
	return result


static func full_health_growth(profiles: Array, count: float, permanent_only: bool = false) -> Dictionary:
	var result = {}
	for profile in profiles:
		if permanent_only and profile.get("temporary", false):
			continue
		var times = max(0.0, count)
		if profile.get("cap", INF) < INF and profile.value > 0:
			times = min(times, ceil(float(profile.cap) / profile.value))
		var stat = profile.get("stat", "max_hp")
		result[stat] = result.get(stat, 0.0) + times * profile.value
	return result
