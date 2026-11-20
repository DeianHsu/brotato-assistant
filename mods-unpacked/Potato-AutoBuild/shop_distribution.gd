extends Reference

# 独立随机源只生成估值场景，不读取或推进游戏的随机序列。
const SAMPLE_COUNT = 256
const Budget = preload("res://mods-unpacked/Potato-AutoBuild/analysis_budget.gd")


func pages(context: Dictionary, catalogue: Array, count: int = SAMPLE_COUNT, work: Dictionary = {}):
	var rng = RandomNumberGenerator.new()
	rng.seed = 725031
	var profile = context.get("shop_distribution", {})
	var groups = {}
	for i in range(catalogue.size()):
		var row = catalogue[i]
		var key = str([row.get("kind", "weapon"), row.get("tier", 0)])
		if not groups.has(key):
			groups[key] = []
		if not row.get("fixed", false):
			groups[key].append(i)
	var result = []
	for _sample in range(count):
		var ready = Budget.checkpoint(work)
		if ready is GDScriptFunctionState:
			ready = yield(ready, "completed")
		if not ready:
			return []
		var page = []
		var excluded = {}
		for id in profile.get("locked_ids", context.get("excluded_ids", [])):
			excluded[id] = true
		var weapons = profile.get("locked_weapons", 0)
		var fixed = profile.get("fixed", []).duplicate()
		for _slot in range(context.get("fresh_slots", 4)):
			var candidates = []
			if profile.empty():
				for i in range(catalogue.size()):
					if not excluded.has(catalogue[i].get("id", i)):
						candidates.append(i)
			else:
				var kind = "item"
				if not profile.no_weapons:
					if profile.exact:
						kind = "weapon" if weapons < profile.minimum else "item"
					elif fixed.empty() and (weapons < profile.minimum or rng.randf() < profile.weapon_chance):
						kind = "weapon"
				if kind == "weapon":
					weapons += 1
				if kind == "item" and not fixed.empty():
					var id = fixed.pop_front()
					for i in range(catalogue.size()):
						if catalogue[i].get("id", "") == id:
							candidates = [i]
							break
				else:
					var tier = _tier(rng, profile.tiers)
					if kind == "weapon":
						tier = int(clamp(tier, context.rules.min_tier, context.rules.max_tier))
					for index in groups.get(str([kind, tier]), []):
						if not excluded.has(catalogue[index].id):
							candidates.append(index)
					candidates = _preferred(rng, catalogue, candidates, kind, profile)
			if candidates.empty():
				continue
			var index = _pick(rng, catalogue, candidates, profile.empty())
			page.append(index)
			excluded[catalogue[index].get("id", index)] = true
		result.append(page)
	return result


static func sampled(pages: Array) -> Dictionary:
	var result = {}
	for page in pages:
		for index in page:
			result[index] = true
	return result


func _tier(rng, probabilities: Dictionary) -> int:
	var value = rng.randf()
	var last = 0
	for tier in probabilities:
		last = tier
		value -= probabilities[tier]
		if value <= 0:
			return tier
	return last


func _preferred(rng, catalogue: Array, candidates: Array, kind: String, profile: Dictionary) -> Array:
	var value = rng.randf()
	var preferred = []
	for i in candidates:
		var row = catalogue[i]
		if kind == "weapon":
			if (value < profile.own_chance and row.owned) or (value >= profile.own_chance and value < profile.set_chance and row.same_set) or (value >= profile.set_chance and not row.owned):
				preferred.append(i)
		elif value >= profile.wanted_chance or row.wanted:
			preferred.append(i)
	return candidates if preferred.empty() else preferred


func _pick(rng, catalogue: Array, candidates: Array, weighted: bool) -> int:
	if not weighted:
		return candidates[rng.randi_range(0, candidates.size() - 1)]
	var total = 0.0
	for i in candidates:
		total += catalogue[i].weight
	var value = rng.randf() * total
	for i in candidates:
		value -= catalogue[i].weight
		if value <= 0:
			return i
	return candidates.back()
