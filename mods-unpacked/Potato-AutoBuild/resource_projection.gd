extends Reference

# 原生整数资源流水：开始结算 → 活动收入/承伤 → 波末属性与转换 → 收获 → 商店销毁。
# 未选择的升级、宝箱、未来出售都不提前到账。
static func project(context: Dictionary, state: Dictionary, permanent: Dictionary, income: float, loss: float = 0.0) -> Dictionary:
	var rules = context.get("resources", {})
	var stats = context.get("permanent_stats", context.stats).duplicate()
	for stat in permanent:
		stats[stat] = stats.get(stat, 0.0) + permanent[stat]
	stats.max_hp = stats.get("max_hp", 1.0) - state.get("hp_spent", 0.0)
	var gold = int(state.get("gold", context.get("gold", state.money)) if context.hp_shop else state.money)
	var pct = context.get("gold_start_pct", 0.0)
	var growth = context.get("wave_growth", {}).duplicate()
	for item in state.get("items", []):
		pct += item.get("bonuses", {}).get("gain_pct_gold_start_wave", 0.0)
		for stat in item.get("wave_growth", {}):
			growth[stat] = growth.get(stat, 0.0) + item.wave_growth[stat]
	if context.wave + 1 > context.final_wave:
		pct = -100.0 if pct < 0 else 0.0
	var start_change = int(gold * pct / 100.0)
	gold += start_change
	gold = max(0, gold + int(max(0.0, income)) - int(ceil(max(0.0, loss))))
	var added = {}
	for stat in state.get("activity_growth", {}):
		var amount = int(state.activity_growth[stat]) * context.gains.get(stat, 1.0)
		stats[stat] = stats.get(stat, 0.0) + amount
		added[stat] = amount
	for stat in growth:
		var amount = int(growth[stat]) * context.gains.get(stat, 1.0)
		stats[stat] = stats.get(stat, 0.0) + amount
		added[stat] = added.get(stat, 0.0) + amount
	var conversions = rules.get("conversions", []).duplicate()
	for item in state.get("items", []):
		conversions.append_array(item.get("conversions", []))
	var supported = rules.get("supported", true)
	for conversion in conversions:
		if conversion.cost <= 0:
			supported = false
			break
		var source = gold if conversion.from_stat == "materials" else int(stats.get(conversion.from_stat, 0.0))
		var chunks = max(0, floor(source * conversion.portion / conversion.cost))
		# 原生此处是 break；不能跳过零组转换继续处理下一项。
		if chunks == 0:
			break
		var removed = chunks * conversion.cost
		var gained = chunks * conversion.reward
		var from_gain = context.gains.get(conversion.from_stat, 1.0)
		var to_gain = context.gains.get(conversion.to_stat, 1.0)
		removed = int(round(removed / from_gain)) if from_gain > 0 else int(removed)
		gained = int(round(gained / to_gain)) if to_gain > 0 else int(gained)
		if conversion.from_stat == "materials":
			gold = max(0, gold - removed)
		else:
			stats[conversion.from_stat] = stats.get(conversion.from_stat, 0.0) - removed * from_gain
			added[conversion.from_stat] = added.get(conversion.from_stat, 0.0) - removed * from_gain
		if conversion.to_stat == "materials":
			gold += gained
		else:
			stats[conversion.to_stat] = stats.get(conversion.to_stat, 0.0) + gained * to_gain
			added[conversion.to_stat] = added.get(conversion.to_stat, 0.0) + gained * to_gain
	# 原生收获在转换之后。属性联动由调用方提供本候选的有效收获。
	var harvest = int(state.projected_harvesting + added.get("harvesting", 0.0)) if state.has("projected_harvesting") else int(stats.get("harvesting", 0.0))
	gold = max(0, gold + harvest + int(state.get("settlement_income", 0.0)))
	var weapons = [] if rules.get("destroy_weapons", false) else state.weapons.duplicate()
	return {"gold": gold, "money": int(stats.max_hp) if context.hp_shop else gold, "stats": stats,
		"stat_changes": added, "weapons": weapons, "start_change": start_change, "income": int(income),
		"loss": int(ceil(loss)), "harvest": harvest, "supported": supported}
