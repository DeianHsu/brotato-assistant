extends Reference


# accuracy 是弧度散布的反量。目标半径和交战距离是估计，不是命中率实测值。
static func hit_chance(accuracy: float, distance: float, radius: float, neighbours: float = 0.0, projectile_spread: float = 0.0) -> float:
	var spread = max(0.0, 1.0 - accuracy)
	var extra = max(0.0, projectile_spread)
	if spread + extra <= 0.0001:
		return 1.0
	var angle = atan(radius / max(radius, distance))
	var direct = 1.0
	# 瞄准随机角与每颗弹丸的随机角相加，按两个均匀分布的卷积计算。
	if angle < spread + extra:
		direct = angle / max(spread, extra) if angle <= abs(spread - extra) else 1.0 - pow(spread + extra - angle, 2.0) / (4.0 * spread * extra)
	return 1.0 - pow(1.0 - direct, 1.0 + max(0.0, neighbours))


static func hits_to_kill(health: float, damage: float, crit_damage: float, chance: float) -> float:
	if chance <= 0.0 or crit_damage == damage:
		return max(1.0, ceil(health / max(1.0, damage)))
	if chance >= 1.0:
		return max(1.0, ceil(health / max(1.0, crit_damage)))
	# 少次命中的原生伤害断点精确求期望；高血目标使用平均伤害近似，限制热路径开销。
	if health > min(damage, crit_damage) * 8.0:
		return max(1.0, ceil(health / max(1.0, lerp(damage, crit_damage, chance))))
	var alive = [1.0]
	var shots = 0.0
	for n in range(8):
		var next = []
		next.resize(n + 2)
		for i in range(next.size()):
			next[i] = 0.0
		for crits in range(alive.size()):
			if n * damage + crits * (crit_damage - damage) < health:
				shots += alive[crits]
				next[crits] += alive[crits] * (1.0 - chance)
				next[crits + 1] += alive[crits] * chance
		alive = next
	return max(1.0, shots)


static func effective_hit(damage: float, critical: float, chance: float, targets: Array, health_factor: float = 1.0) -> float:
	if targets.empty():
		return lerp(damage, critical, chance)
	var health_total = 0.0
	var hits_total = 0.0
	for target in targets:
		var health = max(1.0, round(target.hp * health_factor))
		var armor = target.get("armor", 0.0)
		health_total += target.weight * health
		hits_total += target.weight * hits_to_kill(health, max(1.0, damage - armor), max(1.0, critical - armor), chance)
	# 同一波的总有效伤害除以总命中次数。耐久敌人占用的攻击按次数进入分母。
	return health_total / max(0.001, hits_total)


# 每个敌人只能首次触发。按命中率估计首次标记的时间，并截去首击已消耗的生命。
# sources 中每项为每秒有效命中数和该次伤害，普通敌群会分摊火力。
static func marked_share(sources: Array, hp: float, armor: float, dps: float, targets: float, window: float, wave_seconds: float) -> float:
	var rate = 0.0
	var remaining = 0.0
	for hit in sources:
		rate += hit.x
		remaining += hit.x * max(0.0, 1.0 - max(1.0, hit.y - armor) / hp)
	if rate <= 0.0 or remaining <= 0.0 or dps <= 0.0:
		return 0.0
	var lifetime = min(wave_seconds, hp * targets / dps)
	var active = min(window, lifetime)
	var frequency = rate / targets
	# 在目标存活期间积分“首次命中发生在最近 active 秒”的概率。
	var covered = active - exp(-frequency * (lifetime - active)) * (1.0 - exp(-frequency * active)) / frequency
	return clamp(covered / lifetime, 0.0, remaining / rate)


static func melee_clear_ratio(weapon: Dictionary, observed: Dictionary, density: float) -> float:
	var baseline = weapon.get("melee_trigger_targets", 0.0)
	if baseline <= 0.0:
		return 1.0
	var sample = observed.get("melee_contacts", {}).get(weapon.family, {})
	if observed.get("seconds", 0.0) < 20.0 or sample.get("swings", 0) < 8:
		return 1.0
	# 混入八次普通挥击的先验；稀疏波次限制可同时触发的敌人数。
	var targets = (sample.hits + 8.0 * baseline) / (sample.swings + 8.0)
	return min(targets, 1.0 + density) / baseline


static func wandering_bot_slow(bots: float, enemy_speed: float) -> float:
	# 按每圈一次局部接触估值。原生减 250 点移速，单次上限为敌速的 90%，每秒恢复 300 点。
	var removal = min(250.0, enemy_speed * 0.9)
	var orbit_seconds = TAU / 2.25
	return clamp(bots * removal * removal / (2.0 * 300.0 * orbit_seconds * max(100.0, enemy_speed)), 0.0, 0.3)


static func crowd_growth(observed: Dictionary, activity: String = "engaged") -> float:
	if observed.get("seconds", 0.0) < 20.0 or observed.get(activity, 0.0) < 0.6:
		return 0.0
	var late = observed.get("late_enemies", 0.0)
	var early = observed.get("early_enemies", 0.0)
	return max(0.0, late - early * 1.35 - 3.0) / late if late >= 12.0 else 0.0


static func impact_coverage(explosions: Array, density: float, size: float) -> Vector2:
	# 命中成功触发爆炸时，由爆炸代替直接命中。多种爆炸各自判定。
	var direct = 1.0
	var splash = 0.0
	var primary = 0.0
	for effect in explosions:
		var chance = clamp(effect.x, 0.0, 1.0)
		var radius = max(0.1, effect.y * (1.0 + size / 100.0))
		direct *= 1.0 - chance
		primary += chance
		splash += chance * density * min(1.0, radius * radius * 0.25)
	return Vector2(direct + primary + splash, direct + primary)


static func calibration(observed: Dictionary) -> float:
	# 更换过装备仍可观测积怪，但只有同装备的预测才能用来校准伤害。
	if observed.get("predicted_clear", 0.0) <= 0.0 or crowd_growth(observed) <= 0:
		return 1.0
	return clamp(observed.get("effective_dps", 0.0) / max(1.0, observed.get("predicted_clear", 0.0)), 0.45, 1.0)
