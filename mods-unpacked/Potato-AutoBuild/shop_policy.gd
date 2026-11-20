extends Reference

const Planner = preload("res://mods-unpacked/Potato-AutoBuild/planner.gd")
const Budget = preload("res://mods-unpacked/Potato-AutoBuild/analysis_budget.gd")
const Distribution = preload("res://mods-unpacked/Potato-AutoBuild/shop_distribution.gd")

var route = "mixed"
var stat = ""
var routes = []
var unit_gain = 0.0


func investment(p, state, score, direction, units = 1) -> float:
	var attribute = p._routes[direction][1]
	var amount = 4.0 * p._context.get("growth", {}).get(attribute, 0.0) * units
	if amount == 0:
		return 0.0
	var invested = p._copy(state)
	invested.bonus_stats[attribute] = invested.bonus_stats.get(attribute, 0.0) + amount
	return p.gains(score, p.evaluate(invested, direction)).combat


func choose_route(p, state, score, incumbent) -> String:
	if p._context.get("pacifist", false):
		return "pacifist"
	var favored = incumbent if incumbent in routes and p._route_allowed(incumbent) else "mixed"
	var recovered = p._focus_route(routes, incumbent)
	if recovered != "":
		favored = recovered
	var switch_gain = 1.25 if p._focus_share(favored) > 0.0 else 1.1
	var best = investment(p, state, score, favored)
	for direction in routes:
		if direction == favored or not p._route_allowed(direction):
			continue
		var gain = investment(p, state, score, direction)
		if gain <= best + 0.01:
			continue
		# 对已有方向用第二次同品质投入复核，避免仅因伤害取整换线。
		if favored != "mixed" and (gain < best * switch_gain or investment(p, state, score, direction, 2) <= investment(p, state, score, favored, 2) + 0.01):
			continue
		best = gain
		favored = direction
	return favored


func runway(p, score) -> float:
	var d = score.defense
	return d.opening_hp + min(0.0, d.recovery - d.incoming) * p._context.get("wave_duration", 60.0) - d.mean_hit


func needs_recovery(p, score) -> bool:
	var defense = score.defense
	if defense.incoming <= defense.recovery or defense.mean_hit <= 0:
		return false
	# 按预计受击次数的一倍标准差估计集中受击余量。
	var hits = defense.incoming * p._context.get("wave_duration", 60.0) / defense.mean_hit
	return runway(p, score) < defense.mean_hit * sqrt(max(1.0, hits))


func elite_exposure(p, score) -> float:
	if p._context.get("future_shop", false) or not p._context.get("burst", {}).get("next", false):
		return 0.0
	var d = score.defense
	# 两次重击之间还可能挨一次普通接触。按缺少的开波生命比例比较交换代价。
	return max(0.0, d.mean_hit - d.burst_margin) / max(1.0, d.opening_hp)


func crowd_growth(p) -> float:
	if p._context.get("pacifist", false) or p._context.get("future_shop", false):
		return 0.0
	var observed = p._context.get("battle_observation", {})
	if p._context.get("weapons", []).empty() and observed.get("events", {}).get("hits", 0) > 0:
		for event in p._context.get("events", []):
			if event.trigger == "explode_on_hit":
				# 受击爆炸没有武器瞄准记录，用敌人在场比例判断积怪样本。
				return p.Combat.crowd_growth(observed, "enemy_presence")
	return p.Combat.crowd_growth(observed)


func crowd_exposure(score) -> float:
	# 清不掉的敌群需要靠移动拉开，接触后损失的生命比例随护甲与生命变化。
	var d = score.defense
	return (1.0 - score.clear_ready) * (100.0 / d.movement) * (1.0 + d.mean_hit / d.opening_hp)


func survival_crowd(p) -> float:
	var c = p._context
	if c.get("future_shop", false):
		return 0.0
	var observation = c.get("battle_observation", {})
	var pressure = p.Combat.crowd_growth(observation, "enemy_presence")
	var limit = c.get("observed_enemy_limit", 0)
	if limit > 0 and observation.get("seconds", 0.0) >= 20.0 and observation.get("enemy_presence", 0.0) >= 0.6:
		# 前半波就已积怪时，活敌增长不大也可能接近场上上限。
		var occupied = observation.get("late_enemies", 0.0) / limit
		pressure = max(pressure, clamp((occupied - 0.75) / 0.25, 0.0, 1.0))
	return pressure


func scales_with(p, weapon, attribute) -> bool:
	return p._scales_with(weapon, attribute)


func assess(p, before, state, offer, original_growth, allow_switch = false) -> Dictionary:
	var score = p.evaluate(state, route)
	var gain = p.gains(before, score)
	var weapon = offer.get("weapon", {})
	var aligned = not weapon.empty() and scales_with(p, weapon, stat)
	var growth = investment(p, state, score, route) - original_growth
	var direction = route
	var coverage = min(before.clear_ready, before.boss_ready)
	var supplies_damage = before.need_damage and gain.combat > 0.01 and (score.clear_ready > before.clear_ready + 0.001 or score.boss_ready > before.boss_ready + 0.001)
	var defense = before.defense
	var margin = runway(p, before)
	var next_margin = runway(p, score)
	var recovery = margin < 0 and (next_margin >= 0 or next_margin - margin >= max(defense.mean_hit, -0.25 * margin))
	var hit_note = ""
	if needs_recovery(p, before):
		var opening_hits = max(0, int(ceil(defense.opening_hp / defense.mean_hit)) - 1)
		var improved_hits = max(0, int(ceil(score.defense.opening_hp / max(0.01, score.defense.mean_hit))) - 1)
		if improved_hits > opening_hits and next_margin > margin:
			hit_note = "补持续失血时的防护，预计可承受接触伤害 %d → %d 次" % [opening_hits, improved_hits]
	var protection = elite_exposure(p, before) - elite_exposure(p, score)
	var rescue = recovery or hit_note != "" or protection > 0.001
	var role = ""
	if not weapon.empty():
		if aligned:
			role = "补主力"
		elif hit_note != "":
			role = hit_note
		elif rescue or (route == "pacifist" and gain.survival > 0.01):
			role = "补生存或控场缺口"
		elif growth > max(1.0, original_growth * 0.25) and gain.immediate > 0:
			role = "强化已有装备的属性联动"
		elif supplies_damage:
			role = "补下波输出缺口"
		# 明显改善实战的可见换装，才比较换线后整套装备的属性收益。
		if allow_switch and not aligned and gain.combat > max(1.0, original_growth) and not score.need_damage:
			var alternative = choose_route(p, state, score, route)
			if alternative != route and scales_with(p, weapon, p._routes[alternative][1]):
				direction = alternative
				growth = investment(p, state, score, direction) - original_growth
				role = "转向" + p._routes[direction][0]
	elif gain.survival > 0.01:
		role = "提高生存余量"
	elif gain.economy > 0.01 or gain.future > 0.01:
		if gain.survival >= -0.01 or rescue or p.pacifist_survival_risk() == 0:
			role = "投资后续商店或成长"
	elif supplies_damage or growth > 0.01 or (gain.combat > 0.01 and gain.survival >= -0.01):
		role = "补强现有装备"
	if p._context.wave + 1 >= p._context.final_wave and weapon.empty() and gain.immediate > 0:
		role = "补强最后一波"
	# 下波缺口未补齐时，未来一次属性升级的假设不能否决明确的即战力改善。
	var growth_weight = coverage if supplies_damage else 1.0
	var forecast = max(growth * growth_weight, -0.25 * gain.combat) if supplies_damage else growth
	var net = gain.score + forecast - state.get("hurdle", 0.0)
	var focus = p._focus_share(route)
	var focus_cost = 0.0
	if focus > 0.0 and direction == route:
		if weapon.empty():
			focus_cost = p._secondary_damage_cost(route, offer.get("item", {}).get("stats", {}), gain, focus)
		elif not aligned and not rescue and not (supplies_damage and score.current_clear > 1.1 * before.current_clear):
			var action = state.actions.back()
			var paid = action.price if action.kind != "bundle" else max(0, action.steps[1].price - action.steps[0].get("refund", 0))
			var price_share = paid / p._income_reference()
			focus_cost = max(0.0, original_growth) * min(1.0, price_share)
			var core = p._route_weapon_count(p._context.weapons, route)
			if p._route_weapon_count(state.weapons, route) < core:
				focus_cost += max(0.0, gain.combat) * focus
	net -= focus_cost
	# 两种风险都以比例计，下降 0.1 折算为 8 个商店评分点，与原有输出和生存收益相加。
	var risk_gain = 80.0 * (protection + crowd_growth(p) * (crowd_exposure(before) - crowd_exposure(score)))
	if route == "pacifist":
		# 留敌构筑需要绕开逐渐挤满场地的敌人，清场评分无法体现这项收益。
		risk_gain += 40.0 * survival_crowd(p) * (100.0 / defense.movement - 100.0 / score.defense.movement)
	net += risk_gain
	if p._context.hp_shop and p._context.get("threat", "") == "elite" and gain.immediate < 0 and role == "投资后续商店或成长":
		# 生命商店用生存余量付款。精英前战力不足时，后续材料只能按兑现机会计分。
		net -= max(0.0, gain.economy) * (1.0 - coverage)
	if weapon.empty() and not p._context.hp_shop and gain.economy > 0 and not state.actions.empty():
		# 折扣模型已扣其购价，其他经济道具只把可再花掉的净收入计入收益。
		var already_paid = max(0.0, score.discount.invested - before.discount.invested)
		var cost = max(0.0, state.actions.back().price - already_paid)
		var horizon = max(1, p._context.final_wave - p._context.wave - 1)
		net -= 100.0 * cost / (p._income_reference() * horizon)
	if role == "" or (state.get("sold_weapon", false) and gain.immediate < -0.001):
		net = -INF
	return {"state": state, "score": score, "surplus": net, "route": direction, "role": role, "growth": growth, "risk_gain": risk_gain, "focus_cost": focus_cost, "urgent": rescue or supplies_damage, "main": aligned or direction != route}


func plan_shop(c, previous, p, work):
	routes = p.prepare(c, work)
	var initial = p.initial_state()
	var before = p.evaluate(initial, "pacifist" if c.get("pacifist", false) else "mixed")
	route = choose_route(p, initial, before, previous)
	stat = p._routes[route][1]
	unit_gain = investment(p, initial, before, route)
	p._priority = p._stage_priority(before)
	var hold = {"state": initial, "score": before, "surplus": 0.0, "route": route, "role": "留钱", "growth": 0.0}
	var candidates = []
	for offer in c.offers:
		for state in p._transitions(initial, offer):
			var ready = Budget.checkpoint(work)
			if ready is GDScriptFunctionState:
				ready = yield(ready, "completed")
			if not ready:
				return {}
			var candidate = assess(p, before, state, offer, unit_gain, true)
			annotate(state, before, candidate.score)
			candidates.append(candidate)
			var bonuses = offer.get("item", {}).get("bonuses", {})
			var discounts = bonuses.get("items_price", 0) < 0 or bonuses.get("weapons_price", 0) < 0
			var prepares = discounts or state.slots > initial.slots or state.weapons.size() < initial.weapons.size() or not state.consumed.empty()
			if not prepares:
				continue
			for other in c.offers:
				if other.index == offer.index:
					continue
				for paired in p._transitions(state, other):
					var budget_ready = Budget.checkpoint(work)
					if budget_ready is GDScriptFunctionState:
						budget_ready = yield(budget_ready, "completed")
					if not budget_ready:
						return {}
					var pair = assess(p, before, paired, other, unit_gain, true)
					annotate(paired, candidate.score, pair.score)
					candidates.append(pair)
	work.visible_done = OS.get_ticks_usec()
	var future = {"budget": 0, "reserve": 0, "target": "无目标", "keep": [], "release": [], "target_value": 0.0}
	var immediate = c.wave == 1 and not candidates.empty()
	var best = select_purchase(candidates, hold, future, p)
	if not immediate or best.state.actions.empty():
		future = commitments(c, p, initial, work)
		if future is GDScriptFunctionState:
			future = yield(future, "completed")
		if future.empty():
			return {}
		best = select_purchase(candidates, hold, future, p)
	var result = p.finish_candidate(best, before, previous, routes, work)
	if result is GDScriptFunctionState:
		result = yield(result, "completed")
	if result.empty():
		return {}
	result.refresh_unlocks = result.unlocks.duplicate()
	result.refresh_locks = future.keep
	if not (immediate and not result.actions.empty()):
		result.future_shop = future
		result.refresh_unlocks = future.release
		result.unlocks = future.release
		result.locks = future.keep
	else:
		result.locks = []
		result.unlocks = []
		result.refresh_unlocks = []
	if c.wave + 1 >= c.final_wave and best.state.actions.empty():
		result.reasons.append("最后一波前，本页没有选中的补强，继续按刷新收益决定是否离店。")
	else:
		result.reasons.append("%s；按%s投入一次普通属性升级，本次配装比进店多获 %+.2f 分。购后剩余 %d。" % [best.role, p._routes[result.route][0], best.growth, result.state.money])
	if abs(best.get("risk_gain", 0.0)) >= 0.01:
		result.reasons.append("按下波重击余量和上波积怪调整本次交易 %+.2f 分。" % best.risk_gain)
	if best.get("focus_cost", 0.0) > 0.01:
		result.reasons.append("跨系投入占用主力预算，扣减 %.2f 分。" % best.focus_cost)
	var noted = {}
	for candidate in candidates:
		var slot = candidate.state.used.back()
		if candidate.state.used.size() != 1 or slot in best.state.used or noted.has(slot):
			continue
		var explanation = ""
		if candidate.role == "":
			explanation = "未补主力成长或下波缺口"
			if route == "pacifist" and candidate.score.defense.pressure > before.defense.pressure:
				explanation = "会降低本波生存余量"
		elif candidate.surplus == -INF:
			explanation = "出售原武器会降低本波即时战力，保留原装备"
		elif candidate.surplus <= 0 and candidate.risk_gain < -0.01:
			explanation = "重击或积怪风险 %+.2f 分，计入后净收益 %+.2f 分" % [candidate.risk_gain, candidate.surplus]
		elif candidate.surplus > 0 and candidate.state.money < future.reserve and not candidate.urgent:
			explanation = "付款后余 %d，目标预算需保留 %d" % [candidate.state.money, future.reserve]
		if explanation != "":
			noted[slot] = true
			result.reasons.append(candidate.state.actions[0].name + "：" + explanation)
	if best.state.actions.empty() and initial.weapons.size() < initial.slots:
		result.reasons.append("保留空槽：本页武器未提供值得付款的主力成长或下波补强。")
	return result


func annotate(state, before, score):
	var i = state.actions.size() - 1
	var action = state.actions[i].duplicate()
	action.before = before
	action.after = score
	action.threshold = state.hurdle - action.previous_hurdle
	state.actions[i] = action


func select_purchase(candidates, hold, future, p):
	var best = hold
	var best_defense = hold
	var needs_defense = p.pacifist_survival_risk() > 0
	for candidate in candidates:
		var defensive = needs_defense and candidate.score.defense.pressure < hold.score.defense.pressure - 0.0001
		if candidate.surplus <= best.surplus + 0.001 and (not defensive or candidate.surplus <= best_defense.surplus + 0.001):
			continue
		if candidate.state.money < future.reserve and not candidate.urgent:
			# 眼前更好的主力可以直接兑现原本为升级预留的材料。
			if p.next_shop(candidate.state, candidate.route).money < future.get("commitment", INF) and (not candidate.main or candidate.surplus < future.target_value):
				continue
		if candidate.surplus > best.surplus + 0.001:
			best = candidate
		if defensive and candidate.surplus > best_defense.surplus + 0.001:
			best_defense = candidate
	return best_defense if best_defense.surplus > 0 else best


func commitments(c, p, initial, work):
	var result = {"budget": 0, "reserve": 0, "target": "无目标", "keep": [], "release": [], "target_value": 0.0}
	var positions = {}
	for offer in c.offers:
		if offer.get("auto_locked", false) and not positions.has(offer.index):
			result.release.append({"index": offer.index, "name": label(offer), "reason": "已到下一商店，旧锁到期" if offer.get("auto_lock_wave", c.wave) < c.wave else "当前目标不再值得占用预算"})
			positions[offer.index] = true
	if c.wave + 1 >= c.final_wave or not c.get("resources", {}).get("supported", true):
		return result
	var projected = p.next_shop(initial, route)
	result.budget = projected.money
	var future = c.duplicate()
	future.wave += 1
	future.future_shop = true
	future.offers = []
	future.money = projected.money
	var evaluator = Planner.new()
	evaluator.prepare(future, {"cache": true})
	# 特殊属性路线可能来自眼前商品，下一店仍沿用这次已选的方向。
	evaluator._routes = p._routes
	var funded = projected.state
	var balance = funded.money
	var lock_cost = 0
	var names = []
	var selected = {}
	# 先兑现能买的手动锁，再从真实可锁商品中逐笔挑选；每件共用上一笔的余款和装备。
	for manual in [true, false]:
		while true:
			var before = evaluator.evaluate(funded, route)
			var growth = investment(evaluator, funded, before, route)
			var best = {}
			for offer in c.offers:
				var player_lock = offer.get("locked", false) and not offer.get("auto_locked", false)
				if manual != player_lock or selected.has(offer.index):
					continue
				if not manual and (not offer.get("lockable", false) or offer.get("released_here", false) or offer.get("auto_lock_wave", c.wave) < c.wave):
					continue
				if not manual and not offer.get("auto_locked", false) and offer.price <= initial.money:
					continue
				for state in evaluator._transitions(funded, offer):
					var ready = Budget.checkpoint(work)
					if ready is GDScriptFunctionState:
						ready = yield(ready, "completed")
					if not ready:
						return {}
					var option = assess(evaluator, before, state, offer, growth)
					option.surplus += funded.get("hurdle", 0.0)
					if option.surplus > 0.001 and (best.empty() or option.surplus > best.value):
						best = {"offer": offer, "state": state, "value": option.surplus}
			if best.empty():
				break
			var chosen = best.offer
			selected[chosen.index] = true
			names.append(label(chosen))
			result.target_value = max(result.target_value, best.value)
			funded = best.state
			lock_cost = max(lock_cost, balance - funded.money)
			if not manual:
				result.keep.append({"index": chosen.index, "price": chosen.price, "name": label(chosen), "gain": best.value, "locked": chosen.get("locked", false)})
				for release in result.release.duplicate():
					if release.index == chosen.index:
						result.release.erase(release)
	result.locked_cost = lock_cost
	if lock_cost == 0 and work.has("catalogue"):
		var generation = future.duplicate()
		generation.weapons = funded.weapons
		generation.stats = future.stats.duplicate()
		generation.stats.luck = projected.stats.get("luck", 0.0)
		var catalogue = work.catalogue.call_func(generation)
		var targets = reserve_targets(evaluator, funded, catalogue, work)
		if targets is GDScriptFunctionState:
			targets = yield(targets, "completed")
		if work.get("cancelled", false):
			return {}
		if not targets.empty():
			targets.sort_custom(self, "cheaper")
			var median = targets[int(targets.size() / 2)]
			lock_cost = median.price
			result.target_value = median.value
			names.append(median.name)
	result.commitment = lock_cost + int(ceil(evaluator._health_floor())) if c.hp_shop and lock_cost > 0 else lock_cost
	if not names.empty():
		result.target = PoolStringArray(names).join("、")
		# 生命的价格按角色生命获取倍率结算，底线在每笔 buy 中检查。
		result.reserve = int(clamp(result.commitment - (balance - initial.money), 0, initial.money))
		if not c.hp_shop and (c.get("gold_start_pct", 0) != 0 or not c.get("resources", {}).get("conversions", []).empty()):
			var low = 0
			var high = int(initial.money)
			while low < high:
				var probe = p._copy(initial)
				probe.money = int((low + high) / 2)
				if p.next_shop(probe, route).money >= result.commitment:
					high = probe.money
				else:
					low = probe.money + 1
			result.reserve = low
	return result


func label(offer):
	return offer.item.name if offer.get("kind", "weapon") == "item" else offer.weapon.name


func cheaper(left, right):
	return left.price < right.price


func more_likely(left, right):
	return left.weight > right.weight


func reserve_targets(p, state, catalogue, work):
	var before = p.evaluate(state, route)
	var growth = investment(p, state, before, route)
	var rows = []
	var needs_defense = route == "pacifist" or needs_recovery(p, before) or elite_exposure(p, before) > 0
	for row in catalogue:
		if row.price <= state.money and row.weight > 0 and (row.kind == "weapon" or needs_defense):
			rows.append(row)
	rows.sort_custom(self, "more_likely")
	var targets = []
	for row in rows:
		var ready = Budget.checkpoint(work)
		if ready is GDScriptFunctionState:
			ready = yield(ready, "completed")
		if not ready:
			work.cancelled = true
			break
		var offer = describe(row, work)
		if offer.get("blocked", "") != "" or not offer.get("weapon", {}).get("unmeasured", []).empty():
			continue
		if offer.kind == "weapon" and not scales_with(p, offer.weapon, stat) and route != "pacifist":
			continue
		var next = p.buy(state, offer)
		if next.empty():
			continue
		var assessed = assess(p, before, next, offer, growth)
		if assessed.surplus > 0.001 and (assessed.main or assessed.urgent or (route == "pacifist" and assessed.score.defense.pressure < before.defense.pressure)):
			targets.append({"price": max(0, state.money - next.money), "name": label(offer), "value": assessed.surplus})
			if targets.size() == 5:
				break
	return targets


func describe(row, work):
	var offer = work.describe.call_func(row) if row.has("source") else row.duplicate()
	# 原生发布版比较不同类型的货位时可能误匹配。真实货位从零开始，模拟货位统一用负整数。
	offer.index = -1 - str(row.id).hash()
	return offer

static func roll_limit(wave: int) -> int:
	return 1 if wave == 1 else 20


func decide(c: Dictionary, plan: Dictionary, p, catalogue: Array, work: Dictionary = {}):
	var fee = c.get("reroll_price", -1)
	var stop = {"allowed": false, "probability": 0.0, "expected": 0.0, "reason": ""}
	if c.get("refresh_tier", {}).get("manual", false):
		stop.reason = "一次性刷新资源的效果需要手动判断"
		return stop
	var gold = c.get("gold", c.money)
	if fee > gold:
		stop.reason = "刷新需要 %d 材料，当前只有 %d" % [fee, gold]
		return stop
	if fee < 0 or c.fresh_slots <= 0 or c.get("auto_rolls", 0) >= roll_limit(c.wave):
		stop.reason = "刷新不可用、没有可刷货位或已达本店刷新上限"
		return stop
	var state = p.after_refresh(fee)
	var before = p.evaluate(state, route)
	var exposure = elite_exposure(p, before)
	var urgent_defense = exposure > 0.0
	var draining = needs_recovery(p, before)
	var observed_risk = p.pacifist_survival_risk()
	var need_output = before.need_damage
	var reserve = plan.future_shop.reserve
	var income = p._income_reference()
	var defense_reserve = max(reserve, income)
	var crowd_pressure = survival_crowd(p) if c.get("pacifist", false) else 0.0
	var seek_defense = c.get("pacifist", false) and not c.hp_shop and not c.refresh_tier.has("id") and (fee == 0 or c.get("reroll_count", 0) == 0) and plan.actions.empty() and crowd_pressure > 0.0 and state.money - defense_reserve >= income
	var named_price = plan.future_shop.get("commitment", 0)
	var seek_main = named_price > 0 and plan.future_shop.get("locked_cost", 0) == 0 and state.money >= 2 * named_price + reserve and plan.future_shop.target_value > p.purchase_threshold(fee) * 2
	var last = c.wave + 1 >= c.final_wave
	if (not c.hp_shop and state.money < reserve) or (plan.future_shop.get("locked_cost", 0) > 0 and p.next_shop(state, route).money < plan.future_shop.get("commitment", 0)):
		stop.reason = "刷新费用会占用已承诺的购买预算"
		return stop
	var crowd = crowd_growth(p) * (1.0 - before.clear_ready)
	var secondary = not plan.actions.empty() and plan.score.defense.pressure >= plan.before.defense.pressure and (observed_risk > 0 or (crowd > 0 and plan.score.clear_ready <= plan.before.clear_ready))
	var primary_ready = plan.get("main", false) or plan.before.need_damage or plan.get("role", "") == "提高生存余量"
	if not plan.actions.empty() and not urgent_defense and not secondary and (primary_ready or not draining):
		stop.reason = "先兑现当前货架的补强"
		return stop
	if not need_output and not urgent_defense and not draining and observed_risk <= 0 and not last and not seek_main and not seek_defense and (fee > 0 or c.refresh_tier.has("id")):
		stop.reason = "下波输出和生存已够，保留余额等待主力升级"
		return stop
	if catalogue.empty():
		catalogue = work.catalogue.call_func(c)
	var growth = investment(p, state, before, route)
	var values = {}
	var names = {}
	var cost = max(0.0, p.purchase_threshold(fee) - p.gains(plan.before, before).score)
	var visible = max(0.0, plan.surplus)
	# 若本页只提供未来收入，先用即战收益比较是否值得放弃这一页去找防护。
	if observed_risk > 0 and secondary:
		visible = min(visible, max(0.0, p.gains(plan.before, plan.score).immediate))
	var shortfall = clamp(-runway(p, before) / before.defense.opening_hp, 0.0, 1.0) if draining else 0.0
	var pressure = max(max(min(1.0, exposure), shortfall), max(crowd, observed_risk))
	var profile = c.get("combat_profile", {})
	if need_output and profile.get("mean", 0.0) > 0:
		# 峰值可能只持续几秒。开波火力连整波平均生成量也应付不了时，才动用余款搜索。
		var mean_ready = before.clear_ready * profile.clear / profile.mean
		pressure = max(pressure, 1.0 - mean_ready)
	for count in [24, 96]:
		var pages = Distribution.new().pages(c, catalogue, count, work)
		if pages is GDScriptFunctionState:
			pages = yield(pages, "completed")
		if pages.empty():
			return {}
		var total = 0.0
		var hits = 0
		var hit_prices = 0.0
		var best_targets = {}
		for page in pages:
			var best = 0.0
			var best_index = -1
			for index in page:
				if not values.has(index):
					var ready = Budget.checkpoint(work)
					if ready is GDScriptFunctionState:
						ready = yield(ready, "completed")
					if not ready:
						return {}
					var row = catalogue[index]
					values[index] = 0.0
					if row.price > state.money:
						continue
					var offer = describe(row, work)
					var item = offer.get("item", {})
					if offer.get("blocked", "") != "" or not offer.get("weapon", {}).get("unmeasured", []).empty():
						continue
					# 未见货架只估直接可成交的补强，满槽出售等到商品实际出现再计算。
					var next = p.buy(state, offer)
					if next.empty():
						continue
					var assessed = assess(p, before, next, offer, growth)
					var defense_help = urgent_defense and assessed.score.defense.burst_margin > before.defense.burst_margin
					if observed_risk > 0 and assessed.score.defense.pressure < before.defense.pressure:
						defense_help = true
					if seek_defense and assessed.score.defense.pressure < before.defense.pressure - 0.001:
						defense_help = true
					if draining and runway(p, assessed.score) > runway(p, before):
						defense_help = defense_help or assessed.urgent or (not item.empty() and assessed.score.defense.pressure < before.defense.pressure)
					var attacks = assessed.score.combat_utility > before.combat_utility + 0.0001
					var main_upgrade = seek_main and assessed.main and assessed.surplus >= plan.future_shop.target_value
					var useful_now = (need_output or last or fee == 0) and (attacks or assessed.main or (last and not item.empty()))
					if not (defense_help or main_upgrade or useful_now):
						continue
					values[index] = max(0.0, assessed.surplus)
					names[index] = label(offer)
				if values[index] > best:
					best = values[index]
					best_index = index
			if best_index >= 0:
				hit_prices += catalogue[best_index].price
				best_targets[names[best_index]] = best_targets.get(names[best_index], 0) + 1
				hits += 1
			total += best
		var chance = float(hits) / pages.size()
		var expected = total / pages.size()
		var minimum = 0.0 if fee == 0 or last else (0.35 if urgent_defense and c.hp_shop else 0.70)
		# 先留够承诺预算和命中商品的平均价格，再按缺口拿出余款承担搜索费用。
		if pressure > 0 and fee > 0 and hits > 0 and not c.hp_shop and not last:
			var search_money = max(0.0, state.money - reserve - hit_prices / hits) * pressure
			minimum = min(minimum, fee / (float(fee) + search_money))
		if seek_defense and fee > 0 and hits > 0 and not last:
			var defense_money = max(0.0, state.money - defense_reserve - hit_prices / hits) * crowd_pressure
			minimum = min(minimum, fee / (float(fee) + defense_money))
		# 末店和高余额防护搜索首批零命中时，用较大样本复核。
		if count == 24 and (last or seek_defense) and hits == 0 and values.size() < catalogue.size():
			continue
		if count == 24 and hits > 0 and (abs(chance - minimum) < 0.10 or abs(expected - cost - visible) < 0.2):
			continue
		if hits == 0:
			stop.price = fee
			stop.reason = "%d 组候选货架中未发现可成交的补强，刷新费用 %d 材料" % [pages.size(), fee]
			return stop
		var name = ""
		var frequency = 0
		for target in best_targets:
			if best_targets[target] > frequency:
				name = target
				frequency = best_targets[target]
		var allowed = hits > 0 and chance >= minimum and expected > cost + visible + 0.001
		if allowed and not c.hp_shop and not plan.actions.empty() and plan.get("risk_gain", 0.0) > 0.0 and visible > 0.0:
			# 可先买再刷。只有能够继续支付预留、目标购价和预期搜索费，才同时安排两笔支出。
			var needed = reserve + hit_prices / hits + fee / chance
			if plan.state.money >= needed:
				return {"allowed": false, "probability": chance, "expected": expected, "reason": "先买本页补强，购后余 %d，仍可覆盖预留、目标商品和预计搜索费 %.0f" % [plan.state.money, needed]}
		return {"allowed": allowed, "price": fee, "probability": chance, "expected": expected, "reason": "%s；目标例如 %s，%d 组货架命中 %.0f%%，所需 %.0f%%，预计收益 %.2f 分，费用 %d 材料，本页备选 %.2f 分" % ["刷新" if allowed else "离店或购买本页", name, count, chance * 100, minimum * 100, expected, fee, visible]}
	return stop
