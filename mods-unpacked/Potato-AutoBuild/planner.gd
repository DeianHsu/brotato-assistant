extends Reference

# 只操作快照。评分是可解释的启发式效用，不是通关概率。
const BASE_ROUTES = {
	"melee": ["近战续航", "melee_damage", 1.0],
	"ranged": ["远程清场", "ranged_damage", 0.55],
	"elemental": ["元素清场", "elemental_damage", 0.8],
	"engineering": ["工程阵地", "engineering", 0.9],
	"mixed": ["混合武器", "", 0.0],
	"pacifist": ["和平控场", "", 0.0]
}
const MAX_NODES = 3000
const Budget = preload("res://mods-unpacked/Potato-AutoBuild/analysis_budget.gd")
const Combat = preload("res://mods-unpacked/Potato-AutoBuild/combat_model.gd")
const WaveProfile = preload("res://mods-unpacked/Potato-AutoBuild/wave_profile.gd")
const Resources = preload("res://mods-unpacked/Potato-AutoBuild/resource_projection.gd")
const Events = preload("res://mods-unpacked/Potato-AutoBuild/event_model.gd")
const Activity = preload("res://mods-unpacked/Potato-AutoBuild/wave_activity.gd")
const ACTIVITY_LINKS = ["knockback", "fossil_count", "structure", "pet", "different_item", "common_item", "legendary_item", "duplicate_item", "living_enemy", "burning_enemy", "living_tree"]
var _context = {}
var _best = {}
var _page_candidates = {}
var _nodes = 0
var _seen = {}
var _routes = {}
var _priority = ""
var _base_levels = 0.0
var _scores = {}
var _hit_scores = {}
var _cache_scores = false
var evaluations = 0
var cache_hits = 0
var _base_inventory = {}
var _base_families = 0
var _base_crit_gold = 0.0
var _behavior = {}


func prepare(context: Dictionary, work: Dictionary) -> Array:
	_context = context
	_behavior = Activity.behavior(context)
	_scores.clear()
	_hit_scores.clear()
	_cache_scores = work.get("cache", false)
	evaluations = 0
	cache_hits = 0
	_base_inventory = _inventory_stats(context.weapons)
	_base_families = _weapon_family_count(context.weapons)
	var weight = 0.0
	_base_crit_gold = 0.0
	for weapon in context.weapons:
		weight += weapon.clear
		_base_crit_gold += weapon.clear * clamp(weapon.get("crit_chance", 0.0), 0.0, 1.0) * weapon.get("crit_gold_chance", 0.0)
	_base_crit_gold /= max(1.0, weight)
	_base_levels = _forecast_levels(0.0, 0.0, context.get("wave_growth", {}).get("xp_gain", 0.0))
	_routes = BASE_ROUTES.duplicate(true)
	var routes = ["mixed", "melee", "ranged", "elemental", "engineering"]
	# 新武器若按进化、护甲、生命等属性缩放，直接从实际缩放表生成路线。
	var candidates = context.weapons.duplicate()
	for offer in context.offers:
		if offer.get("kind", "weapon") == "weapon":
			candidates.append(offer.weapon)
	for weapon in candidates:
		for stat in weapon.scaling:
			var route = "scaling_" + stat
			if stat in ["melee_damage", "ranged_damage", "elemental_damage", "engineering"] or _routes.has(route):
				continue
			_routes[route] = [context.get("stat_labels", {}).get(stat, stat) + "协同", stat, context.get("growth", {}).get(stat, 0.5)]
			routes.append(route)
	if context.get("pacifist", false):
		routes = ["pacifist"]
	return routes


func plan(context: Dictionary, previous_route: String = "", work: Dictionary = {}):
	var routes = prepare(context, work)
	var trade_route = "pacifist" if context.get("pacifist", false) else "mixed"
	var initial = initial_state()
	var baseline = evaluate(initial, trade_route)
	_priority = _stage_priority(baseline)
	_nodes = 0
	_seen = {}
	_page_candidates.clear()
	_best = {"state": initial, "score": baseline, "surplus": 0.0}
	var search = _search(initial, baseline, baseline, trade_route, work)
	if search is GDScriptFunctionState:
		yield(search, "completed")
	if work.get("cancelled", false):
		return {}
	var winner = finish_candidate(_best, baseline, previous_route, routes, work)
	return yield(winner, "completed") if winner is GDScriptFunctionState else winner


func page_candidates() -> Array:
	var choices = _page_candidates.values()
	choices.sort_custom(self, "_higher_surplus")
	return choices


func _higher_surplus(left: Dictionary, right: Dictionary) -> bool:
	return left.surplus > right.surplus


func finish_candidate(candidate: Dictionary, baseline: Dictionary, previous_route: String, routes: Array, work: Dictionary):
	var winner = candidate.duplicate()
	winner.routes = routes
	var route_value = -INF
	var focus_route = "" if candidate.has("route") else _focus_route(routes, previous_route)
	if focus_route != "":
		winner.route = focus_route
	for route in routes:
		if candidate.has("route") or focus_route != "":
			break
		if not _route_allowed(route):
			continue
		var forecast = evaluate(winner.state, route, true)
		var value = gains(winner.score, forecast).future
		if value > route_value + 0.001 or (abs(value - route_value) <= 0.001 and route == previous_route):
			winner.route = route
			route_value = value
	winner.limited = _nodes >= MAX_NODES
	winner.actions = winner.state.actions
	winner.goal = _routes[winner.route][0]
	if winner.route == "engineering":
		var mines = 0
		for weapon in winner.state.weapons:
			if weapon.get("mine_interval", 0) > 0:
				mines += 1
		if mines > 0:
			winner.goal = "工程地雷＋工具近战" if mines == winner.state.weapons.size() else "工程＋混搭输出"
	winner.before = baseline
	winner.priority = _priority
	winner.priority_note = _priority_note(baseline)
	winner.gain = gains(baseline, winner.score)
	winner.reasons = _explain(winner)
	var skipped = _explain_skips(winner, work)
	if skipped is GDScriptFunctionState:
		skipped = yield(skipped, "completed")
	winner.skipped = skipped
	var lock_plan = _plan_locks(winner, work)
	if lock_plan is GDScriptFunctionState:
		lock_plan = yield(lock_plan, "completed")
	if work.get("cancelled", false):
		return {}
	winner.locks = lock_plan.keep
	winner.unlocks = lock_plan.release
	return winner


func _plan_locks(result: Dictionary, _work: Dictionary = {}):
	# 当前页只处理归属与到期。新增锁必须由联合下店规划比较货位价值后决定。
	var release = []
	var seen = {}
	for offer in _context.offers:
		if offer.index in result.state.used or seen.has(offer.index) or not offer.get("auto_locked", false):
			continue
		seen[offer.index] = true
		release.append({"index": offer.index, "name": offer.item.name if offer.get("kind", "weapon") == "item" else offer.weapon.name,
			"reason": "已保留到下一商店，本店方案未购买" if offer.get("auto_lock_wave", _context.wave) < _context.wave else "下店联合规划未保留此目标"})
	return {"keep": [], "release": release}

func retain_money(result: Dictionary, reason: String) -> Dictionary:
	result = result.duplicate()
	result.state = initial_state()
	result.actions = []
	result.score = result.before
	result.surplus = 0.0
	result.gain = gains(result.before, result.before)
	result.reasons = _explain(result)
	result.reasons.append(reason)
	result.skipped = _explain_skips(result)
	var locks = _plan_locks(result)
	result.locks = locks.keep
	result.unlocks = locks.release
	return result


func ramp_average(ramps: Array, duration: float) -> float:
	var total = 0.0
	for ramp in ramps:
		var count = max(0, int(ceil(duration / max(1.0, ramp.interval))) - 1)
		total += ramp.value * (count * duration - ramp.interval * count * (count + 1) / 2.0) / max(1.0, duration)
	return total


func initial_state() -> Dictionary:
	return {"weapons": _context.weapons.duplicate(), "slots": _context.rules.slots, "money": _context.money, "gold": _context.get("gold", _context.money), "items": [], "hp_spent": 0.0, "hp_fraction": _context.get("hp_currency_fraction", 0.0), "used": [], "actions": []}


func after_refresh(price: int) -> Dictionary:
	var state = _copy(initial_state())
	if _context.hp_shop:
		state.gold -= price
	else:
		state.money -= price
	var effect = _context.get("refresh_tier", {})
	if effect.has("id"):
		state.consumed[effect.id] = 1
	return state


func best_offer(state: Dictionary, offer: Dictionary, route: String, baseline: Dictionary = {}, explain_rejection: bool = false, work: Dictionary = {}):
	var best = {}
	var rejected = {}
	if baseline.empty():
		baseline = evaluate(state, route)
	for next in _transitions(state, offer):
		var ready = Budget.checkpoint(work)
		if ready is GDScriptFunctionState:
			ready = yield(ready, "completed")
		if not ready:
			work.cancelled = true
			return {}
		var score = evaluate(next, route)
		var gain = gains(baseline, score)
		var threshold = next.hurdle - state.get("hurdle", 0.0)
		var surplus = gain.score - threshold
		var action = next.actions.back()
		if action.kind == "bundle" and action.steps[0].kind == "sell" and gain.immediate < -0.001:
			if explain_rejection and (rejected.empty() or surplus > rejected.surplus):
				rejected = {"state": next, "score": score, "gain": gain, "threshold": threshold, "surplus": surplus, "sale_rejected": true}
			continue
		if best.empty() or surplus > best.surplus + 0.001:
			best = {"state": next, "score": score, "gain": gain, "threshold": threshold, "surplus": surplus}
	return rejected if best.empty() else best


func rank_upgrades(context: Dictionary, choices: Array, previous_route: String = "") -> Dictionary:
	var build = plan(context, previous_route)
	var route = build.route
	var initial = {"weapons": context.weapons, "money": context.money}
	var baseline = evaluate(initial, route)
	var prioritize_immediate = _prioritize_immediate_upgrades()
	var focus = _focus_share(route)
	var ranked = []
	for choice in choices:
		var state = {"weapons": context.weapons, "slots": context.rules.slots + choice.get("slots", 0), "money": context.money, "bonus_stats": choice.stats}
		var score = evaluate(state, route)
		var delta = _stat_delta(state)
		var gain = gains(baseline, score)
		var row = choice.duplicate()
		var focus_cost = _secondary_damage_cost(route, choice.stats, gain, focus)
		row.score = (gain.immediate if prioritize_immediate else gain.score) - focus_cost
		row.total_score = gain.score - focus_cost
		row.reason = explain_gain(baseline, score, gain)
		if focus_cost > 0.0:
			row.reason += "；跨系伤害按主力占比扣减 %.2f 分" % focus_cost
		if prioritize_immediate:
			row.reason += "；生存受压，按即战收益 %+.2f 分排序" % row.score
		var changes = []
		for stat in choice.stats:
			changes.append("%s %+.1f" % [context.get("stat_labels", {}).get(stat, stat), delta.get(stat, 0.0)])
		if score.slots != baseline.slots:
			changes.append("武器槽 %d → %d" % [baseline.slots, score.slots])
		row.changes = PoolStringArray(changes).join("，")
		ranked.append(row)
	# 即战收益相同的加点继续比较完整收益，仍相同则保留屏幕顺序。
	for i in range(1, ranked.size()):
		var row = ranked[i]
		var j = i - 1
		while j >= 0:
			var difference = row.score - ranked[j].score
			if abs(difference) <= 0.001:
				difference = row.total_score - ranked[j].total_score
			if difference <= 0.001:
				break
			ranked[j + 1] = ranked[j]
			j -= 1
		ranked[j + 1] = row
	return {"route": route, "goal": build.goal, "ranked": ranked, "priority_note": build.priority_note, "burst_note": explain_burst(baseline)}


func estimate_upgrade_reroll(ranking: Dictionary, groups: Dictionary, price: int) -> Dictionary:
	var result = {"price": price, "affordable": _context.get("gold", _context.money) >= price}
	if groups.size() < 4 or ranking.ranked.empty():
		return result
	var state = initial_state()
	var baseline = evaluate(state, ranking.route)
	state.gold = max(0, state.gold - price)
	if not _context.hp_shop:
		state.money = max(0, state.money - price)
	var cost = purchase_threshold(price)
	var current = ranking.ranked[0].score
	var prioritize_immediate = _prioritize_immediate_upgrades()
	var focus = _focus_share(ranking.route)
	result.keep_current = _streamer_retried() and current > 0.001
	var scores = []
	var thresholds = {}
	var common_weight = -1.0
	for id in groups:
		var variants = []
		var weight = 0.0
		for option in groups[id]:
			state.bonus_stats = option.stats
			var evaluated = evaluate(state, ranking.route)
			var gain = gains(baseline, evaluated)
			var score = (gain.immediate if prioritize_immediate else gain.score) - cost - _secondary_damage_cost(ranking.route, option.stats, gain, focus)
			thresholds[score] = true
			variants.append({"score": score, "weight": option.weight})
			weight += option.weight
		if weight <= 0.0 or (common_weight >= 0.0 and not is_equal_approx(weight, common_weight)):
			return result
		common_weight = weight
		scores.append(variants)
	var sorted_scores = thresholds.keys()
	sorted_scores.sort()
	var possible = float(scores.size() * (scores.size() - 1) * (scores.size() - 2) * (scores.size() - 3)) / 24.0
	var previous = 0.0
	result.expected = 0.0
	result.chance = 1.0
	for threshold in sorted_scores:
		# 不同属性不会同页重复。累计四个不同属性均低于分数线的组合概率。
		var combinations = [1.0, 0.0, 0.0, 0.0, 0.0]
		for variants in scores:
			var probability = 0.0
			for option in variants:
				if option.score <= threshold:
					probability += option.weight / common_weight
			for count in range(4, 0, -1):
				combinations[count] += combinations[count - 1] * probability
		var at_most = clamp(combinations[4] / possible, 0.0, 1.0)
		result.expected += threshold * (at_most - previous)
		if threshold <= current + 0.0001:
			result.chance = 1.0 - at_most
		previous = at_most
	result.surplus = result.expected - current
	return result


func _prioritize_immediate_upgrades() -> bool:
	return pacifist_survival_risk() > 0.0 or _streamer_retried()


func _streamer_retried() -> bool:
	return _context.get("character_id", "") == "character_streamer" and _context.get("battle_observation", {}).get("wave_retries", 0) > 0


func rank_crate(context: Dictionary, offers: Array, refund: int, previous_route: String = "") -> Dictionary:
	var crate_context = context.duplicate()
	crate_context.copy_purchase = {}
	crate_context.offers = offers
	var build = plan(crate_context, previous_route)
	var initial = initial_state()
	var baseline = evaluate(initial, build.route)
	var recycled = _copy(initial)
	recycled.gold += refund
	if not context.hp_shop:
		recycled.money += refund
	var cash_value = purchase_threshold(refund) if context.final_wave > context.wave else 0.0
	var recycle_score = evaluate(recycled, build.route)
	var recycle_gain = gains(baseline, recycle_score).score + cash_value
	var focus = _focus_share(build.route)
	var best = {}
	var choices = []
	var partial = false
	for offer in offers:
		var pending = _offer_evidence(offer)
		partial = partial or pending != ""
		var probe = offer.duplicate()
		probe.blocked = ""
		var label = "保留" + ("（" + offer.choice_text + "）" if offer.get("choice_text", "") != "" else "")
		# 宝箱仅比较原生可直接保留/合成的选项，不在此悄悄出售已有装备。
		var taken = buy(initial, probe)
		if taken.empty():
			var alternative = best_offer(initial, probe, build.route, baseline)
			choices.append(label + " 当前无法直接保留" if alternative.empty() else label + " 需先整理装备，" + _explain_skipped_trade(baseline, alternative))
			continue
		var score = evaluate(taken, build.route)
		var gain = gains(baseline, score)
		var detail = explain_gain(baseline, score, gain)
		var focus_cost = _secondary_damage_cost(build.route, offer.get("item", {}).get("stats", {}), gain, focus)
		if focus > 0.0 and offer.get("kind", "weapon") == "weapon" and not _scales_with(offer.weapon, _routes[build.route][1]):
			focus_cost += max(0.0, gain.combat) * focus / max(1, context.rules.slots)
		var keep_gain = gain.score - focus_cost
		if focus_cost > 0.0:
			detail += "；跨系投入扣减 %.2f 分" % focus_cost
		for event in offer.get("item", {}).get("events", []):
			if event.trigger == "projectiles_on_death":
				detail += "；死亡子弹预计清场输出 %.2f → %.2f/秒" % [baseline.event_output.get("death_shots", 0.0), score.event_output.get("death_shots", 0.0)]
				break
		choices.append(label + ("（已计部分）" if pending != "" else "") + " " + detail + pending)
		if offer.get("blocked", "") != "" or (offer.get("kind", "weapon") == "weapon" and not offer.weapon.get("unmeasured", []).empty()):
			continue
		if best.empty() or keep_gain > best.keep_gain + 0.001:
			best = {"action": "take" if keep_gain > recycle_gain + 0.001 else "recycle", "keep_gain": keep_gain, "recycle_gain": recycle_gain, "choice": offer.get("choice", -1), "choice_text": offer.get("choice_text", ""), "reason": "保留 %s；回收 %d 材料，综合收益估计 %+.2f 分" % [detail, refund, recycle_gain]}
	if best.empty():
		best = {"action": "manual", "reason": offers[0].get("blocked", "") if not offers.empty() and offers[0].get("blocked", "") != "" else "当前无法直接保留；请先手动整理武器或判断特殊效果"}
	elif partial and best.action == "recycle":
		best.action = "manual"
		best.reason = "保留收益仅计入已知部分，请确认特殊效果后再决定是否回收"
	best.route = build.route
	best.goal = build.goal
	best.priority_note = build.priority_note
	best.choices = choices
	best.recycle_note = "回收 %d 材料，综合收益估计 %+.2f 分" % [refund, recycle_gain]
	return best


func _route_allowed(route: String) -> bool:
	var stat = _routes[route][1]
	if stat != "" and _context.gains.get(stat, 1.0) <= 0:
		return false
	if route == "melee" and _context.rules.no_melee:
		return false
	if route == "ranged" and _context.rules.no_ranged:
		return false
	return true


func _scales_with(weapon: Dictionary, attribute: String) -> bool:
	if attribute == "":
		return false
	var scaling = weapon.scaling
	if scaling.get(attribute, 0) > 0 or weapon.get("burn_model", {}).get("scaling", {}).get(attribute, 0) > 0:
		return true
	for component in weapon.get("damage_components", []) + weapon.get("structure_components", []):
		if component.get("scaling", {}).get(attribute, 0) > 0:
			return true
	if attribute == "engineering" and weapon.get("structure_scaling", 0) > 0:
		return true
	for link in _context.get("links", []):
		if link.source == attribute and link.value > 0 and scaling.get(link.target, 0) > 0:
			return true
	return false


func _route_weapon_count(weapons: Array, route: String) -> int:
	var count = 0
	var attribute = _routes[route][1]
	for weapon in weapons:
		if _scales_with(weapon, attribute):
			count += 1
	return count


func _focus_share(route: String) -> float:
	if _context.wave < 6 or _context.wave + 1 >= _context.final_wave or route in ["mixed", "pacifist"] or not _routes.has(route) or not _route_allowed(route):
		return 0.0
	if _context.get("resources", {}).get("destroy_weapons", false):
		return 0.0
	var weapons = _context.weapons
	var count = _route_weapon_count(weapons, route)
	return float(count) / weapons.size() if count >= 3 and count * 2 > weapons.size() else 0.0


func _focus_route(routes: Array, previous: String) -> String:
	if previous in routes and _focus_share(previous) > 0.0:
		return previous
	# 续局和首次明确构筑时，从持有装备恢复主力。两路并列时继续比较成长。
	var strongest = 0.5
	var focused = ""
	for route in routes:
		var share = _focus_share(route)
		if share > strongest:
			strongest = share
			focused = route
		elif share == strongest:
			focused = ""
	return focused


func _secondary_damage_cost(route: String, stats: Dictionary, gain: Dictionary, focus: float) -> float:
	if focus <= 0.0 or gain.combat <= 0.0 or stats.get(_routes[route][1], 0.0) > 0.0 or stats.get("percent_damage", 0.0) > 0.0 or stats.get("attack_speed", 0.0) > 0.0:
		return 0.0
	for attribute in ["melee_damage", "ranged_damage", "elemental_damage", "engineering"]:
		if stats.get(attribute, 0.0) > 0.0:
			return gain.combat * focus
	return 0.0


func _search(state: Dictionary, baseline: Dictionary, parent_score: Dictionary, route: String, work: Dictionary = {}):
	if _nodes >= MAX_NODES:
		return
	var ready = Budget.checkpoint(work)
	if ready is GDScriptFunctionState:
		ready = yield(ready, "completed")
	if not ready:
		work.cancelled = true
		return
	var keys = []
	for weapon in state.weapons:
		keys.append(weapon.key)
	var used = state.used.duplicate()
	used.sort()
	var sold_weapon = state.get("sold_weapon", false)
	var copied_items = []
	if not state.get("consumed", {}).empty():
		for item in state.items:
			copied_items.append(item.id)
	var signature = str([keys, used, copied_items, state.money, state.get("hp_fraction", 0.0), state.get("consumed", {}), state.get("economy_investment", 0.0), sold_weapon])
	var hurdle = state.get("hurdle", 0.0)
	if _seen.get(signature, INF) <= hurdle + 0.0001:
		return
	_seen[signature] = hurdle
	_nodes += 1
	var score = baseline
	if not state.actions.empty():
		score = evaluate(state, route)
		var action = state.actions.back().duplicate()
		action.before = parent_score
		action.after = score
		action.threshold = hurdle - action.get("previous_hurdle", 0.0)
		state.actions[state.actions.size() - 1] = action
	var gain = gains(baseline, score)
	var surplus = gain.score - hurdle
	# 可以用同页后续购买补回损失。仅靠成长或经济得分的降战力出售不能胜出。
	if surplus > 0.001 and (not sold_weapon or gain.immediate >= -0.001):
		var candidate = {"state": state, "score": score, "surplus": surplus}
		if surplus > _best.surplus + 0.001:
			_best = candidate
		if work.get("alternatives", false):
			_page_candidates[signature] = candidate
	for offer in _context.offers:
		if offer.index in state.used or offer.get("blocked", "") != "":
			continue
		for next in _transitions(state, offer):
			var search = _search(next, baseline, score, route, work)
			if search is GDScriptFunctionState:
				yield(search, "completed")
			if work.get("cancelled", false):
				return


func _transitions(state: Dictionary, offer: Dictionary) -> Array:
	var transitions = []
	if offer.get("blocked", "") != "":
		return transitions
	if offer.get("kind", "weapon") == "weapon" and not offer.weapon.get("unmeasured", []).empty():
		return transitions
	var direct = buy(state, offer)
	if not direct.empty():
		transitions.append(direct)
	if offer.get("kind", "weapon") == "item" or _context.rules.locked:
		return transitions
	# 只将合成/出售与后续购买作为完整方案比较，不为现金单独卖掉武器。
	if direct.empty():
		var pairs = {}
		for i in range(state.weapons.size()):
			var left = state.weapons[i]
			var partner = _partner(state, left, i)
			if partner < 0:
				continue
			var right = state.weapons[partner]
			if _first_equivalent(state.weapons, left) != i:
				continue
			var pair = [left.get("trade_key", left.key), right.get("trade_key", right.key)]
			if pairs.has(pair):
				continue
			pairs[pair] = true
			var merged = _copy(state)
			merged.weapons.remove(i)
			var removed = _first_equivalent(merged.weapons, right)
			if removed < 0 or merged.weapons[removed].key != right.key:
				continue
			merged.weapons.remove(removed)
			merged.weapons.append(_merge(left, right))
			var next = buy(merged, offer)
			if not next.empty() and next.actions.back().get("partner", "") == "":
				_bundle(next, {"kind": "combine", "id": left.id, "key": left.key, "partner": right.key, "name": left.name})
				transitions.append(next)
	if replacement_needed(state, offer.weapon) and not _context.hp_shop:
		var sales = {}
		for i in range(state.weapons.size()):
			var held = state.weapons[i]
			if not held.get("can_sell", false) or not held.get("unmeasured", []).empty() or _first_equivalent(state.weapons, held) != i:
				continue
			var key = held.get("trade_key", held.key)
			if sales.has(key):
				continue
			sales[key] = true
			var sold = _copy(state)
			sold.weapons.remove(i)
			sold.money += held.refund
			sold.sold_weapon = true
			sold.sale_credit = held.refund
			var next = buy(sold, offer)
			if not next.empty():
				_bundle(next, {"kind": "sell", "id": held.id, "key": held.key, "refund": held.refund, "name": held.name})
				transitions.append(next)
	return transitions


func replacement_needed(state: Dictionary, weapon: Dictionary) -> bool:
	if state.weapons.size() >= state.get("slots", _context.rules.slots):
		return true
	var types = 0
	for held in state.weapons:
		if held.type == weapon.type:
			types += 1
		if _context.rules.unique and held.family == weapon.family:
			return true
	return types >= (_context.rules.max_melee if weapon.type == 0 else _context.rules.max_ranged)


func _bundle(state: Dictionary, preparation: Dictionary) -> void:
	var purchase = state.actions.pop_back()
	state.actions.append({"kind": "bundle", "name": preparation.name + " → " + purchase.name, "steps": [preparation, purchase], "previous_hurdle": purchase.previous_hurdle})


func buy(state: Dictionary, offer: Dictionary) -> Dictionary:
	offer = offer.duplicate()
	offer.price = offer_price(state, offer)
	if offer.price > state.money:
		return {}
	if offer.get("kind", "weapon") == "item":
		var next = _copy(state)
		var count = 0
		for item in next.items:
			if item.id == offer.item.id or item.id in offer.item.get("limited_descendants", []):
				count += 1
		if count >= offer.item.get("remaining", 999):
			return {}
		var copies = 1
		var mirror = _context.get("copy_purchase", {})
		if not mirror.empty() and count + 1 < offer.item.get("remaining", 999):
			if mirror.get("manual", false):
				return {}
			var used = next.get("consumed", {}).get(mirror.id, 0)
			var extra = min(mirror.value - used, offer.item.get("remaining", 999) - count - 1)
			if extra > 0:
				extra = min(extra, mirror.count - used)
				next.consumed[mirror.id] = used + extra
				copies += extra
		for _copy_index in range(copies):
			next.items.append(offer.item)
		next.slots += copies * int(offer.item.get("bonuses", {}).get("weapon_slot", 0))
		if _context.hp_shop and int(state.money + state.get("hp_fraction", _context.get("hp_currency_fraction", 0.0)) - offer.price * _context.gains.get("max_hp", 1.0)) < _health_floor():
			return {}
		_pay(next, offer, _permanent_stat_delta(next).get("max_hp", 0.0) - _permanent_stat_delta(state).get("max_hp", 0.0) if _context.hp_shop else 0.0)
		next.actions.back().copies = copies
		for name in offer.item.get("caps", {}):
			var cap = offer.item.caps[name]
			var start = _context.get("raw_max_hp", _context.stats.max_hp) if cap.stat == "max_hp" else _context.stats.get(cap.stat, 0.0)
			var spent = next.hp_spent if cap.stat == "max_hp" else 0.0
			next.caps[name] = cap.value if cap.stat == "" else start + _stat_delta(next, false).get(cap.stat, 0.0) - spent
		return next
	var weapon = offer.weapon
	var rules = _context.rules
	if offer.price > state.money or weapon.tier < rules.min_tier or weapon.tier > rules.max_tier:
		return {}
	if (weapon.type == 0 and rules.no_melee) or (weapon.type == 1 and rules.no_ranged):
		return {}
	var types = 0
	var duplicate = false
	for held in state.weapons:
		if held.type == weapon.type:
			types += 1
		if held.family == weapon.family:
			duplicate = true
	var type_cap = rules.max_melee if weapon.type == 0 else rules.max_ranged
	var free = state.weapons.size() < state.get("slots", rules.slots) and types < type_cap and not (rules.unique and duplicate)
	var next = _copy(state)
	var partner_key = ""
	if free:
		next.weapons.append(weapon)
	else:
		if rules.locked:
			return {}
		var partner = _partner(state, weapon)
		if partner < 0:
			return {}
		partner_key = state.weapons[partner].key
		next.weapons.append(weapon)
		next.weapons.remove(_first_equivalent(next.weapons, weapon))
		var removed = _first_equivalent(next.weapons, state.weapons[partner])
		if removed < 0:
			return {}
		next.weapons.remove(removed)
		next.weapons.append(_merge(weapon, state.weapons[partner]))
	# 生命商店必须保有随波次上升的生命底线。
	if _context.hp_shop and int(state.money + state.get("hp_fraction", _context.get("hp_currency_fraction", 0.0)) - offer.price * _context.gains.get("max_hp", 1.0)) < _health_floor():
		return {}
	_pay(next, offer, _permanent_stat_delta(next).get("max_hp", 0.0) - _permanent_stat_delta(state).get("max_hp", 0.0) if _context.hp_shop else 0.0)
	next.actions.back().partner = partner_key
	return next


func offer_price(state: Dictionary, offer: Dictionary) -> int:
	if not offer.has("pricing"):
		return int(offer.price)
	var changes = {}
	for item in state.get("items", []):
		_add_stats(changes, item.get("bonuses", {}))
	# 宝箱无价格元数据；真实商店按本版本原生定价顺序重算，保留锁定商品的波次价格。
	var p = offer.pricing
	var current = _context.get("price_effects", {})
	var base = p.base * (1.0 + (current.get("weapons_price", 0.0) + changes.get("weapons_price", 0.0)) / 100.0) if p.weapon else float(p.base)
	var value = max(1.0, (base + p.wave + base * p.wave * p.inflation) * (1.0 + (current.get("items_price", 0.0) + p.specific + changes.get("items_price", 0.0)) / 100.0) * (1.0 + p.endless))
	value = int(value) + p.markup
	return int(ceil(value / 20.0)) if _context.hp_shop else int(value)


func _pay(state: Dictionary, offer: Dictionary, hp_added: float = 0.0) -> void:
	if _context.hp_shop:
		# 原生货币向零截断，但属性的小数保留到下次付款，不能每笔丢掉。
		var raw = state.money + state.get("hp_fraction", _context.get("hp_currency_fraction", 0.0)) - offer.price * _context.gains.get("max_hp", 1.0) + hp_added
		state.money = int(raw)
		state.hp_fraction = raw - state.money
	else:
		state.money -= offer.price
	var previous_hurdle = state.hurdle
	if _context.hp_shop:
		state.hp_spent += offer.price * _context.gains.get("max_hp", 1.0)
	else:
		state.hurdle += purchase_threshold(max(0, offer.price - state.get("sale_credit", 0)))
	state.erase("sale_credit")
	state.used.append(offer.index)
	if offer.get("kind", "weapon") == "item" and not _context.hp_shop:
		for name in ["items_price", "weapons_price", "reroll_price", "free_rerolls"]:
			if offer.item.get("bonuses", {}).has(name):
				state.economy_investment = state.get("economy_investment", 0.0) + offer.price
				break
	state.actions.append({"kind": "buy", "slot_key": offer.get("slot_key", ""), "index": offer.index, "price": offer.price, "name": offer.item.name if offer.get("kind", "weapon") == "item" else offer.weapon.name, "choice": offer.get("choice", -1), "choice_text": offer.get("choice_text", ""), "previous_hurdle": previous_hurdle})


func _first_equivalent(weapons: Array, target: Dictionary) -> int:
	for index in range(weapons.size()):
		var held = weapons[index]
		if held.key == target.key:
			return index
		if held.id == target.id and _context.has("same_weapon") and _context.same_weapon.call_func(held.source, target.source):
			return index
	return -1


func validates_bundle(context: Dictionary, action: Dictionary) -> bool:
	_context = context
	var purchase = action.steps[1]
	for offer in context.offers:
		if offer.index != purchase.index or offer.get("choice", -1) != purchase.choice or offer.slot_key != purchase.slot_key:
			continue
		for state in _transitions(initial_state(), offer):
			var planned = state.actions.back()
			if planned.kind != "bundle":
				continue
			var prep = planned.steps[0]
			var wanted = action.steps[0]
			if prep.kind == wanted.kind and prep.key == wanted.key and prep.get("partner", "") == wanted.get("partner", "") and prep.get("refund", 0) == wanted.get("refund", 0) and planned.steps[1].price == purchase.price and planned.steps[1].get("partner", "") == purchase.get("partner", ""):
				return true
	return false


func _partner(state: Dictionary, weapon: Dictionary, excluded: int = -1) -> int:
	var best = -1
	var rank = -1
	var preferred = _context.get("preferred_flavor", 1)
	if preferred < 0:
		return -1
	for index in range(state.weapons.size()):
		var held = state.weapons[index]
		if index == excluded or not _mergeable(weapon, held):
			continue
		var flavor = held.get("flavor", 0)
		var priority = 2 * int(flavor != weapon.get("flavor", 0)) + int(flavor == preferred)
		if priority > rank:
			best = index
			rank = priority
	return best


func _mergeable(a: Dictionary, b: Dictionary) -> bool:
	var flavor_a = a.get("flavor", 0)
	var flavor_b = b.get("flavor", 0)
	return a.id == b.id and (flavor_a == 0 or flavor_b == 0 or flavor_a == flavor_b) and a.has("upgrade") and a.upgrade.tier <= _context.rules.max_tier and a.get("unmeasured", []).empty() and b.get("unmeasured", []).empty()


func _merge(a: Dictionary, b: Dictionary) -> Dictionary:
	if _context.has("merge"):
		return _context.merge.call_func(a, b)
	return a.upgrade


func _copy(state: Dictionary) -> Dictionary:
	return {"weapons": state.weapons.duplicate(), "slots": state.get("slots", _context.rules.slots), "consumed": state.get("consumed", {}).duplicate(), "caps": state.get("caps", {}).duplicate(), "bonus_stats": state.get("bonus_stats", {}).duplicate(), "money": state.money, "gold": state.get("gold", _context.get("gold", _context.money)), "items": state.get("items", []).duplicate(), "hp_spent": state.get("hp_spent", 0.0), "hp_fraction": state.get("hp_fraction", _context.get("hp_currency_fraction", 0.0)), "economy_investment": state.get("economy_investment", 0.0), "hurdle": state.get("hurdle", 0.0), "sale_credit": state.get("sale_credit", 0), "sold_weapon": state.get("sold_weapon", false), "used": state.used.duplicate(), "actions": state.actions.duplicate()}


func _health_floor() -> float:
	return min(_context.money, 12.0 + _context.wave * (1.6 + _context.difficulty * 0.12))


func evaluate(state: Dictionary, route: String, include_route_growth: bool = false) -> Dictionary:
	var key = _score_key(state, route, include_route_growth) if _cache_scores else ""
	if _cache_scores and _scores.has(key):
		cache_hits += 1
		return _scores[key]
	evaluations += 1
	var original_context = _context
	var profile = _context.get("combat_profile", {})
	if profile.has("bait") and not state.get("items", []).empty():
		var groups = 0
		var copies = 0
		for item in state.items:
			groups += int(item.get("bonuses", {}).get("bait_groups", 0))
			if item.get("id", "") == "item_bait":
				copies += 1
		if groups > 0 or (copies > 0 and profile.bait.upgraded):
			# 同一组敌人的生命、密度和出现时点同时用于有效伤害与清场需求。
			_context = original_context.duplicate()
			_context.combat_profile = WaveProfile.with_bait(profile, groups, copies)
	var score = _evaluate_behavior(state, route, include_route_growth)
	if Events.has_growth(_context, state):
		# 用未叠层状态估计可承受的事件数，再投影一次。绝不让成长后的恢复或伤害反复放大事件。
		score = _evaluate_behavior(state, route, include_route_growth, score.get("events", {}))
	_context = original_context
	if _cache_scores:
		_scores[key] = score
	return score


func _score_key(state: Dictionary, route: String, growth: bool) -> String:
	var weapons = []
	var resources = _context.get("resources", {})
	var wallet = _context.hp_shop or not _context.get("gold_ticks", []).empty() or _context.get("gold_start_pct", 0) != 0 or resources.get("materials_as_health", false) or resources.get("damage_taken_on_materials", false)
	for link in _context.get("links", []):
		wallet = wallet or link.source == "materials"
	for weapon in state.weapons:
		weapons.append(weapon.key)
		for component in weapon.get("damage_components", [weapon.get("damage_model", {})]):
			for effect in component.get("base_effects", []):
				wallet = wallet or effect.get("source", "") == "materials"
	for item in state.get("items", []):
		var bonuses = item.get("bonuses", {})
		wallet = wallet or bonuses.get("gain_pct_gold_start_wave", 0) != 0 or bonuses.get("free_rerolls", 0) != 0
		for link in item.get("links", []):
			wallet = wallet or link.source == "materials"
	var purchases = []
	var visible_used = []
	for action in state.get("actions", []):
		var purchase = action.steps.back() if action.kind == "bundle" else action
		# 只有本页真实商品会影响当前页折扣；随机池的占位索引不参与此项。
		for offer in _context.offers:
			if offer.index == purchase.get("index", -2):
				purchases.append([purchase.index, purchase.price, offer.get("locked", false)])
				visible_used.append(offer.index)
				break
	return str([weapons, state.get("items", []), state.get("bonus_stats", {}), state.get("caps", {}),
		state.get("consumed", {}), state.get("slots", _context.rules.slots), state.get("hp_spent", _context.money - state.money if _context.hp_shop else 0),
		state.get("economy_investment", 0), visible_used, purchases, _context.get("fresh_slots", 1),
		[state.money, state.get("gold", _context.get("gold", _context.money))] if wallet else [], route if growth else ""])


func wallet_sensitive(state: Dictionary, offer: Dictionary) -> bool:
	var resources = _context.get("resources", {})
	if _context.hp_shop or not _context.get("gold_ticks", []).empty() or _context.get("gold_start_pct", 0) != 0 or resources.get("materials_as_health", false) or resources.get("damage_taken_on_materials", false):
		return true
	for link in _context.get("links", []):
		if link.source == "materials":
			return true
	var items = state.get("items", []).duplicate()
	if offer.get("kind", "weapon") == "item":
		items.append(offer.item)
	for item in items:
		var bonuses = item.get("bonuses", {})
		if bonuses.get("gain_pct_gold_start_wave", 0) != 0 or bonuses.get("free_rerolls", 0) != 0:
			return true
		for link in item.get("links", []):
			if link.source == "materials":
				return true
	var weapons = state.weapons.duplicate()
	if offer.get("kind", "weapon") == "weapon":
		weapons.append(offer.weapon)
	for weapon in weapons:
		for component in weapon.get("damage_components", [weapon.get("damage_model", {})]):
			for effect in component.get("base_effects", []):
				if effect.get("source", "") == "materials":
					return true
	return false


func _evaluate_behavior(state: Dictionary, route: String, growth: bool, events: Dictionary = {}) -> Dictionary:
	if not Activity.needs_movement(_context, state):
		return _evaluate_phases(state, route, growth, events)
	if _behavior.still <= 0.0:
		return _evaluate_phases(state, route, growth, events, 1)
	if _behavior.moving <= 0.0:
		return _evaluate_phases(state, route, growth, events, 0)
	var still = _evaluate_phases(state, route, growth, events, 0)
	var moving = _evaluate_phases(state, route, growth, events, 1)
	var moving_share = 1.0 - _behavior.combat_still
	var result = Activity.blend(still, moving, moving_share)
	for field in ["defense", "future_defense"]:
		var worst_short = max(still[field].short_pressure, moving[field].short_pressure)
		result[field].pressure += (worst_short - result[field].short_pressure) * (1.0 - result[field].pressure)
		result[field].short_pressure = worst_short
	result.movement_output = [still.current_clear, moving.current_clear]
	result.movement_share = _behavior.combat_still
	result.clear_ready = clamp(min(result.current_clear, result.opening_clear) / result.clear_target, 0.0, 1.0)
	result.boss_ready = clamp(result.current_boss / result.boss_target, 0.0, 1.0)
	if result.has("half_wave_output"):
		result.half_wave_output = []
		for i in range(still.half_wave_output.size()):
			result.half_wave_output.append(lerp(still.half_wave_output[i], moving.half_wave_output[i], moving_share))
		result.clear_ready = min(result.clear_ready, min(result.half_wave_output[0], result.half_wave_output[1]) / result.clear_target)
		result.boss_ready = min(result.boss_ready, min(result.half_wave_output[2], result.half_wave_output[3]) / result.boss_target)
	result.need_damage = not _context.get("pacifist", false) and min(result.clear_ready, result.boss_ready) < 1.0
	return result


func _evaluate_phases(state: Dictionary, route: String, include_route_growth: bool, event_rates: Dictionary = {}, movement: int = -1) -> Dictionary:
	var permanent = null if _context.get("half_wave_conversions", []).empty() else _permanent_stat_delta(state)
	var first = _evaluate(state, route, include_route_growth, permanent, false, event_rates, movement)
	if not first.split_wave:
		return first
	var second = _evaluate(state, route, include_route_growth, permanent, true, event_rates, movement)
	first.half_wave_output = [first.current_clear, second.current_clear, first.current_boss, second.current_boss]
	for field in ["clear", "boss", "current_clear", "current_boss", "combat_utility", "growth_utility"]:
		first[field] = (first[field] + second[field]) * 0.5
	for field in ["durability", "next_durability", "pressure", "short_pressure", "drain_pressure", "recovery_pressure", "incoming", "recovery"]:
		first.defense[field] = (first.defense[field] + second.defense[field]) * 0.5
		first.future_defense[field] = (first.future_defense[field] + second.future_defense[field]) * 0.5
	var duration = _context.get("wave_duration", 60.0)
	var opening = min(15.0, duration)
	if opening > duration * 0.5:
		first.opening_clear = lerp(first.opening_clear, second.opening_clear, (opening - duration * 0.5) / opening)
	# 转换后也要达到火力线。开局短窗口继续单独衡量。
	first.clear_ready = min(1.0, min(first.opening_clear, min(first.half_wave_output[0], first.half_wave_output[1])) / first.clear_target)
	first.boss_ready = min(first.boss_ready, second.boss_ready)
	first.need_damage = not _context.get("pacifist", false) and min(first.clear_ready, first.boss_ready) < 1.0
	return first


func _half_wave_change(permanent: Dictionary, growth: Dictionary) -> Dictionary:
	var changes = {}
	for conversion in _context.half_wave_conversions:
		var source = conversion.from_stat
		var target = conversion.to_stat
		var base = _context.get("permanent_stats", _context.stats).get(source, 0.0)
		var available = int(base + permanent.get(source, 0.0) + growth.get(source, 0.0))
		var chunks = int(floor(available * conversion.portion / conversion.cost))
		if chunks <= 0:
			break
		var source_gain = _context.gains.get(source, 1.0)
		var target_gain = _context.gains.get(target, 1.0)
		# 原生从常驻属性取整分组，再反除收益倍率写入整数临时属性。
		var removed = round(chunks * conversion.cost / source_gain) if source_gain > 0.0 else chunks * conversion.cost
		var added = round(chunks * conversion.reward / target_gain) if target_gain > 0.0 else chunks * conversion.reward
		changes[source] = changes.get(source, 0.0) - removed * source_gain
		changes[target] = changes.get(target, 0.0) + added * target_gain
	return changes


func _evaluate(state: Dictionary, route: String, include_route_growth: bool, permanent, second_half: bool, event_rates: Dictionary = {}, movement: int = -1) -> Dictionary:
	var remaining = max(0, _context.final_wave - _context.wave)
	var future_weight = clamp(remaining / 20.0, 0.0, 0.65)
	var delta = _stat_delta(_wave_wallet_state(state, _context.get("wave_duration", 60.0)), true, permanent)
	var conditional = _conditional_stats(state, event_rates, 1.0, movement)
	_add_stats(delta, conditional)
	if _context.hp_shop:
		delta.max_hp = delta.get("max_hp", 0.0) - state.get("hp_spent", _context.money - state.money)
	var clear = 0.0
	var boss = 0.0
	var current_clear = 0.0
	var current_boss = 0.0
	var opening_clear = 0.0
	var control = 0.0
	var healing = 0.0
	var lifesteal_hits = 0.0
	var best_burn = 0.0
	var best_burn_clear = 0.0
	var current_burn = 0.0
	var current_burn_clear = 0.0
	var opening_burn_clear = 0.0
	var bonuses = {}
	var secondary = _context.get("secondary", {}).duplicate()
	var global_burn = _context.get("global_burn", {}).duplicate()
	var level_growth = {}
	var wave_growth = _context.get("wave_growth", {}).duplicate()
	var regen_conditions = _context.get("regen_conditions", []).duplicate()
	var ramps = _context.get("damage_ramps", []).duplicate()
	var item_structure = _context.get("item_structure", 0.0)
	var item_structure_scaling = _context.get("item_structure_scaling", 0.0)
	var item_components = _context.get("structure_components", []).duplicate()
	var support_structures = _context.get("support_structures", []).duplicate()
	var full_health_growth = _context.get("full_health_growth", []).duplicate()
	var event_profiles = _context.get("events", []).duplicate()
	var ice_mark = _context.get("ice_mark", {})
	var mark_hits = []
	for item in state.get("items", []):
		if item.has("ice_mark"):
			ice_mark = item.ice_mark
		event_profiles.append_array(item.get("events", []))
		_add_stats(bonuses, item.get("bonuses", {}))
		_add_stats(level_growth, item.get("level_growth", {}))
		item_structure += item.get("structure", 0.0)
		item_structure_scaling += item.get("structure_scaling", 0.0)
		ramps.append_array(item.get("damage_ramps", []))
		_add_stats(wave_growth, item.get("wave_growth", {}))
		regen_conditions.append_array(item.get("regen_conditions", []))
		item_components.append_array(item.get("structure_components", []))
		support_structures.append_array(item.get("support_structures", []))
		full_health_growth.append_array(item.get("full_health_growth", []))
		if item.has("burn"):
			global_burn.chance = global_burn.get("chance", 0.0) + item.burn.chance
			global_burn.damage = global_burn.get("damage", 0.0) + item.burn.damage
			global_burn.duration = max(global_burn.get("duration", 0), item.burn.duration)
			global_burn.scaling = global_burn.get("scaling", item.burn.scaling)
	_add_stats(secondary, bonuses)
	# 非主属性的联动同样会影响输出、经验或建筑，不能只留在 delta 中。
	for linked in ["xp_gain", "explosion_size", "explosion_damage"]:
		if delta.get(linked, 0.0) != 0.0:
			var gain = _context.gains.get(linked, 1.0) if linked == "xp_gain" else 1.0
			bonuses[linked] = bonuses.get(linked, 0.0) + delta[linked] / gain if gain != 0.0 else bonuses.get(linked, 0.0)
	var fruit_stats = Activity.full_health_growth(full_health_growth, event_rates.get("full_health_food", 0.0))
	bonuses.explosion_damage = bonuses.get("explosion_damage", 0.0) + fruit_stats.get("explosion_damage", 0.0) * 0.5
	for item in state.get("items", []):
		for name in item.get("overrides", {}):
			secondary[name] = item.overrides[name]
	var caps = state.get("caps", {})
	for name in caps:
		secondary[name] = caps[name]
	var cooldown_floor = secondary.get("cooldown_floor", _context.get("minimum_cooldown", 0))
	var burn_time = max(0.1, _context.get("burn_time", 0.5) - bonuses.get("burning_cooldown_reduction", 0.0) / 200.0)
	var stack_burns = secondary.get("burning_stacks", 0) > 0
	var growth_stats = {}
	var earning_waves = max(0, remaining - 1) / 2.0
	for stat in fruit_stats:
		if not stat in ["max_hp", "harvesting", "explosion_damage"]:
			growth_stats[stat] = growth_stats.get(stat, 0.0) + fruit_stats[stat] * earning_waves * _context.gains.get(stat, 1.0)
	var future_event_bonuses = bonuses
	if fruit_stats.get("explosion_damage", 0.0) != 0.0:
		future_event_bonuses = bonuses.duplicate()
		future_event_bonuses.explosion_damage += fruit_stats.explosion_damage * earning_waves
	for stat in wave_growth:
		if stat == "xp_gain":
			continue
		# 下一波结束才首次发放；最终波结束的属性不能帮助通关。
		growth_stats[stat] = wave_growth[stat] * earning_waves * _context.gains.get(stat, 1.0)
	var experience = _experience_growth(bonuses, wave_growth, growth_stats, level_growth, delta.get("harvesting", 0.0), secondary.get("harvesting_growth", _context.get("harvesting_growth", 5)))
	var duration = _context.get("wave_duration", 60.0)
	var pacifist = _context.get("pacifist", false)
	var kills = 30.0 + _context.wave * 4.0
	if pacifist:
		# 在留敌构筑中按实测击杀校准永久成长，避免用通用估计预支击杀奖励。
		var record = _context.get("battle_observation", {})
		var seconds = record.get("seconds", 0.0)
		kills = min(kills, record.get("events", {}).get("kills", 0.0) * duration / seconds) if seconds >= 15.0 else 0.0
	var kills_per_weapon = kills / max(1.5, state.weapons.size())
	for weapon in state.weapons:
		for stat in weapon.get("farm_stats", {}):
			var farm_waves = min(1.0, earning_waves) if _context.get("resources", {}).get("destroy_weapons", false) else earning_waves
			growth_stats[stat] = growth_stats.get(stat, 0.0) + weapon.farm_stats[stat] * kills_per_weapon * farm_waves * _context.gains.get(stat, 1.0)
	var route_stat = _routes[route][1] if include_route_growth else ""
	if route_stat != "":
		growth_stats[route_stat] = growth_stats.get(route_stat, 0.0) + max(0, remaining - 1) * _context.get("growth", {}).get(route_stat, _routes[route][2]) * max(0, _context.gains.get(route_stat, 1.0)) * future_weight
	var opening = min(15.0, duration)
	var opening_delta = delta
	if not conditional.empty() or permanent != null or not _context.get("gold_ticks", []).empty():
		opening_delta = delta.duplicate()
		if not _context.get("gold_ticks", []).empty():
			opening_delta = _stat_delta(_wave_wallet_state(state, opening), true, permanent)
			_add_stats(opening_delta, conditional)
			if _context.hp_shop:
				opening_delta.max_hp = opening_delta.get("max_hp", 0.0) - state.get("hp_spent", 0.0)
		var opening_conditions = _conditional_stats(state, event_rates, opening / duration, movement)
		for stat in conditional:
			opening_delta[stat] = opening_delta.get(stat, 0.0) - conditional[stat] + opening_conditions.get(stat, 0.0)
	var ramp_gain = _context.gains.get("percent_damage", 1.0)
	var wave_ramp = ramp_average(ramps, duration) * ramp_gain
	var average_damage = wave_ramp
	var opening_damage = ramp_average(ramps, opening) * ramp_gain
	var conversion = _half_wave_change(permanent, {}) if permanent != null else {}
	var future_conversion = _half_wave_change(permanent, growth_stats) if permanent != null and not growth_stats.empty() else conversion
	var split_wave = not conversion.empty() or not future_conversion.empty()
	if split_wave:
		var first_ramp = ramp_average(ramps, duration * 0.5) * ramp_gain
		average_damage = 2.0 * wave_ramp - first_ramp if second_half else first_ramp
		if opening > duration * 0.5:
			opening_damage = (opening_damage * opening - first_ramp * duration * 0.5) / (opening - duration * 0.5) if second_half else first_ramp
		if second_half:
			_add_stats(delta, conversion)
			for stat in conversion:
				growth_stats[stat] = growth_stats.get(stat, 0.0) - conversion[stat]
			_add_stats(growth_stats, future_conversion)
	var engineering_growth = growth_stats.get("engineering", 0.0)
	var phases = ["current"]
	for amount in growth_stats.values():
		if amount != 0.0:
			phases.append("future")
			break
	var different_opening = opening_delta != delta
	if opening_damage != average_damage or different_opening:
		phases.append("opening")
	var family_counts = {}
	var old_family_counts = {}
	for weapon in state.weapons:
		family_counts[weapon.family] = family_counts.get(weapon.family, 0) + 1
	for weapon in _context.weapons:
		old_family_counts[weapon.family] = old_family_counts.get(weapon.family, 0) + 1
	var density = _context.get("combat_profile", {}).get("density", 2.0)
	for weapon in state.weapons:
		var damage_delta = 0.0
		var growth = 0.0
		for stack in weapon.get("stacks", []):
			if stack.stat == "damage":
				damage_delta += stack.value * (max(0, family_counts.get(stack.family, 0) - 1) - max(0, old_family_counts.get(stack.family, 0) - 1))
		var speed_change = delta.get("attack_speed", 0.0)
		var range_change = delta.get("range", 0.0)
		var speed_ratio = _attack_rate_ratio(weapon, speed_change, cooldown_floor, range_change)
		var opening_speed_ratio = _attack_rate_ratio(weapon, opening_delta.get("attack_speed", 0.0), cooldown_floor, opening_delta.get("range", 0.0)) if different_opening else speed_ratio
		var future_speed_ratio = _attack_rate_ratio(weapon, speed_change + growth_stats.get("attack_speed", 0.0), cooldown_floor, range_change + growth_stats.get("range", 0.0))
		var cannot_shoot = movement == 1 and not _context.get("can_attack_while_moving", true)
		var attack_share = Activity.carry_share(_behavior.segments, weapon.get("projectile_life", 0.0)) if cannot_shoot else 1.0
		var factor = 1.0
		var current_factor = 1.0
		var opening_factor = 1.0
		var projected = {}
		var impact = weapon.get("damage_model", {}).get("impact_explosions", [])
		var impact_cover = Vector2.ONE
		if not impact.empty():
			var effect_size = _context.get("explosion_size", 0.0) + bonuses.get("explosion_size", 0.0)
			impact_cover = Combat.impact_coverage(impact, density, effect_size)
		if weapon.has("damage_components"):
			var melee_ratio = Combat.melee_clear_ratio(weapon, _context.get("battle_observation", {}), density) if weapon.has("melee_trigger_targets") else 1.0
			# 直接伤害、附带弹丸各自用原生的缩放、取整与保底，不能套主武器的倍率。
			for phase in phases:
				var phase_delta = opening_delta if phase == "opening" else delta
				var clear_value = 0.0
				var boss_value = 0.0
				for i in range(weapon.damage_components.size()):
					var component = weapon.damage_components[i]
					var extra_raw = damage_delta if i == 0 and not component.has("base_effects") else 0.0
					var future_stats = growth_stats if phase == "future" else {}
					var damage = projected_damage(component, phase_delta, future_stats, opening_damage if phase == "opening" else average_damage, future_event_bonuses if phase == "future" else bonuses, extra_raw, state)
					var expected_base = max(1.0, _expected_hit(component, component.damage, {}, {}))
					var expected = _expected_hit(component, damage, phase_delta, bonuses, future_stats)
					var additional = _projectile_chain_damage(component, damage, phase_delta, bonuses, future_stats)
					var effective = _effective_hit(component, damage, phase_delta, bonuses, future_stats)
					var clear_hit = melee_ratio
					var single_hit = 1.0
					if weapon.type == 1 and i == 0:
						var accuracy = weapon.get("accuracy", 1.0) + bonuses.get("accuracy", 0.0) / 100.0
						var distance = min(250.0, max(18.0, weapon.reach + range_change))
						clear_hit = Combat.hit_chance(accuracy, distance, 18.0, density, weapon.get("projectile_spread", 0.0))
						single_hit = Combat.hit_chance(accuracy, distance, 36.0, 0.0, weapon.get("projectile_spread", 0.0))
					var cover = impact_cover if i == 0 else Vector2.ONE
					clear_value += component.clear * (effective + additional) / expected_base * clear_hit * cover.x
					boss_value += component.boss * expected / expected_base * single_hit * cover.y
					if phase == "current" and not ice_mark.empty() and component.scaling.has(ice_mark.stat) and component.clear > 0.0:
						mark_hits.append(Vector2(component.clear / expected_base * clear_hit * speed_ratio * attack_share * ice_mark.chance, expected))
				var rate = future_speed_ratio if phase == "future" else (opening_speed_ratio if phase == "opening" else speed_ratio)
				projected[phase] = {"clear": clear_value * rate, "boss": boss_value * rate}
			if not projected.has("future"):
				projected.future = projected.current
			if not projected.has("opening"):
				projected.opening = projected.current
		else:
			var opening_change = 0.0
			for stat in weapon.scaling:
				var change = delta.get(stat, 0.0)
				if stat == "evolution":
					change = abs(_context.stats.get(stat, 0.0) + change) - abs(_context.stats.get(stat, 0.0))
				damage_delta += weapon.scaling[stat] * change
				growth += weapon.scaling[stat] * growth_stats.get(stat, 0.0)
				opening_change += weapon.scaling[stat] * (opening_delta.get(stat, 0.0) - delta.get(stat, 0.0))
			var damage_ratio = max(0.0, weapon.damage + (damage_delta + growth) * weapon.damage_multiplier) / max(1.0, weapon.damage)
			var percent_ratio = max(0.0, 100.0 + _context.stats.percent_damage + delta.get("percent_damage", 0.0) + average_damage) / max(1.0, 100.0 + _context.stats.percent_damage)
			var opening_ratio = max(0.0, 100.0 + _context.stats.percent_damage + opening_delta.get("percent_damage", 0.0) + opening_damage) / max(1.0, 100.0 + _context.stats.percent_damage)
			var expected_before = max(1.0, _expected_hit(weapon, weapon.damage, {}, {}))
			factor = _expected_hit(weapon, max(1.0, round(damage_ratio * weapon.damage * percent_ratio)), delta, bonuses, growth_stats) / expected_before * future_speed_ratio
			current_factor = _expected_hit(weapon, max(1.0, round((weapon.damage + damage_delta * weapon.damage_multiplier) * percent_ratio)), delta, bonuses) / expected_before * speed_ratio
			opening_factor = _expected_hit(weapon, max(1.0, round((weapon.damage + (damage_delta + opening_change) * weapon.damage_multiplier) * opening_ratio)), opening_delta, bonuses) / expected_before * opening_speed_ratio
		if weapon.get("explosive", false) and projected.empty():
			var explosion = max(0.0, 1.0 + bonuses.get("explosion_damage", 0.0) / max(1.0, 100.0 + _context.get("explosion_damage", 0.0)))
			factor *= explosion
			current_factor *= explosion
			opening_factor *= explosion
		var reach_factor = clamp(1.0 + delta.get("range", 0.0) / (1000.0 if weapon.type == 1 else 600.0), 0.5, 1.5)
		if _context.get("resources", {}).get("destroy_weapons", false):
			# 此武器只服务下一波，不能再用它兑现随后获得的成长属性。
			factor = current_factor
			if not projected.empty():
				projected.future = projected.current
		if impact.empty() and weapon.get("explosive", false):
			reach_factor *= max(0.1, 1.0 + bonuses.get("explosion_size", 0.0) / 100.0 * 0.8)
		clear += projected.get("future", weapon).clear * factor * reach_factor * attack_share
		boss += projected.get("future", weapon).boss * factor * attack_share
		current_clear += projected.get("current", weapon).clear * current_factor * reach_factor * attack_share
		current_boss += projected.get("current", weapon).boss * current_factor * attack_share
		opening_clear += projected.get("opening", weapon).clear * opening_factor * reach_factor * attack_share
		# 原生通常共享一个燃烧槽，开启叠加时才分别计算各武器的燃烧。
		var fire = _project_burn(weapon, global_burn, burn_time, delta, growth_stats, average_damage, opening_damage)
		if not ice_mark.empty() and fire.current > 0 and not weapon.scaling.has(ice_mark.stat):
			var burn_scaling = weapon.get("burn_model", global_burn).get("scaling", {})
			if burn_scaling.has(ice_mark.stat):
				var chance = weapon.get("burn_chance", global_burn.get("chance", 0.0))
				var applications = weapon.get("hits_per_second", 0.0) * speed_ratio * attack_share * chance
				mark_hits.append(Vector2(applications * ice_mark.chance, fire.current * burn_time / max(0.001, chance)))
		if cannot_shoot:
			var burn_share = Activity.carry_share(_behavior.segments, max(weapon.get("burn_duration", 0), global_burn.get("duration", 0)) * burn_time)
			for field in ["future", "current", "opening"]:
				fire[field] *= burn_share
		if _context.get("resources", {}).get("destroy_weapons", false):
			fire.future = fire.current
		best_burn = best_burn + fire.future if stack_burns else max(best_burn, fire.future)
		current_burn = current_burn + fire.current if stack_burns else max(current_burn, fire.current)
		best_burn_clear = best_burn_clear + fire.future * fire.cover if stack_burns else max(best_burn_clear, fire.future * fire.cover)
		current_burn_clear = current_burn_clear + fire.current * fire.cover if stack_burns else max(current_burn_clear, fire.current * fire.cover)
		opening_burn_clear = opening_burn_clear + fire.opening * fire.cover if stack_burns else max(opening_burn_clear, fire.opening * fire.cover)
		var base_structure = weapon.get("structure", 0.0) + weapon.get("structure_scaling", 0.0) * delta.get("engineering", 0.0)
		var future_structure = base_structure + weapon.get("structure_scaling", 0.0) * engineering_growth
		var components = weapon.get("structure_components", [])
		var structure = structure_output(components, future_structure, delta, growth_stats, bonuses)
		var current_structure = structure_output(components, base_structure, delta, {}, bonuses)
		if _context.get("resources", {}).get("destroy_weapons", false):
			structure = current_structure
		clear += structure.clear
		boss += structure.boss
		current_clear += current_structure.clear
		current_boss += current_structure.boss
		opening_clear += current_structure.clear
		control += weapon.get("control", 0.0) + min(4.0, max(0, weapon.knockback + bonuses.get("knockback", 0.0)) / 3.0)
		if weapon.type == 1 and not pacifist:
			control += min(2.0, weapon.reach / 350.0)
		healing += weapon.healing * speed_ratio * attack_share
		var hit_rate = weapon.get("hits_per_second", 1.0)
		if weapon.type == 1 and weapon.has("raw_hits_per_second"):
			hit_rate = weapon.raw_hits_per_second * Combat.hit_chance(weapon.get("accuracy", 1.0) + bonuses.get("accuracy", 0.0) / 100.0, min(250.0, max(18.0, weapon.reach + range_change)), 18.0, _context.get("combat_profile", {}).get("density", 2.0), weapon.get("projectile_spread", 0.0))
		var zone_slow = weapon.get("zone_slow_speed", 0.0)
		if zone_slow > 0.0:
			var enemy_speed = _context.get("combat_profile", {}).get("average_enemy_speed", 400.0)
			enemy_speed = max(100.0, enemy_speed)
			var removal = min(zone_slow, enemy_speed * 0.9)
			# 原生每秒恢复 300 速度。取一次作用的速度损失面积，不推定额外受影响的目标数。
			var lost_distance = removal * removal / 600.0
			control += min(1.0, lost_distance / enemy_speed * hit_rate * speed_ratio * attack_share)
		lifesteal_hits += clamp(weapon.get("lifesteal", 0.0) + delta.get("lifesteal", 0.0) / 100.0, 0.0, 1.0) * hit_rate * speed_ratio * attack_share
	healing += min(10.0, lifesteal_hits) * _context.get("lifesteal_amount", 1)
	var base_structures = item_structure + item_structure_scaling * delta.get("engineering", 0.0)
	var tree_loot = _tree_loot(secondary, delta)
	for i in range(item_components.size()):
		if item_components[i].get("tree_turret", false):
			var turret = item_components[i].duplicate()
			# 砍倒后才生成；按平均半波的在场时间折算火力。
			turret.rate *= tree_loot.get("felled", 0.0) * 0.5
			item_components[i] = turret
	var structures = structure_output(item_components, base_structures + item_structure_scaling * engineering_growth, delta, growth_stats, bonuses)
	var current_structures = structure_output(item_components, base_structures, delta, {}, bonuses)
	clear += structures.clear + best_burn_clear
	boss += structures.boss + best_burn
	current_clear += current_structures.clear + current_burn_clear
	current_boss += current_structures.boss + current_burn
	opening_clear += current_structures.clear + opening_burn_clear
	var boss_bonus = max(0.0, 1.0 + bonuses.get("damage_against_bosses", 0.0) / max(1.0, 100.0 + _context.get("boss_damage", 0.0)))
	boss *= boss_bonus
	current_boss *= boss_bonus
	var spread_clear = best_burn * max(0, bonuses.get("burning_spread", 0.0)) * 0.3
	clear += spread_clear
	current_clear += current_burn * max(0, bonuses.get("burning_spread", 0.0)) * 0.3
	opening_clear += current_burn * max(0, bonuses.get("burning_spread", 0.0)) * 0.3
	var wave_pressure = 1.0 + _context.difficulty * 0.09
	var base_enemy_load = max(0.25, 1.0 + _context.get("enemy_count", 0.0) / 100.0)
	var enemy_load = max(0.25, 1.0 + (_context.get("enemy_count", 0.0) + bonuses.get("number_of_enemies", 0.0)) / 100.0)
	var enemy_health = _context.stats.get("enemy_health", 0.0) + bonuses.get("enemy_health", 0.0) * _context.gains.get("enemy_health", 1.0)
	var next_health_factor = max(0.01, 1.0 + (enemy_health + _next_wave_bonus(bonuses, "enemy_health")) / 100.0)
	var clear_target = (18.0 + _context.wave * 15.0) * wave_pressure * enemy_load * next_health_factor
	var boss_target = (12.0 + _context.wave * 10.0) * wave_pressure * next_health_factor
	var profile = _context.get("combat_profile", {})
	if not profile.empty():
		clear_target = profile.clear * enemy_load * next_health_factor
		boss_target = profile.boss * next_health_factor
	var calibration = Combat.calibration(_context.get("battle_observation", {}))
	clear *= calibration
	current_clear *= calibration
	opening_clear *= calibration
	var boss_urgent = _context.get("threat", "normal") == "elite" or _context.wave >= _context.final_wave - 3
	var activity = _activity(state, secondary, delta, min(1.0, current_clear / clear_target), tree_loot)
	if _context.get("resources", {}).get("materials_as_health", false) or _context.get("resources", {}).get("damage_taken_on_materials", false):
		activity.wallet = state.get("gold", _context.get("gold", state.money)) if _context.hp_shop else state.money
		# 波初材料变化立即改变材料防护，尚未获得的掉落不能抵挡开局受击。
		activity.wallet += int(activity.wallet * (_context.get("gold_start_pct", 0.0) + bonuses.get("gain_pct_gold_start_wave", 0.0)) / 100.0)
	var defense = _survival(delta, control, healing, bonuses, regen_conditions, tree_loot.food, secondary, activity, conditional, support_structures, true)
	var weapon_current_clear = current_clear
	var triggered = {"clear": 0.0, "boss": 0.0}
	if not event_profiles.empty() or not conditional.empty() or not full_health_growth.empty():
		if event_rates.empty():
			var event_effects = _context.get("survival_effects", {}).duplicate()
			_add_stats(event_effects, bonuses)
			event_rates = Events.rates(_context, defense, activity, event_effects)
			event_rates.full_health_food = defense.full_health_food
		triggered = Events.output(self, event_profiles, event_rates, delta, bonuses, {}, average_damage)
		var future_events = Events.output(self, event_profiles, event_rates, delta, future_event_bonuses, growth_stats, average_damage) if not growth_stats.empty() or future_event_bonuses != bonuses else triggered
		var opening_events = Events.output(self, event_profiles, event_rates, opening_delta, bonuses, {}, opening_damage) if different_opening or opening_damage != average_damage else triggered
		current_clear += triggered.clear
		current_boss += triggered.boss * boss_bonus
		clear += future_events.clear
		boss += future_events.boss * boss_bonus
		opening_clear += opening_events.clear
	if not ice_mark.empty():
		var structures_with_marks = item_components.duplicate()
		for weapon in state.weapons:
			structures_with_marks.append_array(weapon.get("structure_components", []))
		for component in structures_with_marks:
			if component.scaling.has(ice_mark.stat):
				mark_hits.append(Vector2(component.rate * ice_mark.chance, projected_damage(component, delta, {}, 0.0, bonuses)))
		var marked = _mark_multipliers(mark_hits, ice_mark, profile, next_health_factor, current_clear, current_boss, duration)
		clear *= marked.x
		current_clear *= marked.x
		weapon_current_clear *= marked.x
		opening_clear *= marked.x
		boss *= marked.y
		current_boss *= marked.y
	var future_delta = delta.duplicate()
	_add_stats(future_delta, growth_stats)
	var fruit_growth = 0.0
	var permanent_fruit = Activity.full_health_growth(full_health_growth, event_rates.get("full_health_food", defense.full_health_food), true)
	fruit_growth = permanent_fruit.get("max_hp", 0.0)
	for stat in permanent_fruit:
		if stat != "harvesting":
			continue
		future_delta[stat] = future_delta.get(stat, 0.0) + permanent_fruit[stat] * earning_waves * _context.gains.get(stat, 1.0)
	var uncapped_hp = _context.stats.max_hp + future_delta.get("max_hp", 0.0)
	var hp_room = max(0.0, secondary.get("hp_cap", _context.get("hp_cap", 999999)) - uncapped_hp)
	fruit_growth = min(hp_room, fruit_growth * earning_waves * _context.gains.get("max_hp", 1.0))
	future_delta.max_hp = future_delta.get("max_hp", 0.0) + fruit_growth
	var steady_defense = defense
	if _next_wave_bonus(bonuses, "enemy_damage") != 0 or _next_wave_bonus(bonuses, "enemy_speed") != 0 or secondary.get("hp_start_next_wave", 100.0) != 100.0:
		steady_defense = _survival(delta, control, healing, bonuses, regen_conditions, tree_loot.food, secondary, activity, conditional, support_structures, false)
	# 无成长变化时，后续常驻状态与当前常驻状态相同，复用完整的压力结果。
	var future_defense = steady_defense.duplicate()
	var changed = fruit_growth != 0.0
	for value in growth_stats.values():
		changed = changed or value != 0.0
	if changed:
		future_defense = _survival(future_delta, control, healing, bonuses, regen_conditions, tree_loot.food, secondary, activity, conditional, support_structures, false)
	if profile.get("opening", {}).get("bait_count", 0.0) > 0.0:
		# 鱼饵在第 2 秒增加敌群，后半波更高的峰值可能掩盖这次接敌。
		# 比较前十秒的清场量，对来不及清掉的七鳃鳗估算每只一次接触。
		var opening_spawn = profile.opening
		var pending_health = opening_spawn.health * next_health_factor - opening_clear * opening_spawn.seconds
		var pending = clamp(pending_health / (opening_spawn.bait_hp * next_health_factor), 0.0, opening_spawn.bait_count)
		var exposure = pending * opening_spawn.bait_damage * defense.enemy_damage * _armor_factor(defense.armor) * (1.0 - defense.dodge / 100.0)
		var risk = _saturate(exposure / defense.health_resource)
		defense = defense.duplicate()
		defense.bait_exposure = exposure
		defense.pressure += (1.0 - defense.pressure) * risk
		defense.short_pressure += (1.0 - defense.short_pressure) * risk
	var discount = _discount_value(state, bonuses)
	var economy = _future_income(_context.stats.get("harvesting", 0.0) + delta.get("harvesting", 0.0), secondary.get("harvesting_growth", _context.get("harvesting_growth", 5))) + discount.net + tree_loot.economy + activity.economy
	# 满血拾取在波内发生，本波末可以兑现收获；以后每波的新增成长按剩余波次计，不重复沿用观测金额。
	var harvest_fruit = permanent_fruit.get("harvesting", 0.0) * _context.gains.get("harvesting", 1.0)
	economy += harvest_fruit * pow(max(0, remaining - 1), 2.0) * 0.5
	# 普通敌人数会改变掉落机会。组内最少生成数、拾取和击杀率使实际变化小于面板比例。
	var enemy_change = enemy_load / base_enemy_load - 1.0
	var economy_coverage = min(1.0, current_clear / clear_target) if enemy_change > 0.0 else 1.0
	economy += enemy_change * economy_coverage * _income_reference() * max(0, remaining - 1) * 0.5
	var luck = delta.get("luck", 0.0) / max(25.0, 100.0 + _context.stats.get("luck", 0.0))
	economy += luck * _income_reference() * max(0, remaining - 1) * 0.1
	var wallet = state.get("gold", _context.get("gold", state.money)) if _context.hp_shop else state.money
	var interest_rate = (_context.get("gold_start_pct", 0.0) + bonuses.get("gain_pct_gold_start_wave", 0.0)) / 100.0
	var interest = int(wallet * interest_rate) if remaining > 1 else 0
	# 超出后续商店预计支出的本金仍在游戏中生息，购物时只为可用于补强的本金保留利息价值。
	var interest_value = min(interest, int(discount.future_spend * interest_rate)) if interest > 0 else interest
	economy += interest_value
	var clear_ready = clamp(min(current_clear, opening_clear) / clear_target, 0.0, 1.0)
	var boss_ready = clamp(current_boss / boss_target, 0.0, 1.0) if boss_urgent else 1.0
	var slots = state.get("slots", _context.rules.slots)
	var future_slots = max(0, slots - max(_context.rules.slots, state.weapons.size()))
	var slot_value = future_slots * 0.30 / max(2, _context.rules.slots) if remaining > 1 else 0.0
	var cap_cost = _cap_cost(caps, delta, earning_waves)
	var score = {"defense": defense, "future_defense": future_defense, "experience": experience, "activity": activity, "fruit_growth": fruit_growth, "caps": caps, "cap_cost": cap_cost, "economy": economy, "discount": discount, "tree_loot": tree_loot, "structures_can_crit": _context.get("structures_can_crit", false) or bonuses.get("structures_can_crit", 0) > 0, "interest": interest, "clear": clear, "boss": boss, "current_clear": current_clear, "current_boss": current_boss, "opening_clear": opening_clear, "average_damage_ramp": wave_ramp, "clear_target": clear_target, "boss_target": boss_target, "enemy_load": enemy_load, "enemy_health": next_health_factor, "later_enemy_health": max(0.01, 1.0 + enemy_health / 100.0), "boss_urgent": boss_urgent, "clear_ready": clear_ready, "boss_ready": boss_ready, "weapon_count": state.weapons.size(), "slots": slots, "slot_value": slot_value, "need_damage": not _context.get("pacifist", false) and min(clear_ready, boss_ready) < 1.0, "split_wave": split_wave, "conversion": conversion}
	var boss_share = 0.45 if boss_urgent else 0.25
	score.interest_value = interest_value
	score.events = event_rates
	score.full_health_stats = permanent_fruit
	score.bait_groups = bonuses.get("bait_groups", 0)
	score.event_output = triggered
	score.weapon_clear = weapon_current_clear
	if _context.get("threat", "normal") == "horde":
		boss_share = 0.10
	# 留敌获得材料的职业只有在能实际消化刷怪量时，才接近常规输出收益。
	var output_weight = 2.5 * clear_ready if _context.get("pacifist", false) else 2.5
	# 同一波次固定参照下的绝对效用；过剩火力仍有收益，但边际递减。
	# 同时考虑整波与开局，避免仅取最小值而丢掉波内成长的后程收益。
	var clear_utility = 0.75 * _saturate(current_clear / clear_target) + 0.25 * _saturate(opening_clear / clear_target)
	score.combat_utility = output_weight * ((1.0 - boss_share) * clear_utility + boss_share * _saturate(current_boss / boss_target))
	var later_factor = next_health_factor / score.later_enemy_health
	var future_opening = max(0.0, opening_clear + clear - current_clear)
	var future_clear_utility = 0.75 * _saturate(clear * later_factor / clear_target) + 0.25 * _saturate(future_opening * later_factor / clear_target)
	var future_combat = output_weight * ((1.0 - boss_share) * future_clear_utility + boss_share * _saturate(boss * later_factor / boss_target))
	var steady_clear_utility = 0.75 * _saturate(current_clear * later_factor / clear_target) + 0.25 * _saturate(opening_clear * later_factor / clear_target)
	var steady_combat = output_weight * ((1.0 - boss_share) * steady_clear_utility + boss_share * _saturate(current_boss * later_factor / boss_target))
	# 养成只比较相同常驻条件下的额外变化，临时惩罚消失本身不是成长收益。
	score.growth_utility = future_combat - steady_combat + 2.0 * (steady_defense.pressure - future_defense.pressure) if remaining > 1 else 0.0
	return score


func pacifist_survival_risk() -> float:
	if not _context.get("pacifist", false) or _context.get("future_shop", false):
		return 0.0
	var observed = _context.get("battle_observation", {})
	var retries = observed.get("wave_retries", 0)
	var low = observed.get("below_half_share", 0.0)
	# 五秒以上低血才视为持续受压。重试占已打场数的比例来自刚结束的一波。
	var sustained = low if low * observed.get("seconds", 0.0) >= 5.0 else 0.0
	return max(sustained, retries / (1.0 + retries))


func _stage_priority(score: Dictionary) -> String:
	if pacifist_survival_risk() > 0:
		return "observed_survival"
	if score.need_damage:
		if _context.wave <= 5 and score.weapon_count < _context.rules.slots and score.clear_ready < 1.0:
			return "slots"
		return "firepower"
	# 分类仅用于解释，不参与打分、候选筛选或排序。
	if score.defense.pressure > 0.35:
		return "sustain"
	return ""


func _priority_note(score: Dictionary) -> String:
	match _priority:
		"observed_survival":
			var observed = _context.battle_observation
			return "阶段目标：上波重试 %d 次，%.0f%% 的时间低于半血，优先寻找能降低承伤的补强" % [observed.get("wave_retries", 0), observed.get("below_half_share", 0.0) * 100.0]
		"slots":
			return "阶段目标：铺武器槽（%d/%d），用能提高开局清场的武器填槽" % [score.weapon_count, _context.rules.slots]
		"firepower":
			return "阶段目标：补即战力，清场达到参考线的 %.0f%%，%s" % [score.clear_ready * 100.0, "单体达到 %.0f%%" % (score.boss_ready * 100.0) if score.boss_urgent else "可通过合成或换装补强"]
		"sustain":
			return "阶段目标：降低持续生存压力，承压、恢复和走位收益一起比较"
	return "阶段目标：生存较宽裕，继续比较补强、成长和预算（压力估计，不是通关概率）"


func gains(before: Dictionary, after: Dictionary) -> Dictionary:
	var combat = after.combat_utility - before.combat_utility
	var survival = 2.0 * (before.defense.pressure - after.defense.pressure)
	# 只把已知养成的额外变化归入未来，当前收益已经计过一次。
	var future = after.growth_utility - before.growth_utility
	future += after.experience.upgrades - before.experience.upgrades + after.slot_value - before.slot_value + before.cap_cost - after.cap_cost
	var economy = (after.economy - before.economy) / (_income_reference() * max(1, _context.final_wave - _context.wave - 1))
	var immediate = combat + survival
	return {"score": 100.0 * (immediate + 0.65 * future + economy), "immediate": immediate * 100.0, "combat": combat * 100.0, "survival": survival * 100.0, "future": future * 100.0, "economy": economy * 100.0}


func purchase_threshold(price: float) -> float:
	if price <= 0:
		return 0.0
	var remaining = _context.final_wave - _context.wave
	var rate = 0.25 if remaining <= 1 else (0.75 if remaining <= 4 else 1.5)
	return max(0.0 if remaining <= 1 else (0.10 if remaining <= 4 else 0.25), rate * price / _income_reference())


func _saturate(value: float) -> float:
	value = max(0.0, value)
	return value / (1.0 + value)


func _income_reference() -> float:
	return max(25.0, _context.get("last_wave_income", max(40.0, _context.wave * 18.0)))


func next_shop(state: Dictionary, route: String, conservative: bool = true) -> Dictionary:
	var score = evaluate(state, route)
	var delta = _stat_delta(state)
	var source = _copy(state)
	source.projected_harvesting = _context.stats.get("harvesting", 0.0) + delta.get("harvesting", 0.0)
	var income = score.activity.income
	income *= 0.75 if conservative else 1.0
	source.settlement_income = score.activity.get("settlement", 0.0) * (0.75 if conservative else 1.0)
	source.activity_growth = score.get("full_health_stats", {}).duplicate()
	source.activity_growth.erase("explosion_damage")
	for stat in source.activity_growth:
		source.activity_growth[stat] *= 0.75 if conservative else 1.0
	var ticks = _context.get("gold_ticks", [])
	if not ticks.empty():
		var wallet = state.gold if _context.hp_shop else state.money
		wallet += int(wallet * _context.get("gold_start_pct", 0.0) / 100.0)
		income += Activity.gold_ticks(wallet, _behavior.segments, ticks, income).income
	var resources = _context.get("resources", {})
	var loss = 0.0
	if resources.get("materials_as_health", false):
		loss = score.defense.incoming * _context.get("wave_duration", 60.0)
	elif resources.get("damage_taken_on_materials", false):
		loss = max(0.0, (score.defense.incoming - max(0.0, score.defense.recovery)) * _context.get("wave_duration", 60.0) - score.defense.opening_hp)
	if income < 0:
		loss -= income
		income = 0.0
	var projected = Resources.project(_context, source, _permanent_stat_delta(state), income, loss)
	source.money = projected.money
	source.hp_fraction = projected.stats.max_hp - projected.money if _context.hp_shop else 0.0
	source.gold = projected.gold
	source.weapons = projected.weapons
	source.used = []
	source.actions = []
	source.hurdle = 0.0
	source.bonus_stats = state.get("bonus_stats", {}).duplicate()
	for stat in projected.stat_changes:
		var gain = _context.gains.get(stat, 1.0)
		if gain != 0.0:
			source.bonus_stats[stat] = source.bonus_stats.get(stat, 0.0) + projected.stat_changes[stat] / gain
	projected.state = source
	return projected


func _next_wave_bonus(bonuses: Dictionary, stat: String) -> float:
	return (_context.get("next_wave_effects", {}).get(stat, 0.0) + bonuses.get("next_" + stat, 0.0)) * _context.gains.get(stat, 1.0)


func _forecast_levels(added_xp: float, next_xp: float, xp_growth: float, harvest_delta: float = 0.0, harvest_growth: float = -1.0, harvest_flat: float = 0.0) -> float:
	var profile = _context.get("progression", {})
	var horizon = _context.final_wave - _context.wave - 1
	if profile.empty() or horizon <= 0:
		return 0.0
	var level = profile.level
	var xp = profile.xp
	var factor = max(0.01, profile.factor)
	var needed = profile.needed.call_func(level + 1) * factor
	var start_progress = xp / needed
	var average = 0.0
	# 实测基础经验已去掉波末结算；无记录时从材料参考中扣去收获部分。
	var base = profile.get("base_xp", max(0.0, _income_reference() - max(0.0, _context.stats.get("harvesting", 0.0))))
	var harvest = _context.stats.get("harvesting", 0.0) + harvest_delta
	var harvest_rate = _context.get("harvesting_growth", 5) if harvest_growth < 0 else harvest_growth
	var harvest_gain = _context.gains.get("harvesting", 1.0)
	var gain = _context.gains.get("xp_gain", 1.0)
	var permanent = _context.stats.get("xp_gain", 0.0) + added_xp * gain
	var first_wave = _next_wave_bonus({"next_xp_gain": next_xp}, "xp_gain")
	for i in range(horizon):
		var rate = permanent + xp_growth * i * gain + (first_wave if i == 0 else 0.0)
		var wave_base = base * (1.0 + float(i + 1) / max(1, _context.wave))
		harvest += (_context.get("wave_growth", {}).get("harvesting", 0.0) + harvest_flat) * harvest_gain
		xp += (wave_base + max(0, int(harvest))) * max(0.0, 1.0 + rate / 100.0)
		if harvest > 0:
			harvest += ceil(harvest * harvest_rate / 100.0) * harvest_gain
		while xp >= needed:
			xp -= needed
			level += 1
			needed = profile.needed.call_func(level + 1) * factor
		average += level - profile.level + xp / needed - start_progress
	return average / horizon


func _experience_growth(bonuses: Dictionary, wave_growth: Dictionary, growth_stats: Dictionary, level_growth: Dictionary, harvest_delta: float = 0.0, harvest_growth: float = -1.0) -> Dictionary:
	var profile = _context.get("progression", {})
	var result = {"levels": 0.0, "upgrades": 0.0}
	var extra = bonuses.get("xp_gain", 0.0)
	var next = bonuses.get("next_xp_gain", 0.0)
	var growth = wave_growth.get("xp_gain", 0.0)
	var harvest_flat = wave_growth.get("harvesting", 0.0) - _context.get("wave_growth", {}).get("harvesting", 0.0)
	var changed_harvest = harvest_delta != 0.0 or harvest_flat != 0.0 or (harvest_growth >= 0 and harvest_growth != _context.get("harvesting_growth", 5))
	if profile.empty() or (not changed_harvest and level_growth.empty() and extra == 0.0 and next == 0.0 and growth == _context.get("wave_growth", {}).get("xp_gain", 0.0)):
		return result
	var levels = _forecast_levels(extra, next, growth, harvest_delta, harvest_growth, harvest_flat)
	result.levels = levels - _base_levels
	for stat in profile.level_stats:
		growth_stats[stat] = growth_stats.get(stat, 0.0) + result.levels * profile.level_stats[stat] * _context.gains.get(stat, 1.0)
	for stat in level_growth:
		growth_stats[stat] = growth_stats.get(stat, 0.0) + levels * level_growth[stat] * _context.gains.get(stat, 1.0)
	if profile.upgrades:
		var slots_left = max(0, profile.slot_limit - _context.rules.slots)
		var extra_slots = min(levels, slots_left) - min(_base_levels, slots_left)
		# 未知升级卡用平均价值估计，仍有槽位升级的角色另计其开槽价值。
		result.upgrades = result.levels * 0.08 + extra_slots * 0.12 / max(1, _context.rules.slots)
	return result


func explain_gain(before: Dictionary, after: Dictionary, gain: Dictionary) -> String:
	var reason = "清场 %s，单体 %s，有效生命 %s，移动 %s，成长折现 %+.2f 分，经济 %+.2f 分；综合 %+.2f 分" % [_percent_change(before.current_clear, after.current_clear), _percent_change(before.current_boss, after.current_boss), _percent_change(before.defense.durability, after.defense.durability), _percent_change(before.defense.movement, after.defense.movement), gain.future * 0.65, gain.economy, gain.score]
	reason += "；参考压力 %.1f → %.1f（越低越好），预计恢复 %.2f → %.2f/秒" % [before.defense.pressure * 100.0, after.defense.pressure * 100.0, before.defense.recovery, after.defense.recovery]
	reason += "；输出 %+.2f、生存 %+.2f 分" % [gain.combat, gain.survival]
	var wave_tradeoff = _explain_wave_tradeoff(before, after)
	if wave_tradeoff != "":
		reason += "；" + wave_tradeoff
	if not before.structures_can_crit and after.structures_can_crit:
		reason += "；构筑物开始继承角色暴击"
	if before.slots != after.slots:
		reason += "；武器槽 %d → %d，空槽价值按后续能填入的机会估计" % [before.slots, after.slots]
	if before.activity.pickup_radius != after.activity.pickup_radius:
		reason += "；拾取半径 %.0f → %.0f" % [before.activity.pickup_radius, after.activity.pickup_radius]
	var event_healing = after.activity.recovery - before.activity.recovery
	if abs(event_healing) >= 0.005:
		reason += "；掉落拾取及击杀触发预计每秒治疗 %+.2f" % event_healing
	var fruit_growth = after.fruit_growth - before.fruit_growth
	var fruit_regen = after.defense.fruit_regen - before.defense.fruit_regen
	if abs(fruit_growth) + abs(fruit_regen) >= 0.005:
		reason += "；满血收集按约 20%% 估计并随开局生命折减，后续波次平均生命上限 %+.1f，本波平均再生 %+.1f" % [fruit_growth, fruit_regen]
	var tree_materials = after.tree_loot.materials - before.tree_loot.materials
	var tree_food = after.tree_loot.food - before.tree_loot.food
	var tree_crates = after.tree_loot.crates - before.tree_loot.crates
	if abs(tree_materials) + abs(tree_food) + abs(tree_crates) >= 0.005:
		reason += "；每波额外树木收益变化：材料 %+.1f、治疗掉落 %+.2f（其中宝箱 %+.2f），按拾取估计" % [tree_materials, tree_food, tree_crates]
	var free_now = after.discount.free_now - before.discount.free_now
	var free_later = after.discount.free_later - before.discount.free_later
	if abs(free_now) + abs(free_later) >= 0.05:
		reason += "；预计免费刷新节省本店 %.1f、后续 %.1f 材料" % [free_now, free_later]
	return reason


func _explain_wave_tradeoff(before: Dictionary, after: Dictionary) -> String:
	var details = PoolStringArray()
	if before.get("bait_groups", 0) != after.get("bait_groups", 0):
		details.append("鱼饵召敌后的下波清场需求 %.1f → %.1f 生命/秒" % [before.clear_target, after.clear_target])
		details.append("开局鱼饵敌群额外承伤估计 %.1f → %.1f" % [before.defense.get("bait_exposure", 0.0), after.defense.get("bait_exposure", 0.0)])
	if before.defense.burst_hit > 0 and before.defense.burst_margin != after.defense.burst_margin:
		details.append("两次重击后生命余量 %d → %d" % [before.defense.burst_margin, after.defense.burst_margin])
	if before.defense.opening_hp != after.defense.opening_hp:
		details.append("下波起始生命 %d → %d" % [before.defense.opening_hp, after.defense.opening_hp])
	if before.defense.enemy_damage != after.defense.enemy_damage or before.enemy_health != after.enemy_health:
		details.append("下波敌伤倍率 %.2f → %.2f，敌生命倍率 %.2f → %.2f" % [before.defense.enemy_damage, after.defense.enemy_damage, before.enemy_health, after.enemy_health])
	var levels = after.experience.levels - before.experience.levels
	if abs(levels) >= 0.005:
		details.append("按角色经验门槛，后续各波平均可用等级 %+.2f" % levels)
	for cap in after.caps:
		if before.caps.get(cap, INF) != after.caps[cap]:
			details.append("%s封顶 %.0f，后续成长机会代价估计 %.2f 分" % ["生命" if cap == "hp_cap" else "移速", after.caps[cap], after.cap_cost * 65.0])
	return details.join("；")


func explain_burst(score: Dictionary) -> String:
	if score.defense.burst_hit <= 0:
		return ""
	return "第 %d 波两击估算：单击受伤 %d，两击后生命余量 %d（不计闪避或恢复）" % [_context.burst.wave, score.defense.burst_hit, score.defense.burst_margin]


func _percent_change(before: float, after: float) -> String:
	if before <= 0:
		return "0 → %.2f" % after
	return "%+.2f%%" % ((after - before) / before * 100.0)


func _mark_multipliers(hits: Array, mark: Dictionary, profile: Dictionary, health_factor: float, clear: float, boss: float, duration: float) -> Vector2:
	var weight = 0.0
	var covered = 0.0
	var largest = 1.0
	var density = max(1.0, profile.get("density", 1.0))
	for target in profile.get("targets", []):
		var hp = max(1.0, target.hp * health_factor)
		var damage_weight = hp * target.weight
		covered += damage_weight * Combat.marked_share(hits, hp, target.get("armor", 0.0), clear, density, mark.duration, duration)
		weight += damage_weight
		largest = max(largest, hp)
	var boss_hp = max(largest, profile.get("boss_health", 0.0) * health_factor)
	var single = Combat.marked_share(hits, boss_hp, 0.0, boss, 1.0, mark.duration, duration)
	return Vector2(1.0, 1.0) + Vector2(covered / max(1.0, weight), single) * mark.percent / 100.0


func _project_burn(weapon: Dictionary, global_burn: Dictionary, tick: float, delta: Dictionary, growth: Dictionary, average: float, opening: float) -> Dictionary:
	var burn = weapon.get("burn", 0.0)
	var cover = weapon.get("burn_coverage", 0.4)
	var base_tick = _context.get("burn_time", 0.5)
	if weapon.get("native_burn", false) and weapon.has("burn_model"):
		var model = weapon.burn_model
		var extra = global_burn.get("damage", 0.0) - _context.get("global_burn", {}).get("damage", 0.0)
		var frequency = burn * base_tick / (tick * max(1.0, model.damage))
		return {"future": projected_damage(model, delta, growth, average, {}, extra) * frequency, "current": projected_damage(model, delta, {}, average, {}, extra) * frequency, "opening": projected_damage(model, delta, {}, opening, {}, extra) * frequency, "cover": cover}
	if global_burn.get("chance", 0.0) > 0.0 and global_burn.get("duration", 0) > 0:
		var raw = global_burn.damage
		for stat in global_burn.scaling:
			raw += global_burn.scaling[stat] * _context.stats.get(stat, 0.0)
		var model = {"raw": raw, "multiplier": 1.0 + _context.stats.percent_damage / 100.0, "scaling": global_burn.scaling}
		var frequency = clamp(global_burn.chance, 0.0, 1.0) / tick
		cover = clamp(weapon.get("hits_per_second", 0.0) * global_burn.duration * 0.25, 1.0, 8.0)
		return {"future": projected_damage(model, delta, growth, average) * frequency, "current": projected_damage(model, delta, {}, average) * frequency, "opening": projected_damage(model, delta, {}, opening) * frequency, "cover": cover}
	return {"future": burn, "current": burn, "opening": burn, "cover": cover}


func projected_damage(model: Dictionary, delta: Dictionary, future: Dictionary = {}, ramp: float = 0.0, bonuses: Dictionary = {}, extra_raw: float = 0.0, state: Dictionary = {}) -> float:
	var raw = model.raw + extra_raw
	if not state.empty() and not model.get("base_effects", []).empty():
		raw += _weapon_base_damage(model, state, future, bonuses) - model.applied_base
	for stat in model.scaling:
		var change = delta.get(stat, 0.0) + future.get(stat, 0.0)
		if stat == "evolution":
			change = abs(_context.stats.get(stat, 0.0) + change) - abs(_context.stats.get(stat, 0.0))
		raw += model.scaling[stat] * change
	if model.get("direct_weapon", false):
		for key in bonuses:
			if key.begins_with("weapon_scaling_"):
				var stat = key.trim_prefix("weapon_scaling_")
				raw += (_context.stats.get(stat, 0.0) + delta.get(stat, 0.0) + future.get(stat, 0.0)) * bonuses[key]
	var multiplier = model.multiplier
	if not model.get("structure", false) or model.get("structure_pet", false):
		multiplier += (delta.get("percent_damage", 0.0) + future.get("percent_damage", 0.0) + ramp) / 100.0
	if model.get("exploding", false):
		multiplier += bonuses.get("explosion_damage", 0.0) / 100.0
	return float(max(1, round(int(max(1.0, raw)) * multiplier)))


func _weapon_base_damage(model: Dictionary, state: Dictionary, future: Dictionary, bonuses: Dictionary) -> float:
	var base = model.base
	var permanent = _permanent_stat_delta(state)
	var sources = _projected_link_sources(state, _weapon_family_count(_context.weapons), _weapon_family_count(state.weapons))
	sources.free_weapon_slots = state.get("slots", _context.rules.slots) - state.weapons.size()
	sources.materials = state.get("gold", _context.money) if _context.hp_shop else state.money
	for effect in model.base_effects:
		if effect.kind == "stack":
			var count = 0
			for held in state.weapons:
				if held.family == effect.family:
					count += 1
			base += effect.value * max(0, count - 1)
			continue
		var stat = effect.source.trim_prefix("stat_")
		var value = _context.get("permanent_stats", _context.stats).get(stat, 0.0) + permanent.get(stat, 0.0) + future.get(stat, 0.0)
		if effect.kind == "multiply":
			# 原生条件读取未乘收益倍率的常驻效果；击退等副属性直接读取效果值。
			var gain = _context.gains.get(stat, 1.0)
			value = effect.current + (permanent.get(stat, 0.0) + future.get(stat, 0.0)) / gain if effect.source.begins_with("stat_") and gain != 0 else effect.current + bonuses.get(stat, 0.0)
			if value >= effect.threshold:
				base = round(base * effect.factor)
		else:
			value = sources.get(effect.source, value)
			base += int(effect.value * value / effect.per)
	return base


func _attack_rate_ratio(weapon: Dictionary, change: float, floor_frames: float = -1.0, range_change: float = 0.0) -> float:
	var old_floor = weapon.get("cooldown_floor", 0.0) * 60.0
	var new_floor = old_floor if floor_frames < 0.0 else floor_frames
	if change == 0 and (weapon.type == 1 or range_change == 0) and is_equal_approx(old_floor, new_floor):
		return 1.0
	var base_speed = _context.stats.attack_speed + weapon.get("attack_speed_mod", 0.0)
	var after = (base_speed + change) / 100.0
	if weapon.has("attack_timing"):
		var timing = weapon.attack_timing
		var recoil = timing.recoil / max(1.0, 1.0 + after)
		var animation = recoil * 2.0
		var limit_animation = animation
		if weapon.type == 0:
			animation = timing.attack_duration
			if animation <= 0.0:
				# 原生面板按最大攻击距离显示参考周期。横扫实战会随目标距离变化。
				var reach = int(max(timing.min_range, timing.base_range + (_context.stats.get("range", 0.0) + range_change) / 2.0))
				animation = _melee_animation_time(reach, timing.animation_speed, after, recoil)
			if new_floor > 0.0 or timing.max_frames < INF:
				# WeaponService 先在原始射程和默认动作上限制冷却，再应用近战的专用动画和范围属性。
				limit_animation = _melee_animation_time(timing.base_range, 1.0, after, recoil)
		var cooldown = _scaled_cooldown_frames(max(2, timing.frames), after)
		var reload_multiplier = timing.reload_multiplier
		var base_reload = timing.frames * reload_multiplier
		if timing.reload_shots > 0 and base_reload > 0.0:
			reload_multiplier = max(1.0, float(_scaled_cooldown_frames(round(base_reload), after)) / cooldown)
		var extra_frames = int(ceil(max(0.0, new_floor - (limit_animation + cooldown / 60.0) * 60.0)))
		if extra_frames > 0 and timing.reload_shots > 0:
			reload_multiplier = max(1.0, reload_multiplier * cooldown / (cooldown + extra_frames))
		cooldown += extra_frames
		cooldown -= int(ceil(max(0.0, (limit_animation + cooldown / 60.0) * 60.0 - timing.max_frames)))
		var reload_average = cooldown * (reload_multiplier - 1.0) / timing.reload_shots if timing.reload_shots > 0 else 0.0
		return weapon.interval / max(0.03, animation + (cooldown + reload_average) / 60.0)
	# 缺少可重算数据的条件武器，仍按当前间隔估计。
	var speed = base_speed / 100.0
	var before_time = 1.0 - speed if speed < 0 else 1.0 / (1.0 + speed)
	var after_time = 1.0 - after if after < 0 else 1.0 / (1.0 + after)
	if not weapon.has("interval"):
		return before_time / after_time
	var interval = weapon.interval * after_time / before_time
	return weapon.interval / max(2.0 / 60.0, max(new_floor / 60.0, interval))


func _melee_animation_time(reach: float, animation_speed: float, attack_speed: float, recoil: float) -> float:
	var range_factor = max(0.0, reach / clamp(70.0 * (1.0 + attack_speed / 3.0), 70.0, 120.0))
	var swing = (max(0.01, 0.2 - attack_speed / 10.0) + range_factor * 0.15) / animation_speed
	var recovery = 0.2 / max(1.0, 1.0 + attack_speed * 3.0) / animation_speed
	return swing / 2.0 + recovery + recoil


func _scaled_cooldown_frames(frames: float, attack_speed: float) -> int:
	return int(max(2.0, frames * (1.0 - attack_speed) if attack_speed < 0 else frames / (1.0 + attack_speed)))


func structure_output(components: Array, fallback: float, delta: Dictionary, future: Dictionary, bonuses: Dictionary) -> Dictionary:
	if components.empty():
		return {"clear": max(0.0, fallback) * 1.3, "boss": max(0.0, fallback)}
	var result = {"clear": 0.0, "boss": 0.0}
	var speed = _structure_speed(delta, future, bonuses)
	for component in components:
		var rate = component.rate
		if component.has("structure_timing"):
			var timing = component.structure_timing
			rate *= float(timing.current) / max(1, _scaled_cooldown_frames(timing.base, speed))
			if timing.reach > 0:
				rate *= clamp(1.0 + bonuses.get("structure_range", 0.0) / max(200.0, timing.reach * 2.0), 0.5, 1.5)
		var damage = projected_damage(component, delta, future, 0.0, bonuses)
		var output = _expected_hit(component, damage, delta, bonuses, future) * rate
		result.boss += output
		result.clear += _effective_hit(component, damage, delta, bonuses, future) * rate * component.get("clear_multiplier", 1.3)
	return result


func _structure_speed(delta: Dictionary, future: Dictionary, bonuses: Dictionary) -> float:
	var speed = _context.get("structure_speed", 0.0) + bonuses.get("structure_attack_speed", 0.0) + delta.get("structure_attack_speed", 0.0) + future.get("structure_attack_speed", 0.0)
	for stat in _context.get("structure_speed_scaling", {}):
		speed += (delta.get(stat, 0.0) + future.get(stat, 0.0)) * _context.structure_speed_scaling[stat]
	for key in bonuses:
		if key.begins_with("structure_scaling_"):
			var stat = key.trim_prefix("structure_scaling_")
			speed += (_context.stats.get(stat, 0.0) + delta.get(stat, 0.0) + future.get(stat, 0.0)) * bonuses[key]
	return speed / 100.0


func _expected_hit(model: Dictionary, damage: float, delta: Dictionary, bonuses: Dictionary, future: Dictionary = {}) -> float:
	var already_enabled = model.get("can_crit", true)
	if not already_enabled and (not model.get("structure", false) or bonuses.get("structures_can_crit", 0) <= 0):
		return damage
	var crit_change = delta.get("crit_chance", 0.0) + future.get("crit_chance", 0.0)
	var player_crit = _context.stats.get("crit_chance", 0.0)
	var cap = _context.get("crit_cap", 999999)
	crit_change = min(cap, player_crit + crit_change) - (min(cap, player_crit) if already_enabled else 0.0)
	var chance = clamp(model.get("crit_chance", 0.0) + crit_change / 100.0, 0.0, 1.0)
	var crit_bonus = bonuses.get("bonus_crit_damage", 0.0) + (0.0 if already_enabled else _context.get("bonus_crit_damage", 0.0))
	var multiplier = model.get("crit_damage", 1.5) + crit_bonus / 100.0
	return lerp(damage, max(1.0, round(damage * multiplier)), chance)


func _effective_hit(model: Dictionary, damage: float, delta: Dictionary, bonuses: Dictionary, future: Dictionary) -> float:
	var targets = _context.get("combat_profile", {}).get("targets", [])
	if targets.empty():
		return _expected_hit(model, damage, delta, bonuses, future)
	var crit_bonus = bonuses.get("bonus_crit_damage", 0.0) + (0.0 if model.get("can_crit", true) else _context.get("bonus_crit_damage", 0.0))
	var critical = max(1.0, round(damage * (model.get("crit_damage", 1.5) + crit_bonus / 100.0)))
	var expected = _expected_hit(model, damage, delta, bonuses, future)
	var chance = clamp((expected - damage) / (critical - damage), 0.0, 1.0) if critical != damage else 0.0
	var health = _context.stats.get("enemy_health", 0.0) + bonuses.get("enemy_health", 0.0) * _context.gains.get("enemy_health", 1.0) + _next_wave_bonus(bonuses, "enemy_health")
	var key = str([damage, critical, chance, health, _context.combat_profile.get("bait_key", null)])
	if not _hit_scores.has(key):
		_hit_scores[key] = Combat.effective_hit(damage, critical, chance, targets, max(0.01, 1.0 + health / 100.0))
	return _hit_scores[key]


func _projectile_chain_damage(model: Dictionary, damage: float, delta: Dictionary, bonuses: Dictionary, future: Dictionary) -> float:
	if not model.has("projectile_chain"):
		return 0.0
	var projectile = model.projectile_chain
	var bounces = max(0, projectile.bounces + bonuses.get("bounce", 0)) if projectile.can_bounce else 0
	var pierces = max(0, projectile.pierces + bonuses.get("piercing", 0))
	var on_crit = projectile.get("bounce_on_crit", 0) + projectile.get("pierce_on_crit", 0)
	if bounces == 0 and pierces == 0 and on_crit == 0:
		return 0.0
	var bounce_reduction = clamp(projectile.bounce_reduction - bonuses.get("bounce_damage", 0.0) / 100.0, 0.0, 1.0)
	var pierce_reduction = clamp(projectile.pierce_reduction - bonuses.get("piercing_damage", 0.0) / 100.0, 0.0, 1.0)
	var weight = 1.0
	var additional = 0.0
	# 原生先弹射再穿透，逐次截断伤害。额外命中覆盖率仍需估计。
	for chain in [[bounces, bounce_reduction, 0.65], [pierces, pierce_reduction, 0.6]]:
		for _i in range(min(4, chain[0])):
			damage = max(1, int(damage - damage * chain[1]))
			weight *= chain[2]
			additional += weight * _effective_hit(model, damage, delta, bonuses, future)
	if on_crit > 0:
		var chance = clamp(model.crit_chance + (delta.get("crit_chance", 0.0) + future.get("crit_chance", 0.0)) / 100.0, 0.0, 1.0)
		var bounce = projectile.get("bounce_on_crit", 0) > 0
		for _i in range(on_crit):
			damage = max(1, int(damage * (1.0 - (bounce_reduction if bounce else pierce_reduction))))
			weight *= chance * (0.65 if bounce else 0.6)
			additional += weight * _effective_hit(model, damage, delta, bonuses, future)
	return additional


func _discount_value(state: Dictionary, bonuses: Dictionary) -> Dictionary:
	var spend = 0.0
	var horizon = max(0, _context.final_wave - _context.wave - 1)
	var income = max(0.0, _context.get("last_wave_income", max(40.0, _context.wave * 18.0)))
	for i in range(horizon):
		spend += income * (1.0 + i * 0.025)
	var prices = _context.get("price_effects", {})
	var all_discount = -bonuses.get("items_price", 0.0) / max(1.0, 100.0 + prices.get("items_price", 0.0))
	var weapon_discount = -bonuses.get("weapons_price", 0.0) / max(1.0, 100.0 + prices.get("weapons_price", 0.0))
	var roll_discount = -bonuses.get("reroll_price", 0.0) / max(10.0, 100.0 + prices.get("reroll_price", 0.0))
	# 尚未出现的购买组成只能估计：70% 商品、其中 35% 武器，30% 刷新。
	var saved = spend * (0.7 * all_discount + 0.7 * 0.35 * weapon_discount + 0.3 * roll_discount)
	var page_saved = 0.0
	for action in state.get("actions", []):
		var purchase = action.steps.back() if action.kind == "bundle" else action
		if purchase.kind != "buy":
			continue
		for offer in _context.offers:
			if offer.index == purchase.index:
				page_saved += offer.price - purchase.price
				break
	saved += page_saved
	var free_refresh = _free_refresh_value(state, bonuses)
	saved += free_refresh.now + free_refresh.later
	var invested = state.get("economy_investment", 0.0)
	return {"saved": saved, "invested": invested, "net": saved - invested, "future_spend": spend, "horizon": horizon, "free_now": free_refresh.now, "free_later": free_refresh.later}


func _free_refresh_value(state: Dictionary, bonuses: Dictionary) -> Dictionary:
	var value = {"now": 0.0, "later": 0.0}
	var extra = int(bonuses.get("free_rerolls", 0))
	var profile = _context.get("free_refresh", {})
	if extra <= 0 or profile.empty() or profile.fees.empty():
		return value
	var use_weight = 0.0
	# 依次减半估计用到第 N 次免费的机会，已有次数占用较高的权重。
	for i in range(extra):
		use_weight += pow(0.5, i)
	var discount = _context.get("price_effects", {}).get("reroll_price", 0.0) + bonuses.get("reroll_price", 0.0)
	var factor = max(0.1, 1.0 + discount / 100.0)
	var future_weight = use_weight * pow(0.5, profile.owned)
	for i in range(1, profile.fees.size()):
		value.later += ceil(profile.fees[i] * factor) * future_weight
	var has_slot = _context.get("fresh_slots", 1) > 0
	var clears_page = _context.has("reroll_price") and not _context.offers.empty()
	for offer in _context.offers:
		if offer.index in state.get("used", []):
			has_slot = has_slot or offer.get("locked", false)
		else:
			clears_page = false
	var available = profile.available + int(profile.empty_bonus or clears_page)
	if has_slot and state.money > (_health_floor() if _context.hp_shop else 0.0):
		value.now = ceil(profile.fees[0] * factor) * use_weight * pow(0.5, available)
	return value


func _tree_loot(bonuses: Dictionary, delta: Dictionary) -> Dictionary:
	var loot = {"materials": 0.0, "food": 0.0, "crates": 0.0, "economy": 0.0}
	var profile = _context.get("tree_profile", {})
	if profile.empty():
		return loot
	var total = max(0.0, profile.base + profile.per_bonus * (profile.owned + bonuses.get("trees", 0.0)))
	var before_total = max(0.0, profile.base + profile.per_bonus * profile.owned)
	var alive_share = 0.65 if profile.preserve_value > 0 else 0.35
	var observation = _context.get("battle_observation", {})
	if observation.get("seconds", 0) >= 20 and observation.has("living_trees"):
		alive_share = clamp(observation.living_trees / max(1.0, before_total), 0.0, 1.0)
	var coverage = 1.0 - alive_share
	if bonuses.get("one_shot_trees", 0) > _context.get("secondary", {}).get("one_shot_trees", 0):
		coverage = min(1.0, coverage + 0.2)
	loot.living = total * (1.0 - coverage)
	loot.felled = total * coverage
	var extra = total * coverage - profile.base * 0.65
	if extra == 0.0:
		return loot
	loot.materials = extra * profile.materials
	if coverage > 0:
		var luck = _context.stats.get("luck", 0.0) + delta.get("luck", 0.0)
		var luck_factor = max(0.0, 1.0 + luck / 100.0)
		var food_rate = min(1.0, profile.food_chance * luck_factor)
		var base_food = profile.base * 0.65 * food_rate
		loot.food = extra * food_rate
		var chance = profile.crate_chance * luck_factor
		loot.crates = _expected_tree_crates(base_food + loot.food, chance) - _expected_tree_crates(base_food, chance)
	loot.economy = (loot.materials + loot.crates * profile.crate_value) * max(0, _context.final_wave - _context.wave - 1)
	return loot


func _expected_tree_crates(drops: float, chance: float) -> float:
	var boxes = 0.0
	# 原生以本波已生成箱数压低后续几率，此处用已生成箱数的期望近似。
	for _i in range(int(drops)):
		boxes += min(1.0, chance / (1.0 + boxes))
	return boxes + (drops - int(drops)) * min(1.0, chance / (1.0 + boxes))


func _activity(state: Dictionary, effects: Dictionary, delta: Dictionary, coverage: float, tree_loot: Dictionary) -> Dictionary:
	var reference = _context.get("secondary", {})
	var duration = max(1.0, _context.get("wave_duration", 60.0))
	var income = _base_activity_income()
	var pickup_ratio = _collection_factor(effects) / _collection_factor(reference)
	# 材料粒数与击杀数是活动量近似，不把收获、翻倍或经验直接当作击杀次数。
	var pickups = income / (2.0 * _drop_factor(reference)) * pickup_ratio
	var kills = pickups * clamp(coverage, 0.0, 1.0)
	var observed = _context.get("battle_observation", {})
	if observed.get("seconds", 0) >= 20:
		pickups = observed.get("events", {}).get("pickups", pickups) * duration / observed.seconds * pickup_ratio
		kills = observed.get("events", {}).get("kills", kills) * duration / observed.seconds * clamp(coverage, 0.0, 1.0)
	var crit_weight = 0.0
	var crit_gold = 0.0
	var weapon_weight = 0.0
	for weapon in state.weapons:
		var critical = weapon.clear * clamp(weapon.get("crit_chance", 0.0) + delta.get("crit_chance", 0.0) / 100.0, 0.0, 1.0)
		crit_weight += critical
		crit_gold += critical * weapon.get("crit_gold_chance", 0.0)
		weapon_weight += weapon.clear
	var crit_kills = kills * crit_weight / max(1.0, weapon_weight)
	var crates = max(0.0, 0.35 + tree_loot.crates) * pickup_ratio
	var future_shops = max(0, _context.final_wave - _context.wave - 1)
	var money = income * (_drop_factor(effects) / _drop_factor(reference) * pickup_ratio - 1.0)
	money += kills * (crit_gold / max(1.0, weapon_weight) - _base_crit_gold)
	money += crates * (effects.get("item_box_gold", 0.0) - reference.get("item_box_gold", 0.0) + (effects.get("extra_item_in_crate", 0.0) - reference.get("extra_item_in_crate", 0.0)) * 0.10)
	money += crit_kills * (effects.get("gold_on_crit_kill", 0.0) - reference.get("gold_on_crit_kill", 0.0)) / 100.0
	var repeatable_income = max(0.0, income + money)
	var activity_effects = _context.get("activity_effects", {})
	var living = 0.0
	var settlement = 0.0
	if activity_effects.get("pacifist", 0) > 0 or activity_effects.get("materials_per_living_enemy", 0) != 0:
		var spawns = _context.get("combat_profile", {}).get("spawns", max(20.0, pickups * 2.0))
		kills = min(spawns, spawns * clamp(coverage, 0.0, 1.0))
		living = max(0.0, spawns - kills)
		# 留敌奖励和击杀掉落互相替代，不能只奖留敌而保留全部击杀收入。
		var base_coverage = _context.get("activity_coverage", clamp(_context.get("battle_observation", {}).get("effective_dps", 0.0) / max(1.0, _context.get("combat_profile", {}).get("clear", 1)), 0.05, 1.0))
		repeatable_income = income * clamp(coverage / max(0.05, base_coverage), 0.0, 2.0) + money
		money = repeatable_income - income
	settlement = Activity.settlement(activity_effects, living, tree_loot.get("living", 0), _context.get("threat", "") == "horde")
	money += settlement
	var tick_rules = _context.get("gold_ticks", [])
	if not tick_rules.empty():
		var wallet = state.get("gold", _context.get("gold", state.money)) if _context.hp_shop else state.money
		wallet += int(wallet * _context.get("gold_start_pct", 0.0) / 100.0)
		money += Activity.gold_ticks(wallet, _behavior.segments, tick_rules, repeatable_income).income
	var recycle_factor = clamp(0.25 + effects.get("recycling_gains", 0.0) / 100.0, 0.01, 1.0)
	var base_recycle_factor = clamp(0.25 + reference.get("recycling_gains", 0.0) / 100.0, 0.01, 1.0)
	money += (recycle_factor - base_recycle_factor) * income * (0.06 + 0.06 * float(state.weapons.size()) / max(1, state.get("slots", _context.rules.slots)))
	var recovery = pickups * clamp(effects.get("heal_when_pickup_gold", 0.0) / 100.0, 0.0, 1.0)
	recovery += kills * clamp(effects.get("heal_on_kill", 0.0) / 100.0, 0.0, 1.0)
	recovery += crit_kills * clamp(effects.get("heal_on_crit_kill", 0.0) / 100.0, 0.0, 1.0)
	if _context.get("no_heal", false) or _context.get("survival_effects", {}).get("torture", 0) > 0:
		recovery = 0.0
	var fruit = kills * clamp(effects.get("enemy_fruit_drops", 0.0) / 100.0, 0.0, 1.0) * 0.65
	return {"pickup_ratio": pickup_ratio, "income": repeatable_income, "living": living, "settlement": settlement, "pickups": pickups, "kills": kills, "kill_coverage": coverage, "economy": money * future_shops, "recovery": recovery * 0.55 / duration, "fruit_rate": fruit / duration, "pickup_radius": max(30.0, 150.0 * (1.0 + effects.get("pickup_range", 0.0) / 100.0))}


func _base_activity_income() -> float:
	var ledger = _context.get("income_ledger", {})
	if not ledger.empty():
		return max(0.0, ledger.get("pickup", 0.0) + ledger.get("mixed", 0.0) * 0.5)
	return max(0.0, _context.get("last_activity_income", _income_reference() - max(0.0, _context.stats.get("harvesting", 0.0))))


func _wave_wallet_state(state: Dictionary, seconds: float) -> Dictionary:
	var rules = _context.get("gold_ticks", [])
	if rules.empty():
		return state
	var next = state.duplicate()
	var wallet = state.gold if _context.hp_shop else state.money
	var pct = _context.get("gold_start_pct", 0.0)
	for item in state.get("items", []):
		pct += item.get("bonuses", {}).get("gain_pct_gold_start_wave", 0.0)
	wallet += int(wallet * pct / 100.0)
	var income = _base_activity_income() * seconds / max(1.0, _context.get("wave_duration", 60.0))
	var gold = Activity.gold_ticks(wallet, Activity.first_seconds(_behavior.segments, seconds), rules, income).average_wallet
	if _context.hp_shop:
		next.gold = gold
	else:
		next.money = gold
	return next


func _collection_factor(effects: Dictionary) -> float:
	var radius = max(0.2, 1.0 + effects.get("pickup_range", 0.0) / 100.0)
	return 1.0 + 0.12 * (radius - 1.0) / max(1.0, radius) + 0.08 * clamp(effects.get("instant_gold_attracting", 0.0) / 100.0, 0.0, 1.0) + effects.get("pet_pickup", 0.0)


func _drop_factor(effects: Dictionary) -> float:
	var yield_factor = max(0.5, 1.0 + (effects.get("gold_drops", 0.0) + effects.get("enemy_gold_drops", 0.0)) / 100.0)
	return yield_factor * (1.0 + clamp(effects.get("chance_double_gold", 0.0) / 100.0, 0.0, 1.0)) * (1.0 + effects.get("pet_double", 0.0))


func _future_income(harvest: float, growth: float) -> float:
	var income = 0.0
	for _wave in range(max(0, _context.final_wave - _context.wave - 1)):
		income += int(harvest)
		if harvest > 0.0:
			harvest += ceil(harvest * growth / 100.0) * _context.gains.get("harvesting", 1.0)
	return income


func _affinity(weapon: Dictionary, route: String) -> float:
	if route == "pacifist":
		return min(3.0, max(0.0, weapon.knockback) / 3.0)
	if route == "mixed":
		return 0.5
	var stat = _routes[route][1]
	var fit = min(1.6, weapon.scaling.get(stat, 0.0))
	if route == "engineering" and weapon.get("structure", 0.0) > 0:
		fit += 1.5
	if route == "elemental" and weapon.get("burn", 0.0) > 0:
		fit += 1.0
	return fit


func _permanent_stat_delta(state: Dictionary) -> Dictionary:
	var totals = _inventory_stats(state.weapons)
	var baseline = _base_inventory if _cache_scores else _inventory_stats(_context.weapons)
	for stat in baseline:
		totals[stat] = totals.get(stat, 0.0) - baseline[stat]
	_add_stats(totals, state.get("bonus_stats", {}))
	for rule in _context.get("weapon_count_stats", []):
		totals[rule.stat] = totals.get(rule.stat, 0.0) + rule.value * (_count_tier(state.weapons, rule.tier) - _count_tier(_context.weapons, rule.tier))
	var before_families = _base_families if _cache_scores else _weapon_family_count(_context.weapons)
	var after_families = _weapon_family_count(state.weapons)
	for stat in _context.get("unique_weapon_stats", {}):
		totals[stat] = totals.get(stat, 0.0) + _context.unique_weapon_stats[stat] * (after_families - before_families)
	for item in state.get("items", []):
		for rule in item.get("weapon_count_stats", []):
			totals[rule.stat] = totals.get(rule.stat, 0.0) + rule.value * _count_tier(state.weapons, rule.tier)
		for stat in item.get("stat_factors", {}):
			var gain = _context.gains.get(stat, 1.0)
			if gain != 0.0:
				var current = _context.get("permanent_stats", _context.stats).get(stat, 0.0) / gain + totals.get(stat, 0.0)
				totals[stat] = totals.get(stat, 0.0) + current * (item.stat_factors[stat] - 1.0)
		_add_stats(totals, item.stats)
		for stat in item.get("unique_weapon_stats", {}):
			totals[stat] = totals.get(stat, 0.0) + item.unique_weapon_stats[stat] * after_families
	for stat in totals:
		totals[stat] *= _context.gains.get(stat, 1.0)
	return totals


func _count_tier(weapons: Array, tier: int) -> int:
	var count = 0
	for weapon in weapons:
		if tier < 0 or (weapon.tier <= 0 if tier == 0 else weapon.tier >= tier):
			count += 1
	return count


func _stat_delta(state: Dictionary, apply_cap: bool = true, permanent = null) -> Dictionary:
	var totals = _permanent_stat_delta(state) if permanent == null else permanent.duplicate()
	var source_delta = totals.duplicate()
	# 读取角色/道具实际的属性联动，包括材料、空槽和其他属性。
	var links = []
	for link in _context.get("links", []):
		links.append({"data": link, "new": false})
	for item in state.get("items", []):
		for link in item.get("links", []):
			links.append({"data": link, "new": true})
	var sources = {}
	for entry in links:
		var link = entry.data
		if link.per == 0 or link.source == "percent_player_missing_health":
			continue
		var before = _context.get("permanent_stats", _context.stats).get(link.source, 0.0) if link.get("permanent", false) else _context.get("unlinked_stats", _context.stats).get(link.source, 0.0)
		# 原生联动仅读取常驻/临时属性，不读取其他联动生成的属性。
		var after = before + source_delta.get(link.source, 0.0)
		if link.source == "materials":
			before = _context.get("gold", _context.money)
			after = state.get("gold", before) if _context.hp_shop else state.money
		elif link.source == "free_weapon_slots":
			before = _context.rules.slots - _context.weapons.size()
			after = state.get("slots", _context.rules.slots) - state.weapons.size()
		elif link.source in ACTIVITY_LINKS or _context.get("link_sources", {}).has(link.source):
			# 近远程等普通属性联动不需要重新投影整份物品、建筑和活敌计数。
			if sources.empty():
				sources = _projected_link_sources(state, _weapon_family_count(_context.weapons), _weapon_family_count(state.weapons))
			if sources.has(link.source):
				before = _context.get("link_sources", {}).get(link.source, 0.0)
				after = sources[link.source]
		# 原生先相乘再向零截断；新拿到的联动需计算全量，而非只算变化。
		var change = int(after * link.value / link.per) - (0 if entry.new else int(before * link.value / link.per))
		totals[link.target] = totals.get(link.target, 0.0) + change * _context.gains.get(link.target, 1.0)
	var hp_cap = state.get("caps", {}).get("hp_cap", _context.get("hp_cap", 999999))
	if apply_cap and (_context.has("hp_cap") or state.get("caps", {}).has("hp_cap")):
		totals.max_hp = max(1, min(_context.get("raw_max_hp", _context.stats.max_hp) + totals.get("max_hp", 0.0), hp_cap)) - _context.stats.max_hp
	return totals


func _cap_cost(caps: Dictionary, delta: Dictionary, earning_waves: float) -> float:
	var cost = 0.0
	for cap in caps:
		var stat = "max_hp" if cap == "hp_cap" else "speed"
		var current = _context.stats.get(stat, 0.0) + delta.get(stat, 0.0)
		var growth = _context.get("growth", {}).get(stat, 0.0) * earning_waves * max(0, _context.gains.get(stat, 1.0))
		var future = current + growth
		var lost = max(0.0, min(future, _context.get(cap, 999999)) - min(future, caps[cap]))
		cost += lost / max(1.0, current) * 0.65 if stat == "max_hp" else lost / max(10.0, 100.0 + current) * 0.25
	return cost


func _conditional_stats(state: Dictionary, event_rates: Dictionary = {}, portion: float = 1.0, movement: int = -1) -> Dictionary:
	var conditions = _context.get("conditional", []).duplicate()
	for item in state.get("items", []):
		conditions.append_array(item.get("conditional", []))
	var stats = {}
	for condition in conditions:
		var coverage = Events.stacks(condition, event_rates, portion)
		if condition.when in ["temp_stats_while_not_moving", "temp_stats_while_moving"]:
			coverage = _behavior.get("still", 0.15) if movement < 0 else float(movement == 0)
			if condition.when == "temp_stats_while_moving":
				coverage = 1.0 - coverage
		elif condition.when == "stats_below_half_health":
			coverage = _context.get("battle_observation", {}).get("below_half_share", 0.25)
			if portion < 1.0:
				coverage = float(_context.get("secondary", {}).get("hp_start_next_wave", _context.get("survival_effects", {}).get("hp_start_wave", 100)) < 50)
		stats[condition.stat] = stats.get(condition.stat, 0.0) + condition.value * coverage * _context.gains.get(condition.stat, 1.0)
	var profiles = _context.get("full_health_growth", []).duplicate()
	for item in state.get("items", []):
		profiles.append_array(item.get("full_health_growth", []))
	var growth = Activity.full_health_growth(profiles, event_rates.get("full_health_food", 0.0))
	for stat in growth:
		if stat != "explosion_damage":
			stats[stat] = stats.get(stat, 0.0) + growth[stat] * clamp(portion, 0.0, 1.0) * 0.5 * _context.gains.get(stat, 1.0)
	var links = _context.get("links", []).duplicate()
	var owned = links.size()
	for item in state.get("items", []):
		links.append_array(item.get("links", []))
	var missing = _context.get("battle_observation", {}).get("missing_health", 25.0)
	if portion < 1.0:
		missing = 100.0 - _context.get("secondary", {}).get("hp_start_next_wave", _context.get("survival_effects", {}).get("hp_start_wave", 100))
	for i in range(links.size()):
		var link = links[i]
		if link.source != "percent_player_missing_health" or link.per == 0:
			continue
		var previous = int(_context.get("missing_health", 0) * link.value / link.per) if i < owned else 0
		stats[link.target] = stats.get(link.target, 0.0) + (int(round(missing) * link.value / link.per) - previous) * _context.gains.get(link.target, 1.0)
	# 已持有的缺血联动在原生 links 中，只补这次换装的差额。
	var change = _missing_steal(state.weapons, missing) - _missing_steal(_context.weapons, missing)
	if change != 0:
		stats.lifesteal = stats.get("lifesteal", 0.0) + change * _context.gains.get("lifesteal", 1.0)
	return stats


func _missing_steal(weapons: Array, missing: float) -> int:
	var amount = 0
	for weapon in weapons:
		if weapon.has("missing_health_steal"):
			var link = weapon.missing_health_steal
			amount += int(round(missing) * link.value / link.per)
	return amount


func _weapon_family_count(weapons: Array) -> int:
	var families = {}
	for weapon in weapons:
		families[weapon.family] = true
	return families.size()


func _projected_link_sources(state: Dictionary, before_families: int, after_families: int) -> Dictionary:
	var sources = _context.get("link_sources", {}).duplicate()
	var counted = _context.get("item_counts", {}).duplicate()
	for rule in ["copy_purchase", "refresh_tier"]:
		var effect = _context.get(rule, {})
		var id = effect.get("id", "")
		var removed = state.get("consumed", {}).get(id, 0)
		if removed == 0:
			continue
		var remaining = counted.get(id, 0) - removed
		sources.duplicate_item -= removed if remaining > 0 else removed - 1
		if remaining > 0:
			counted[id] = remaining
		else:
			counted.erase(id)
			sources.different_item -= 1
			if effect.tier == 0:
				sources.common_item -= 1
			elif effect.tier == 3:
				sources.legendary_item -= 1
	var previous_duplicates = _context.weapons.size() - before_families
	sources.duplicate_item = sources.get("duplicate_item", 0) + state.weapons.size() - after_families - previous_duplicates
	var tree = _context.get("tree_profile", {})
	var trees = tree.get("owned", 0.0)
	var enemies = _context.get("enemy_count", 0.0)
	for item in state.get("items", []):
		var bonuses = item.get("bonuses", {})
		for source in ["fossil_count", "knockback"]:
			sources[source] = sources.get(source, 0.0) + bonuses.get(source, 0.0)
		sources.structure = sources.get("structure", 0.0) + bonuses.get("structure_count", 0.0)
		sources.pet = sources.get("pet", 0.0) + bonuses.get("pet_count", 0.0)
		trees += bonuses.get("trees", 0.0)
		enemies += bonuses.get("number_of_enemies", 0.0)
		if item.id in counted:
			sources.duplicate_item += 1
		elif not item.id.begins_with("character_") and item.id != "item_tumor":
			sources.different_item = sources.get("different_item", 0) + 1
			if item.get("tier", -1) == 0:
				sources.common_item = sources.get("common_item", 0) + 1
			elif item.get("tier", -1) == 3:
				sources.legendary_item = sources.get("legendary_item", 0) + 1
		counted[item.id] = true
		if item.id == "item_bait":
			sources.item_bait = sources.get("item_bait", 0) + 1
	sources.living_enemy = max(1.0, (5.0 + _context.wave * 0.6) * (1.0 + enemies / 100.0))
	var burning = 0.0
	for weapon in state.weapons:
		burning += weapon.get("burn_coverage", 0.0)
	sources.burning_enemy = min(sources.living_enemy, burning * 0.35)
	sources.living_tree = max(0.0, tree.get("base", 0.0) + tree.get("per_bonus", 0.0) * trees) * 0.5
	return sources


func _inventory_stats(weapons: Array) -> Dictionary:
	var result = {}
	var counts = {}
	for weapon in weapons:
		_add_stats(result, weapon.get("stats", {}))
		for set_id in weapon.sets:
			counts[set_id] = counts.get(set_id, 0) + 1
	for set_id in counts:
		var count = weapons.size() if _context.get("all_sets", false) else counts[set_id]
		count += _context.get("set_bonus", 0)
		var bonuses = _context.get("set_bonuses", {}).get(set_id, [])
		if count >= 2 and not bonuses.empty():
			_add_stats(result, bonuses[min(count - 2, bonuses.size() - 1)])
	return result


func _add_stats(target: Dictionary, values: Dictionary) -> void:
	for stat in values:
		target[stat] = target.get(stat, 0.0) + values[stat]


func _survival(delta: Dictionary, control: float, healing: float, bonuses: Dictionary, regen_conditions: Array, tree_food: float, secondary: Dictionary, activity: Dictionary, conditional: Dictionary, support_structures: Array, next_wave: bool) -> Dictionary:
	var hp = max(1.0, min(secondary.get("hp_cap", _context.get("hp_cap", 999999)), _context.stats.max_hp + delta.get("max_hp", 0.0)))
	var armor = int(_context.stats.armor + delta.get("armor", 0.0))
	var dodge = clamp(_context.stats.dodge + delta.get("dodge", 0.0), 0, secondary.get("dodge_cap", _context.get("dodge_cap", 60)))
	var damage_taken = _armor_factor(armor)
	var mitigation = damage_taken * max(0.1, 1.0 - dodge / 100.0)
	var target = (15.0 + _context.wave * 4.5) * (1.0 + _context.difficulty * 0.08)
	if _context.get("threat", "normal") in ["elite", "horde"]:
		target *= 1.15
	var speed = min(secondary.get("speed_cap", _context.get("speed_cap", 999999)), _context.stats.speed + delta.get("speed", 0.0))
	var effects = _context.get("survival_effects", {}).duplicate()
	_add_stats(effects, bonuses)
	var aura = secondary.get("knockback_aura", 0.0)
	var fog = max(0.0, secondary.get("fog_visibility", 0.0))
	control += (min(1.5, 2.0 / aura) if aura > 0.0 else 0.0) + 3.0 * _context.get("fog_share", 0.0) * fog / (100.0 + fog)
	control += secondary.get("pet_control", 0.0) + min(3, secondary.get("jellyshield_count", 0)) * 0.45
	control += min(secondary.get("slow_limit", 0.0), secondary.get("slow_step", 0.0) * 2.0) * 0.09
	control += min(1.0, secondary.get("slow_time", 0.0) * 0.18)
	var enemy_speed = max(-75.0, secondary.get("enemy_speed", 0.0) + (_next_wave_bonus(bonuses, "enemy_speed") if next_wave else 0.0))
	# 移速主要影响接触和追击，弹幕等压力不按同一比例缩放。
	var movement = max(10.0, 100.0 + speed) / (1.0 + enemy_speed * 0.004)
	var reference_rate = 0.2 * (0.5 + 0.5 * 100.0 / movement) / (1.0 + 0.15 * (1.0 - exp(-max(0, control) / 4.0)))
	var profile = _context.get("combat_profile", {})
	var bots = secondary.get("wandering_bots", 0.0)
	if bots > 0.0:
		var enemy_base_speed = profile.get("average_enemy_speed", 0.0)
		reference_rate *= 1.0 - Combat.wandering_bot_slow(bots, enemy_base_speed if enemy_base_speed > 0.0 else 400.0)
	if _context.get("pacifist", false) and _context.get("threat", "") == "horde" and not _context.get("future_shop", false):
		# 和平主义者几乎无法清掉新增批次。用原生暴走增量估计本波接触负担。
		var spawns = profile.get("spawns", 0.0)
		var regular = spawns - profile.get("horde_spawns", 0.0)
		if regular > 0.0:
			reference_rate *= spawns / regular
	# 上波高频接触同时增加承伤和触发收益。低接触样本仍为下一波保留基础威胁。
	var observed = _context.get("battle_observation", {})
	var hit_rate = max(reference_rate, Events.contact_rate(observed, reference_rate))
	var late_rate = max(hit_rate, Events.contact_rate(observed, reference_rate, true))
	var duration = max(1.0, _context.get("wave_duration", 60.0))
	var food_rate = 0.12 + tree_food / duration + activity.fruit_rate
	var structure_healing = 0.0
	var structure_heal_events = 0.0
	var structure_speed = _structure_speed(delta, {}, bonuses) if not support_structures.empty() else 0.0
	for structure in support_structures:
		var rate = structure.amount * 60.0 / max(1, _scaled_cooldown_frames(structure.frames, structure_speed))
		if structure.garden:
			food_rate += rate * 0.65
		else:
			structure_healing += rate * 0.4
			structure_heal_events += rate * 0.4 / max(1.0, structure.get("heal_amount", 1.0))
	var start_hp = clamp(effects.get("hp_start_wave", 100), 0, 100) / 100.0
	var next_start_pct = secondary.get("hp_start_next_wave", 100.0)
	var full_health_share = _context.get("battle_observation", {}).get("full_health_share", 0.20) * (clamp(next_start_pct, 0.0, 100.0) / 100.0 if next_wave and next_start_pct != 100.0 else start_hp)
	var full_health_food = max(0.0, food_rate) * duration * full_health_share
	var regen_gain = _context.gains.get("hp_regeneration", 1.0)
	var fruit_regen = effects.get("full_health_regen", 0.0) * full_health_food * 0.5 * regen_gain
	if _context.get("no_heal", false) or effects.get("torture", 0.0) > 0.0:
		fruit_regen = 0.0
	var regen = max(0.0, _context.stats.hp_regeneration + delta.get("hp_regeneration", 0.0) + effects.get("regen_ramp", 0.0) * regen_gain + fruit_regen)
	# 原生再生间隔为 5 / (1 + (再生 - 1) / 2.25) 秒；吸血有触发频率上限。
	var recovery = (1.0 + (regen - 1.0) / 2.25) / 5.0 if regen > 0 else 0.0
	var heal_events = recovery
	# 低血量时按原生倍率强化再生；低血量覆盖时间未知，按阈值的一半估计。
	var regen_bonus = 0.0
	for condition in regen_conditions:
		regen_bonus += condition.multiplier * clamp(condition.below / 100.0, 0.0, 1.0) * 0.5
	var pet_boost = 1.0 + secondary.get("pet_heal_boost", 0.0)
	recovery *= max(0.0, 1.0 + regen_bonus) * pet_boost
	recovery += max(0.0, healing * pet_boost) * 0.55
	var fruit_timing = min(1.0, 4.0 / max(1.0, secondary.get("consumable_heal_over_time", 0.0)))
	recovery += max(0.0, food_rate) * (1.0 - full_health_share) * max(0, 3.0 + effects.get("consumable_heal", 0.0)) * fruit_timing + activity.recovery + structure_healing
	recovery += dodge / 100.0 * hit_rate * effects.get("heal_on_dodge", 0.0)
	heal_events += max(0.0, healing) * 0.55 / max(1.0, _context.get("lifesteal_amount", 1.0)) + activity.recovery + structure_heal_events
	heal_events += max(0.0, food_rate) * (1.0 - full_health_share) * (max(0.0, 3.0 + effects.get("consumable_heal", 0.0)) * fruit_timing if secondary.get("consumable_heal_over_time", 0) > 0 else 1.0)
	heal_events += dodge / 100.0 * hit_rate * min(1.0, effects.get("heal_on_dodge", 0.0))
	if effects.get("torture", 0) > 0:
		recovery = effects.torture
		heal_events = 1.0
	if _context.get("no_heal", false):
		recovery = 0.0
		heal_events = 0.0
	var gross_recovery = max(0.0, recovery)
	recovery -= max(0, effects.get("lose_hp_per_second", 0.0))
	var opening_max = max(1.0, hp - max(0.0, conditional.get("max_hp", 0.0)))
	var next_start = max(1, int(int(opening_max) * next_start_pct / 100.0)) if next_wave and next_start_pct != 100.0 else max(1, int(int(opening_max) * start_hp))
	var protection = max(0, int(effects.get("hit_protection", 0)))
	var permanent_damage = _context.stats.get("enemy_damage", 0.0) + delta.get("enemy_damage", 0.0) + bonuses.get("enemy_damage", 0.0) * _context.gains.get("enemy_damage", 1.0)
	var steady_factor = max(0.01, 1.0 + permanent_damage / 100.0)
	var damage_factor = max(0.01, 1.0 + (permanent_damage + (_next_wave_bonus(bonuses, "enemy_damage") if next_wave else 0.0)) / 100.0)
	# 有效生命只表示生命和减伤；治疗不再折成固定秒数的额外生命。
	var durability = hp / mitigation / steady_factor
	var next_durability = next_start / mitigation / damage_factor
	# 重击使用原生伤害取整；购买策略另行比较开波余量。
	var burst = _context.get("burst", {})
	var raw_hit = burst.get("damage", 0)
	if burst.has("base_damage"):
		raw_hit = max(1, int(round(burst.base_damage * (damage_factor if burst.next else steady_factor))))
	var previous_health_armor = 0.0
	for link in _context.get("links", []):
		if link.source == "percent_player_missing_health" and link.target == "armor" and link.per != 0:
			previous_health_armor += int(_context.get("missing_health", 0) * link.value / link.per) * _context.gains.get("armor", 1.0)
	var reliable_armor = int(_context.stats.armor + delta.get("armor", 0.0) - max(0.0, conditional.get("armor", 0.0) + previous_health_armor))
	var burst_hit = max(1, int(round(raw_hit * _armor_factor(reliable_armor)))) if raw_hit > 0 else 0
	var burst_damage = max(0, 2 - protection) * burst_hit
	var burst_margin = (next_start if burst.get("next", false) else max(1, int(int(hp) * start_hp))) - burst_damage
	# 固定波次下的参考接触压力，不是真实中弹率或死亡概率。输出的减压收益
	# 已通过递减战斗效用计入，这里不再随候选伤害重复降低受击频率。
	var reference = _context.get("pressure_reference", {})
	var mean_raw = reference.get("mean", target / 6.0)
	var peak_raw = reference.get("peak", mean_raw)
	if burst.get("next", false):
		peak_raw = max(peak_raw, burst.get("base_damage", burst.get("damage", 0.0)))
	var mean_hit = max(1.0, mean_raw * damage_factor * damage_taken)
	var short_mean = max(1.0, mean_raw * damage_factor * _armor_factor(reliable_armor))
	var peak_hit = max(1.0, peak_raw * damage_factor * _armor_factor(reliable_armor))
	var landed_rate = hit_rate * (1.0 - dodge / 100.0)
	# 免伤是整波有限次数；短时压力保守地抵消普通一击，不假设必挡最大伤害。
	var incoming = max(0.0, mean_hit * (landed_rate - protection / duration))
	# 整波补血能覆盖平均承伤时，最后一段连续受击仍会消耗开波储备。
	var late_incoming = mean_hit * late_rate * (1.0 - dodge / 100.0)
	var late_damage = max(0.0, late_incoming - recovery) * min(15.0, duration) if late_rate > hit_rate else 0.0
	var short_load = max(0.0, peak_hit + short_mean * late_rate * 1.5 - protection * min(short_mean, peak_hit))
	var short_pressure = _saturate(short_load / next_start)
	var drain_pressure = _saturate(max(late_damage, hp - next_start + (incoming - recovery) * duration) / hp)
	var injury = min(hp, max(mean_hit, hp - next_start))
	var recovered = max(0.0, recovery) / max(0.001, landed_rate)
	var recovery_pressure = _saturate(injury / hp) * injury / (injury + recovered)
	# 短时余量不足时，治疗的价值自然受限；再强的回血也不能消除连续命中压力。
	var pressure = short_pressure + (1.0 - short_pressure) * (0.6 * drain_pressure + 0.4 * recovery_pressure)
	var health_resource = next_start
	var resources = _context.get("resources", {})
	var material_health = resources.get("materials_as_health", false)
	var shield = resources.get("damage_taken_on_materials", false)
	if material_health or shield:
		var wallet = max(0.0, activity.get("wallet", 0.0))
		var resource_hp = max(1.0, wallet if material_health else next_start + wallet)
		health_resource = resource_hp
		var resource_recovery = 0.0 if material_health else recovery
		short_pressure = _saturate(short_load / resource_hp)
		drain_pressure = _saturate(max(0.0, (incoming - resource_recovery) * duration) / resource_hp)
		recovery_pressure = 0.0 if material_health else recovery_pressure * hp / resource_hp
		pressure = short_pressure + (1.0 - short_pressure) * (0.6 * drain_pressure + 0.4 * recovery_pressure)
		durability = resource_hp / mitigation / steady_factor
		next_durability = resource_hp / mitigation / damage_factor
		if material_health:
			recovery = 0.0
			full_health_food = 0.0
			if wallet <= 0:
				pressure = 1.0
	if resources.get("die_in_one_hit", false):
		# 任意正伤害致死；只评估接触、闪避与有限免伤，HP/护甲/治疗不延长受击寿命。
		var hits = max(0.0, landed_rate * duration - protection)
		pressure = _saturate(hits)
		short_pressure = _saturate(max(0.0, landed_rate * 2.5 - protection))
		drain_pressure = pressure
		recovery_pressure = 0.0
		recovery = 0.0
		durability = (protection + 1.0) / max(0.001, landed_rate)
		next_durability = durability
	return {"health_resource": health_resource, "hit_rate": reference_rate, "mean_hit": mean_hit, "dodge": dodge, "protection": protection, "food_rate": food_rate, "heal_rate": heal_events, "gross_recovery": gross_recovery, "max_hp": hp, "armor": armor, "durability": durability, "next_durability": next_durability, "enemy_damage": damage_factor, "opening_hp": next_start, "movement": movement, "burst_hit": burst_hit, "burst_margin": burst_margin, "full_health_food": full_health_food, "fruit_regen": fruit_regen, "pressure": pressure, "short_pressure": short_pressure, "drain_pressure": drain_pressure, "recovery_pressure": recovery_pressure, "incoming": incoming, "recovery": recovery}


func _armor_factor(armor: int) -> float:
	var factor = 1.0 / (1.0 + abs(armor) / 15.0)
	return 2.0 - factor if armor < 0 else factor


func _explain(result: Dictionary) -> Array:
	var reasons = []
	var stat = _routes[result.route][1]
	if stat != "":
		reasons.append("根据现有武器、属性和职业收益选择路线；成长倍率 %.2f" % _context.gains.get(stat, 1.0))
	reasons.append("第 %d/%d 波，难度 %d，下波：%s" % [_context.wave, _context.final_wave, _context.difficulty, {"normal": "普通", "elite": "精英", "horde": "暴走"}.get(_context.get("threat", "normal"), "普通")])
	reasons.append(result.priority_note)
	reasons.append(explain_gain(result.before, result.score, result.gain) + "；购买门槛 %.2f 分" % result.state.get("hurdle", 0.0))
	var defense = result.before.defense
	reasons.append("压力依据：短时 %.1f，整波失血 %.1f，恢复 %.1f；参考承伤 %.2f/秒（参考压力并非死亡概率）" % [defense.short_pressure * 100.0, defense.drain_pressure * 100.0, defense.recovery_pressure * 100.0, defense.incoming])
	var burst_reason = explain_burst(result.before)
	if burst_reason != "":
		reasons.append(burst_reason)
	var pending = _context.get("next_wave_effects", {})
	if not pending.empty():
		reasons.append("下波待生效词条：经验 %+.0f%%，敌伤 %+.0f%%，敌生命 %+.0f%%" % [pending.get("xp_gain", 0.0), pending.get("enemy_damage", 0.0), pending.get("enemy_health", 0.0)])
	if result.before.enemy_load != result.score.enemy_load:
		reasons.append("普通敌人生成压力 %s；掉落变化已计入经济估计" % _percent_change(result.before.enemy_load, result.score.enemy_load))
	reasons.append("生存现状：生命 %.0f，护甲 %.0f，闪避 %.0f%%，再生 %.0f；已计入恢复、减益和职业上限" % [_context.stats.max_hp, _context.stats.armor, _context.stats.dodge, _context.stats.hp_regeneration])
	reasons.append("输出属性：伤害 %.0f%%，近战 %.0f，远程 %.0f，元素 %.0f，工程 %.0f，攻速 %.0f%%，暴击 %.0f%%，速度 %.0f%%" % [_context.stats.percent_damage, _context.stats.get("melee_damage", 0), _context.stats.get("ranged_damage", 0), _context.stats.get("elemental_damage", 0), _context.stats.get("engineering", 0), _context.stats.attack_speed, _context.stats.get("crit_chance", 0), _context.stats.speed])
	if result.before.has("half_wave_output"):
		var phase = result.before.half_wave_output
		var converted = []
		for converted_stat in result.before.conversion:
			converted.append("%s %+.1f" % [_context.stat_labels.get(converted_stat, converted_stat), result.before.conversion[converted_stat]])
		reasons.append("半波转换%s；前/后半清场 %.0f / %.0f，单体 %.0f / %.0f" % [
			" " + PoolStringArray(converted).join("，") if not converted.empty() else "按后续属性投入预测", phase[0], phase[1], phase[2], phase[3]])
	if _context.hp_shop:
		reasons.append("生命商店保留 %.0f 生命底线" % _health_floor())
	elif _context.final_wave - _context.wave <= 4:
		reasons.append("冲刺阶段：降低购买与刷新门槛")
	if result.before.interest != result.before.interest_value or result.score.interest != result.score.interest_value:
		reasons.append("波初利息 %.0f → %.0f，按剩余商店支出纳入评分 %.0f → %.0f" % [result.before.interest, result.score.interest, result.before.interest_value, result.score.interest_value])
	elif result.before.interest != 0 or result.score.interest != 0:
		reasons.append("已计入波开始材料结算 %.0f → %.0f" % [result.before.interest, result.score.interest])
	if result.score.discount.invested > 0:
		reasons.append("商店经济投入 %.0f，预计省 %.0f 材料，净回报 %+.0f；按剩余 %d 次商店、预计支出 %.0f 估计" % [result.score.discount.invested, result.score.discount.saved, result.score.discount.net, result.score.discount.horizon, result.score.discount.future_spend])
	if _context.get("minimum_cooldown", 0) > 0:
		reasons.append("当前武器冷却下限 %.2f 秒；高速武器和攻速投资会受限制" % (_context.minimum_cooldown / 60.0))
	if _context.get("speed_cap", 999999) < 999999:
		reasons.append("当前速度上限 %.0f%%；超过上限的加速不产生移动收益" % _context.speed_cap)
	if _context.get("hp_cap", 999999) < 999999:
		reasons.append("当前生命上限封顶 %.0f；超过封顶的加血不产生容错收益" % _context.hp_cap)
	if not _context.get("damage_ramps", []).empty() or result.score.average_damage_ramp != 0:
		reasons.append("本波预计 %.0f 秒，定时伤害属性波内平均 +%.1f 个百分点；前 15 秒清场估计 %.0f，波内平均 %.0f，分别评估开局风险和后程收益" % [_context.get("wave_duration", 60), result.score.average_damage_ramp, result.score.opening_clear, result.score.current_clear])
	var families = {}
	for weapon in result.state.weapons:
		families[weapon.family] = {"name": weapon.name, "count": families.get(weapon.family, {}).get("count", 0) + 1, "fit": _affinity(weapon, result.route)}
	var focus = ""
	var weight = -1.0
	for family in families.values():
		var fit_weight = family.count * (1.0 + family.fit)
		if fit_weight > weight:
			focus = family.name
			weight = fit_weight
	reasons.append("当前主武器：%s；计划持有 %d/%d 把，同名数量不是必须保留的目标" % [focus if focus != "" else result.goal, result.state.weapons.size(), result.score.slots])
	if result.route == "engineering":
		var mines = []
		for weapon in result.state.weapons:
			if weapon.get("mine_interval", 0) > 0:
				mines.append("%s 每 %d 秒一颗，单次 %.0f" % [weapon.name, weapon.mine_interval, weapon.mine_damage])
		if not mines.empty():
			reasons.append("地雷生成：" + PoolStringArray(mines).join("；"))
		reasons.append("工程投入同时改善工具近战与建筑；比较各品质的地雷生成频率，并搭配炮塔、生命和恢复，不固定保留六把低级武器")
	reasons.append("输出参考：清场 %.0f / %.0f，单体 %.0f / %.0f；后续成长方向：%s" % [result.before.current_clear, result.before.clear_target, result.before.current_boss, result.before.boss_target, _context.get("stat_labels", {}).get(stat, "当前路线属性") if stat != "" else "控制和续航"])
	if "primal_dread" in _context.get("dlcs", []):
		reasons.append("进化 %.0f，机械零件 %d，宠物 %d；机械二选一和变异后的现有效果已纳入" % [_context.stats.get("evolution", 0), _context.get("meca_parts", 0), _context.get("pets", 0)])
	if not result.score.get("events", {}).empty():
		var events = result.score.events
		reasons.append("事件估计：受击 %.1f、自伤 %.1f、有效治疗 %.1f、拾取 %.1f 次；触发清场贡献 %.1f/秒。次数与覆盖受活动和缺血假设影响，开局叠层单独估计" % [events.hits, events.self_hits, events.heals, events.pickups, result.score.event_output.clear])
	if result.score.has("movement_output") or not _context.get("gold_ticks", []).empty():
		reasons.append("用于战斗估值的站定比例 %.0f%%（%s）。移动与站定分别估计，短时承压保留不利状态" % [_behavior.combat_still * 100.0, "本局观测" if _behavior.observed else "样本不足，暂用行为假设"])
	if result.score.activity.get("settlement", 0.0) > 0:
		reasons.append("波末留敌、留树奖励估计 %.0f 材料，在原生转换后结算；实际存活数量仍不确定" % result.score.activity.settlement)
	if result.actions.empty():
		reasons.append("当前页没有值得购买的商品，继续比较刷新与保留资源")
	if result.get("limited", false):
		reasons.append("搜索达到节点上限，返回已找到的最佳方案")
	return reasons


func _explain_skips(result: Dictionary, work: Dictionary = {}):
	var skipped = []
	var selected = {}
	for action in result.actions:
		var purchase = action.steps.back() if action.kind == "bundle" else action
		selected[purchase.index] = purchase.choice
	for offer in _context.offers:
		var variant = offer.get("choice", -1)
		var other_choice = selected.has(offer.index) and selected[offer.index] != variant
		if selected.has(offer.index) and not other_choice:
			continue
		var quoted_state = initial_state() if other_choice else result.state
		var reason = offer.get("blocked", "")
		if reason == "" and offer.get("kind", "weapon") == "weapon" and not offer.weapon.get("unmeasured", []).empty():
			reason = "武器核心效果未覆盖，本店跳过"
		var price = offer_price(quoted_state, offer)
		var pending = _offer_evidence(offer)
		if reason == "" or pending != "":
			var probe = offer.duplicate()
			probe.blocked = ""
			var baseline = result.before if other_choice else result.score
			var candidate = best_offer(quoted_state, probe, result.route, baseline, true, work)
			if candidate is GDScriptFunctionState:
				candidate = yield(candidate, "completed")
			if work.get("cancelled", false):
				return []
			var funded = candidate.empty() and price > quoted_state.money
			if funded:
				var state = _copy(quoted_state)
				state.money = price + (_health_floor() if _context.hp_shop else 0.0)
				baseline = evaluate(state, result.route)
				candidate = best_offer(state, probe, result.route, baseline, true, work)
				if candidate is GDScriptFunctionState:
					candidate = yield(candidate, "completed")
				if work.get("cancelled", false):
					return []
			if not candidate.empty():
				var prefix = "同槽另一选项按进店状态估计，" if other_choice else ""
				if funded:
					prefix += "补足预算后估计，"
				if pending != "":
					prefix += "已计部分，"
				reason += ("；" if reason != "" else "") + prefix + _explain_skipped_trade(baseline, candidate)
			elif reason == "":
				reason = "职业、槽位、品质或生命底线限制，且没有可行的合成/换装方案"
		var name = offer.item.name if offer.get("kind", "weapon") == "item" else offer.weapon.name
		var suffix = "（" + offer.choice_text + "）" if offer.get("choice_text", "") != "" else ""
		skipped.append("跳过 %s%s，价格 %d：%s%s" % [name, suffix, price, reason, pending])
	return skipped


func _offer_evidence(offer: Dictionary) -> String:
	var source = offer.item if offer.get("kind", "weapon") == "item" else offer.weapon
	var pending = source.get("unmeasured", [])
	if not pending.empty():
		return "；尚未进入总分的原生参数 " + PoolStringArray(pending).join("；")
	return "；拿取后将永久限制属性成长" if not source.get("caps", {}).empty() else ""


func _explain_skipped_trade(baseline: Dictionary, candidate: Dictionary) -> String:
	var details = PoolStringArray()
	var last_action = candidate.state.actions.back()
	if candidate.get("sale_rejected", false):
		details.append("出售 %s 后本波战斗与生存合计下降 %.2f 分，不自动换装" % [last_action.steps[0].name, -candidate.gain.immediate])
	elif last_action.kind == "bundle":
		var step = last_action.steps[0]
		details.append(("可先合成 %s 再买" if step.kind == "combine" else "可先出售 %s 再买") % [step.name])
	details.append("综合收益 %+.2f 分，购买门槛 %.2f 分，净收益 %+.2f 分" % [candidate.gain.score, candidate.threshold, candidate.surplus])
	details.append(explain_gain(baseline, candidate.score, candidate.gain))
	var purchase = last_action.steps.back() if last_action.kind == "bundle" else last_action
	var refund = last_action.steps[0].get("refund", 0) if last_action.kind == "bundle" else 0
	details.append("净支出 %d；套装及装备变化后生命 %.0f → %.0f、护甲 %.1f → %.1f" % [purchase.get("price", 0) - refund, baseline.defense.max_hp, candidate.score.defense.max_hp, baseline.defense.armor, candidate.score.defense.armor])
	if candidate.score.discount.invested > baseline.discount.invested:
		details.append("商店经济新增投入 %.0f，预计多省 %.0f 材料，剩余支出估计 %.0f" % [candidate.score.discount.invested - baseline.discount.invested, candidate.score.discount.saved - baseline.discount.saved, candidate.score.discount.future_spend])
	return details.join("；")
