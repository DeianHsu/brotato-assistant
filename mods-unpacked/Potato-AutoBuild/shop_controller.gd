extends Node

const Planner = preload("res://mods-unpacked/Potato-AutoBuild/planner.gd")
const Adapter = preload("res://mods-unpacked/Potato-AutoBuild/game_adapter.gd")
const DecisionLog = preload("res://mods-unpacked/Potato-AutoBuild/decision_log.gd")
const ShopPolicy = preload("res://mods-unpacked/Potato-AutoBuild/shop_policy.gd")
var manager
var shop
var adapter = Adapter.new()
var planner = Planner.new()
var busy = false
var _log
var shop_policy = ShopPolicy.new()
var _roll_spent = 0
var _auto_rolls = 0
var _released_locks = {}
var _signature = ""
var _poll_time = 0.0
var _planning = false
var _auto_stopped_board = ""
var latest_plan = {}
var latest_reroll = {}
var revision = 0


func _ready() -> void:
	manager.connect("automation_changed", self, "_clear_auto_stop")
	adapter.setup(get_tree())
	_released_locks = manager.released_locks
	for slot in shop._get_shop_items_container(0)._shop_items:
		slot._lock_icon.connect("visibility_changed", self, "_on_lock_icon_changed", [slot])
	_log = DecisionLog.new()
	_log.manager = manager
	_log.context_owner = self
	add_child(_log)
	log_line(manager.shortcut_hint())
	log_line("助手版本：" + manager.version + "；游戏版本：" + get_node("/root/ProgressData").VERSION + "；按本局实际数据规划。")
	log_line("读取当前游戏数据；目标为通关构筑。评分与未来成长是估计。")


func toggle_log() -> void:
	_log.toggle()


func is_active() -> bool:
	return _available()


func _on_lock_icon_changed(slot) -> void:
	if not slot._lock_icon.visible or slot.item_data == null:
		return
	var key = _lock_key(slot.item_data, slot.wave_value)
	if not manager.auto_locks.has(key):
		return
	# 原生新加锁先亮图标再写记录。刷新后重绘旧锁时，记录已在。
	for entry in adapter.run.get_player_locked_shop_items(0):
		if _lock_key(entry[0], entry[1]) == key:
			return
	manager.auto_locks.erase(key)
	manager.save_locks()
	_signature = ""


func _lock_key(item, wave: int) -> String:
	return "%s/%d" % [item.my_id, wave]


func _is_auto_locked(slot) -> bool:
	if not slot.active or not slot.locked or not manager.auto_locks.has(_lock_key(slot.item_data, slot.wave_value)):
		return false
	# 原生按物品 ID 解锁。重复 ID 时，避免解除另一个商品的锁。
	var matches = 0
	for entry in adapter.run.get_player_locked_shop_items(0):
		if entry[0].my_id == slot.item_data.my_id:
			matches += 1
	return matches == 1


func _process(delta: float) -> void:
	_poll_time += delta
	if _poll_time < 0.2 or busy or _planning or not _available():
		return
	_poll_time = 0.0
	var board = _board_signature()
	if manager.auto_enabled and board != _auto_stopped_board:
		if _can_start_wave():
			execute(true)
	elif board != _signature:
		_refresh(false, true)


func _clear_auto_stop() -> void:
	_auto_stopped_board = ""


func _can_start_wave() -> bool:
	var button = shop._get_go_button(0)
	return button.is_visible_in_tree() and not button.disabled and not shop._player_pressed_go_button[0]


func _board_signature() -> String:
	var values = [adapter.run.current_wave, shop._reroll_count[0], shop._reroll_price[0], _auto_rolls,
		adapter.run.get_player_gold(0), adapter.run.get_player_currency(0), adapter.run.get_player_meca_parts(0), adapter.run.get_player_items(0).size()]
	for weapon in adapter.run.get_player_weapons(0):
		values.append(weapon.get_instance_id())
	var effects = adapter.run.get_player_effects(0)
	values.append(effects.get(adapter.keys.generate_hash("duplicate_item"), []))
	values.append(effects.get(adapter.keys.generate_hash("increase_tier_on_reroll"), []))
	for slot in shop._get_shop_items_container(0)._shop_items:
		values.append([slot.active, slot.value, slot.locked, slot.item_data.get_instance_id() if slot.item_data != null else 0])
	return str(values)


func _available() -> bool:
	return is_instance_valid(shop) and shop.is_inside_tree() and shop.is_visible_in_tree() and not get_tree().paused and not adapter.run.wave_in_progress and not adapter.run.is_coop_run and not shop._block_background.visible


func preview(sliced: bool = false):
	if busy or not _available():
		return {}
	_log.open()
	if _planning:
		return latest_plan if _signature == _board_signature() else {}
	return _refresh(true, sliced)


func _analysis_current(signature: String) -> bool:
	return _available() and _board_signature() == signature


func _refresh(show_log: bool, sliced: bool = false):
	var started = OS.get_ticks_usec()
	var signature = _board_signature()
	_planning = true
	if sliced and signature != _signature:
		_log.clear_page()
		log_line("正在计算当前货架…")
	var context = adapter.snapshot(shop)
	if not context.coverage.automatic:
		latest_plan = {"automatic": false, "actions": [], "locks": [], "unlocks": [], "coverage": context.coverage}
		latest_reroll = {"allowed": false, "reason": context.coverage.note}
		_signature = signature
		_planning = false
		manager.combat_prediction = {}
		_log.clear_page()
		if show_log:
			_log.open()
		log_line("当前角色：" + context.character)
		log_line(context.coverage.note)
		log_line("请手动购买、换装、刷新和锁定；助手保留现有货架与锁定。")
		return latest_plan
	manager.prepare_locks(adapter.run, shop._reroll_count[0])
	_released_locks = manager.released_locks
	var slots = shop._get_shop_items_container(0)._shop_items
	var live_keys = {}
	var locked_ids = {}
	for entry in adapter.run.get_player_locked_shop_items(0):
		live_keys[_lock_key(entry[0], entry[1])] = true
		locked_ids[entry[0].my_id] = locked_ids.get(entry[0].my_id, 0) + 1
	var visible_ids = {}
	for slot in slots:
		if slot.active and slot.item_data != null:
			visible_ids[slot.item_data.my_id] = visible_ids.get(slot.item_data.my_id, 0) + 1
	for key in manager.auto_locks.keys():
		if not live_keys.has(key) or locked_ids.get(key.rsplit("/", true, 1)[0], 0) > 1:
			manager.auto_locks.erase(key)
			manager.save_locks()
	for offer in context.offers:
		var slot = slots[offer.index]
		var key = _lock_key(slot.item_data, slot.wave_value)
		offer.auto_locked = _is_auto_locked(slot)
		if not offer.auto_locked and visible_ids.get(slot.item_data.my_id, 0) > 1:
			offer.lockable = false
		offer.auto_lock_wave = manager.auto_locks.get(key, context.wave)
		offer.released_here = _released_locks.has(key)
	context.auto_rolls = _auto_rolls
	var work = {"describe": funcref(adapter, "describe_reroll_offer"), "catalogue": funcref(self, "_future_catalogue"), "cache": true}
	# 规划期间仅在货架、余额和锁定仍与快照一致时发布结果。
	if sliced:
		work.tree = get_tree()
		work.is_current = funcref(self, "_analysis_current")
		work.signature = signature
		work.slice_started = started
	var snapped = OS.get_ticks_usec()
	var result = shop_policy.plan_shop(context, manager.previous_route, planner, work)
	if result is GDScriptFunctionState:
		result = yield(result, "completed")
	if result.empty() or not _analysis_current(signature):
		_planning = false
		return {}
	var planned = work.get("visible_done", OS.get_ticks_usec())
	var saved = OS.get_ticks_usec()
	if context.wave == 1 and not result.actions.empty():
		return _publish(context, result, {"allowed": false, "reason": "首店优先买入当前补强"}, signature, show_log, work, started, snapped, planned, saved)
	for offer in context.offers:
		for unlocked in result.refresh_unlocks:
			if offer.index == unlocked.index:
				offer.locked = false
		for target in result.refresh_locks:
			if offer.index == target.index:
				offer.locked = true
	for target in result.refresh_locks:
		if not target.locked:
			context.fresh_slots -= 1
	context.fresh_slots += result.refresh_unlocks.size()
	var reroll = shop_policy.decide(context, result, planner, [], work)
	if reroll is GDScriptFunctionState:
		reroll = yield(reroll, "completed")
	if reroll.empty() or not _analysis_current(signature):
		_planning = false
		return {}
	return _publish(context, result, reroll, signature, show_log, work, started, snapped, planned, saved)


func _publish(context, result, reroll, signature, show_log, work, started, snapped, planned, saved):
	_planning = false
	latest_plan = result
	var weapon_ids = []
	for weapon in context.weapons:
		weapon_ids.append(weapon.id)
	manager.combat_prediction = {"wave": adapter.run.get_next_wave(), "weapons": weapon_ids, "clear": result.before.weapon_clear / planner.Combat.calibration(context.get("battle_observation", {}))}
	manager.combat_prediction.food_rate = result.before.defense.food_rate
	manager.combat_prediction.hit_rate = result.before.defense.hit_rate
	latest_reroll = reroll
	_signature = signature
	revision += 1
	var rendered = OS.get_ticks_usec()
	_display(context, latest_plan, show_log)
	log_line("刷新决策：" + latest_reroll.reason)
	log_line("计算耗时：读取 %.0f、当前页 %.0f、预算及说明 %.0f、刷新 %.0f、展示 %.0f 毫秒；评分 %d 次、复用 %d 次、分帧 %d 次，最长计算片段 %.1f 毫秒" % [(snapped - started) / 1000.0, (planned - snapped) / 1000.0, (saved - planned) / 1000.0, (rendered - saved) / 1000.0, (OS.get_ticks_usec() - rendered) / 1000.0, planner.evaluations + work.get("future_evaluations", 0), planner.cache_hits + work.get("future_hits", 0), work.get("yields", 0), work.get("max_slice_usec", 0) / 1000.0])
	return latest_plan


func _future_catalogue(context: Dictionary) -> Array:
	return adapter.reroll_catalogue(shop, context)


func execute(automatic: bool = false) -> void:
	if busy or not _available():
		return
	busy = true
	# 每个商品最多购买一次。每次购买后，以真实属性重新规划。
	var purchases = 0
	var operations = 0
	var finished = false
	var stopped = false
	yield(get_tree(), "idle_frame")
	while _planning and _available():
		yield(get_tree(), "idle_frame")
	while _available() and operations < 32 and (not automatic or manager.auto_enabled):
		var container = shop._get_shop_items_container(0)
		if container._is_delay_active:
			yield(get_tree().create_timer(0.07), "timeout")
			continue
		var result = latest_plan
		if result.empty() or _signature != _board_signature():
			result = _refresh(false, true)
			if result is GDScriptFunctionState:
				result = yield(result, "completed")
		if result.empty() or not _available() or (automatic and not manager.auto_enabled):
			break
		if not result.get("automatic", true):
			stopped = true
			break
		if not result.actions.empty() and not latest_reroll.allowed:
			var action = result.actions[0]
			if not _perform(action):
				log_line("停止：本次交易条件已变化，请查看新方案。")
				stopped = true
				break
			purchases += 1
			manager.previous_route = result.route
		else:
			var locks = {"locks": result.refresh_locks if latest_reroll.allowed else result.locks,
				"unlocks": result.refresh_unlocks if latest_reroll.allowed else result.unlocks}
			var lock_signature = _board_signature()
			if not _release_locks(locks, container._shop_items):
				stopped = true
				break
			# 先释放并重新读取真实货位、预算和费用，不能沿用解锁前的付款决定。
			if _board_signature() != lock_signature:
				operations += 1
				yield(get_tree(), "idle_frame")
				continue
			if not _add_locks(locks, container._shop_items):
				stopped = true
				break
			if _board_signature() != lock_signature:
				operations += 1
				yield(get_tree(), "idle_frame")
				continue
			if not latest_reroll.allowed:
				manager.previous_route = result.route
				finished = true
				break
			var count = shop._reroll_count[0]
			var price = shop._reroll_price[0]
			shop._get_reroll_button(0).grab_focus()
			shop._on_RerollButton_pressed(0)
			if shop._reroll_count[0] != count + 1:
				log_line("停止：游戏未接受本次刷新。")
				stopped = true
				break
			_roll_spent += price
			_auto_rolls += 1
			log_line("已刷新：花费 %d；本次商店自动刷新 %d/%d 次。" % [price, _auto_rolls, ShopPolicy.roll_limit(adapter.run.current_wave)])
		operations += 1
		yield(get_tree().create_timer(0.07), "timeout")
	if is_instance_valid(shop):
		log_line("本次完成：购买/换装 %d 次；本店自动刷新累计 %d 次，花费 %d 材料。" % [purchases, _auto_rolls, _roll_spent])
	busy = false
	if automatic and manager.auto_enabled and _available():
		if stopped or operations >= 32 or (finished and not manager.next_run.is_automatic_run()):
			_auto_stopped_board = _board_signature()
		elif finished and _signature == _board_signature() and _can_start_wave():
			shop._on_GoButton_pressed(0)


func _release_locks(result: Dictionary, slots: Array) -> bool:
	for target in result.unlocks:
		var slot = slots[target.index]
		if not _is_auto_locked(slot):
			return false
		slot.change_lock_status(false)
		if slot.locked:
			return false
		var key = _lock_key(slot.item_data, slot.wave_value)
		manager.auto_locks.erase(key)
		_released_locks[key] = true
		log_line("已解除助手锁定：%s，%s" % [target.name, target.reason])
		manager.save_locks()
	return true


func _add_locks(result: Dictionary, slots: Array) -> bool:
	for target in result.locks:
		var slot = slots[target.index]
		if not slot.active or slot.value != target.price:
			return false
		if not slot.locked:
			slot.change_lock_status(true)
			if not slot.locked:
				return false
			manager.auto_locks[_lock_key(slot.item_data, slot.wave_value)] = adapter.run.current_wave
			manager.save_locks()
			log_line("已锁定：%s，价格 %d，当前差 %d，留待下一商店再评估" % [target.name, target.price, max(0, target.price - adapter.run.get_player_currency(0))])
	return true


func _perform(action: Dictionary) -> bool:
	if action.kind == "bundle":
		var purchase = action.steps[1]
		var slot = shop._get_shop_items_container(0)._shop_items[purchase.index]
		if not _matches_purchase(slot, purchase) or _signature != _board_signature() or shop._get_shop_items_container(0)._is_delay_active:
			return false
		var prep = action.steps[0]
		var fresh = adapter.snapshot(shop)
		if not fresh.coverage.automatic or not Planner.new().validates_bundle(fresh, action):
			return false
		if adapter.run.get_player_currency(0) + prep.get("refund", 0) < purchase.price or not _perform(prep):
			return false
		if _perform(purchase):
			return true
		log_line("原生游戏已完成前一步，但未完成购买：" + purchase.name)
		return false
	if action.kind == "sell" or action.kind == "combine":
		if adapter.effect("lock_current_weapons") > 0:
			return false
		for weapon in adapter.run.get_player_weapons(0):
			if str(weapon.get_instance_id()) != action.key:
				continue
			var before = adapter.run.get_player_weapons(0).size()
			if action.kind == "sell":
				shop._on_item_discard_button_pressed(weapon, 0)
			else:
				var partner = adapter.run.get_combine_partner(weapon, 0)
				if partner == null or str(partner.get_instance_id()) != action.partner or not adapter.run.can_combine(weapon, 0):
					return false
				shop._on_item_combine_button_pressed(weapon, 0)
			if adapter.run.get_player_weapons(0).size() != before - 1:
				return false
			log_line("%s：%s" % ["已出售" if action.kind == "sell" else "已合成", action.name])
			return true
		return false
	var container = shop._get_shop_items_container(0)
	var slot = container._shop_items[action.index]
	if not _matches_purchase(slot, action) or adapter.run.get_player_currency(0) < slot.value:
		return false
	if slot.item_data.has_method("get_weapon_id_hash"):
		if not container._can_weapon_be_bought(slot):
			return false
		var partner = null if adapter.run.has_weapon_slot_available(slot.item_data, 0) else adapter.run.get_combine_partner(slot.item_data, 0)
		if (str(partner.get_instance_id()) if partner != null else "") != action.get("partner", ""):
			return false
	if action.choice >= 0:
		slot.effect_choice_selected = action.choice
	container.on_shop_item_buy_button_pressed(slot)
	if slot.active:
		return false
	log_line("已购买：%s，花费 %d%s" % [action.name, action.price, "；选择 " + action.choice_text if action.choice >= 0 else ""])
	return true


func _matches_purchase(slot, action: Dictionary) -> bool:
	return slot.active and slot.value == action.price and str(slot.item_data.get_instance_id()) == action.slot_key


func _display(context: Dictionary, result: Dictionary, is_preview: bool) -> void:
	_log.clear_page()
	if is_preview:
		_log.open()
	log_line("助手 %s | 决策更新 #%d | 刷新次数 %d | 材料 %d | %s | 目标：%s" % [manager.version, revision, context.reroll_count, context.gold, context.character, result.goal])
	log_line(context.coverage.note)
	for reason in result.reasons:
		log_line(reason)
	var weapons = []
	var measured = []
	for weapon in context.weapons:
		weapons.append(weapon.name)
		var damage = weapon.source.dmg_dealt_last_wave
		if damage > 0:
			measured.append("%s %d" % [weapon.name, damage])
	log_line("现有武器：" + PoolStringArray(weapons).join("、"))
	if not context.get("combat_profile", {}).empty():
		var profile = context.combat_profile
		log_line("下一波原生生成参照：平均 %.0f、10 秒峰值 %.0f 生命/秒，预计 %.0f 个普通敌人；命中、覆盖与接敌仍为估计" % [profile.mean, profile.peak, profile.spawns])
	if context.has("battle_observation"):
		var observed = context.battle_observation
		log_line("上波观测 %.0f 秒：接敌 %.0f%%，前/后半波平均活敌 %.1f/%.1f，有效武器伤害 %.0f/秒；清场校准 %.0f%%" % [observed.seconds, observed.engaged * 100.0, observed.early_enemies, observed.late_enemies, observed.effective_dps, planner.Combat.calibration(observed) * 100.0])
	if not measured.empty():
		log_line("上波原生武器伤害记录：" + PoolStringArray(measured).join("；"))
	var described = {}
	var inspected = context.weapons.duplicate()
	for offer in context.offers:
		if offer.get("kind", "weapon") == "weapon":
			inspected.append(offer.weapon)
	for weapon in inspected:
		var signature = str([weapon.id, weapon.damage, weapon.interval, weapon.scaling, weapon.attack_speed_mod])
		if described.has(signature):
			continue
		described[signature] = true
		var scaling = []
		for stat in weapon.scaling:
			scaling.append("%s×%.2f" % [context.stat_labels.get(stat, stat), weapon.scaling[stat]])
		log_line("伤害依据 %s：原生单发 %.0f，攻击间隔 %.3f 秒，暴击 %.0f%%×%.2f；缩放 %s；类别攻速 %+.0f%%" % [weapon.name, weapon.damage, weapon.interval, clamp(weapon.crit_chance, 0, 1) * 100, weapon.crit_damage, PoolStringArray(scaling).join("＋"), weapon.attack_speed_mod])
		if not weapon.get("unmeasured", []).empty():
			log_line("%s 尚未进入总分的原生参数 %s" % [weapon.name, PoolStringArray(weapon.unmeasured).join("；")])
	var offers = []
	for offer in context.offers:
		offers.append("%s %d" % [offer.item.name if offer.get("kind", "weapon") == "item" else offer.weapon.name, offer.price])
	log_line("当前商品及价格：" + PoolStringArray(offers).join("；"))
	for action in result.actions:
		var lead = "本页备选" if latest_reroll.allowed else "建议"
		log_line("%s%s：%s%s" % [lead, "购买" if action.kind == "buy" else ("出售换装" if action.steps[0].kind == "sell" else "合成腾槽后购买"), action.name, "；" + action.get("choice_text", "") if action.get("choice", -1) >= 0 else ""])
		if action.get("copies", 1) > 1:
			log_line("这笔购买消耗复制道具，实际获得 %d 件" % action.copies)
		log_line(planner.explain_gain(action.before, action.after, planner.gains(action.before, action.after)) + "；购买门槛 %.2f 分" % action.threshold)
	for skipped in result.skipped:
		log_line(skipped)
	var lock_targets = result.refresh_locks if latest_reroll.allowed else result.locks
	var lock_money = context.money if latest_reroll.allowed else result.state.money
	for target in lock_targets:
		log_line("建议%s：%s，价格 %d，差 %d；在共享预算内补强 %+.2f 分" % ["保持锁定" if target.locked else "锁定", target.name, target.price, max(0, target.price - lock_money), target.gain])
	if result.has("future_shop"):
		var future = result.future_shop
		log_line("下店保守预算 %d；当前为%s预留 %d %s" % [future.budget, future.target, future.reserve, "生命" if context.hp_shop else "材料"])
	for target in (result.refresh_unlocks if latest_reroll.allowed else result.unlocks):
		log_line("建议解除助手锁定：%s，%s" % [target.name, target.reason])
	_display_manual_actions(context)


func _display_manual_actions(context: Dictionary) -> void:
	var dlc = adapter.items.get_dlc_data_by_id("primal_dread")
	var slots = shop._get_shop_items_container(0)._shop_items
	var currency = "生命" if context.hp_shop else "材料"
	for slot in slots:
		if not slot.active:
			continue
		var name = slot.item_data.get_name_text()
		if slot._dismantle_button.is_visible_in_tree() and dlc != null:
			log_line("手动拆解 %s 花费 %d %s，获得 %d 机械零件" % [name, slot.get_dismantle_price(), currency, dlc.get_dismantle_meca_parts(slot.item_data)])
		if slot._ban_button.is_visible_in_tree():
			log_line("手动封禁 %s 消耗 1 枚封禁令（剩余 %d），该条目从常规候选池移除" % [name, adapter.run.players_data[0].remaining_ban_token])
		if shop._item_steals[0] > 0 and slot._steal_button.is_visible_in_tree():
			var caught = adapter.items.get_chance_getting_caught(slot, context.wave, adapter.effect("item_steals_spawns_random_elite"))
			var spawns = []
			for entry in adapter.run.get_player_effects(0)[adapter.keys.item_steals_spawns_enemy_hash]:
				spawns.append("%.0f%%" % entry[1])
			var extra = "，其他额外敌群的触发概率 %s" % PoolStringArray(spawns).join(" / ") if not spawns.empty() else ""
			log_line("手动偷取 %s 可省 %d %s，剩余 %d 次，下波额外精英概率 %.0f%%%s" % [name, slot.value, currency, shop._item_steals[0], caught * 100.0, extra])


func log_line(message: String) -> void:
	_log.write(message)
