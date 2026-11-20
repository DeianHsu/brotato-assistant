extends Node

const Planner = preload("res://mods-unpacked/Potato-AutoBuild/planner.gd")
const Adapter = preload("res://mods-unpacked/Potato-AutoBuild/game_adapter.gd")
const DecisionLog = preload("res://mods-unpacked/Potato-AutoBuild/decision_log.gd")
var manager
var ui
var adapter = Adapter.new()
var planner = Planner.new()
var _log
var _signature = ""
var recommendation = {}
var _crate_hint: Label


func _ready() -> void:
	adapter.setup(get_tree())
	_log = DecisionLog.new()
	_log.manager = manager
	_log.context_owner = self
	add_child(_log)


func is_active() -> bool:
	if not is_instance_valid(ui) or not ui.is_visible_in_tree() or get_tree().paused or adapter.run.is_coop_run:
		return false
	var container = ui._get_player_container(0)
	return container != null and ui._player_is_choosing[0] and not container._is_focus_in_blockers() and ((container.is_showing_item() and container._item_data != null) or container._upgrades_container.is_visible_in_tree())


func _process(_delta: float) -> void:
	if not is_active():
		_signature = ""
		if _crate_hint != null:
			_crate_hint.hide()
		return
	var signature = str(ui._showing_option[0])
	var container = ui._get_player_container(0)
	signature += str([adapter.run.get_player_gold(0), container._reroll_count])
	if container.is_showing_item():
		signature += str([container._item_data.get_instance_id(), adapter.run.get_player_weapons(0).size(), adapter.run.get_player_items(0).size(), manager.auto_enabled, manager.next_run.is_automatic_run(), container._discard_button.is_visible_in_tree(), container._discard_button.disabled])
	for card in ui._get_player_container(0)._get_upgrade_uis():
		if card.visible and card.upgrade_data != null:
			signature += str(card.upgrade_data.get_instance_id())
	if signature != _signature:
		_signature = signature
		_refresh(false)
	if manager.auto_enabled and not container._button_pressed and manager.next_run.is_automatic_run():
		if recommendation.get("auto_reroll", false) and container._reroll_count == 0 and container._reroll_button.is_visible_in_tree() and not container._reroll_button.disabled:
			var fee = container._reroll_price
			container._on_RerollButton_pressed()
			if container._reroll_count > 0:
				_log.write("已重抽属性，花费 %d 材料，重新比较四张卡。" % fee)
				_signature = ""
				return
		if _confirm(recommendation, container):
			_signature = ""


func preview() -> Dictionary:
	return _refresh(true)


func _refresh(show_log: bool) -> Dictionary:
	if not is_active():
		return {}
	_log._position()
	var container = ui._get_player_container(0)
	if container.is_showing_item():
		return _refresh_crate(show_log)
	if _crate_hint != null:
		_crate_hint.hide()
	var choices = []
	var cards = container._get_upgrade_uis()
	for i in range(cards.size()):
		var card = cards[i]
		if card.visible and card.upgrade_data != null:
			var slots = 0
			for effect in card.upgrade_data.effects:
				if effect.key == "weapon_slot":
					slots += effect.value
			choices.append({"index": i, "name": card.upgrade_data.get_name_text(), "stats": adapter.effect_stats(card.upgrade_data.effects), "slots": slots, "data": card.upgrade_data})
	var context = adapter.snapshot()
	if not context.coverage.automatic:
		return _manual_coverage(context, show_log, cards)
	recommendation = planner.rank_upgrades(context, choices, manager.previous_route)
	if show_log:
		_log.open()
	_log.write("属性升级 | 目标：" + recommendation.goal)
	_log.write(context.coverage.note)
	_log.write(recommendation.priority_note)
	if recommendation.burst_note != "":
		_log.write(recommendation.burst_note)
	for rank in range(recommendation.ranked.size()):
		var row = recommendation.ranked[rank]
		_log.write("%s第 %d 项 %s：%s；%s" % ["推荐 " if rank == 0 else "备选 ", row.index + 1, row.name, row.changes, row.reason])
	if container._reroll_button.is_visible_in_tree():
		var pool = adapter.upgrade_reroll_pool(container._level, container._old_upgrades, context)
		var quote = planner.estimate_upgrade_reroll(recommendation, pool, container._reroll_price)
		recommendation.reroll = quote
		recommendation.auto_reroll = container._reroll_count == 0 and _worth_rerolling(quote, context)
		var note = "重抽花费 %d 材料%s" % [quote.price, "（材料不足）" if not quote.affordable else ""]
		if quote.has("expected"):
			note += "；扣除材料机会成本后，预计最佳综合 %+.2f 分，相比当前首选 %+.2f 分，超过当前首选的机会约 %.0f%%" % [quote.expected, quote.surplus, quote.chance * 100.0]
		else:
			note += "；候选不足或各品质属性池不同，保留手动判断"
		if quote.get("keep_current", false):
			note += "。主播刚结束重试，优先确认当前有效加点"
		_log.write(note)
	_log.write("执行快捷键仅确认当前一级；可继续用方向键和 A 自行选择。")
	_highlight(cards, recommendation.ranked[0].index if not recommendation.ranked.empty() else -1)
	return recommendation


func _worth_rerolling(quote: Dictionary, context: Dictionary) -> bool:
	if context.hp_shop or context.get("resources", {}).get("materials_as_health", false) or quote.get("keep_current", false):
		return false
	# 每波最多一次，给接下来的商店保留至少九成余额。
	return quote.affordable and 10 * quote.price <= context.gold and quote.get("surplus", 0.0) > 0.0 and quote.get("chance", 0.0) >= 0.8


func _refresh_crate(show_log: bool) -> Dictionary:
	var container = ui._get_player_container(0)
	var source = container._item_data
	var weapon = source.has_method("get_weapon_id_hash")
	var context = adapter.snapshot()
	if not context.coverage.automatic:
		_show_crate_reason(container, context.coverage.note)
		return _manual_coverage(context, show_log, [container._take_button, container._discard_button])
	var offers = adapter.crate_offers(source)
	var refund = adapter.items.get_item_box_recycling_value(context.wave, source.value, 0, weapon)
	recommendation = planner.rank_crate(context, offers, refund, manager.previous_route)
	recommendation.data = source
	if weapon and not adapter.run.can_take_weapon(source, 0):
		recommendation.action = "manual"
		recommendation.reason = "当前武器槽或职业规则不允许直接拿取"
	var parts = adapter.items.get_meca_parts(source) if weapon else 0
	if parts > 0:
		recommendation.reason += "。回收另得 %d 个机械零件" % parts
	var can_recycle = container._discard_button.is_visible_in_tree() and not container._discard_button.disabled
	if recommendation.action == "manual" and can_recycle and manager.auto_enabled and manager.next_run.is_automatic_run():
		recommendation.action = "recycle"
		recommendation.reason += "。自动局回收 %d 材料" % refund
	elif recommendation.action == "recycle" and not can_recycle:
		recommendation.action = "manual"
		recommendation.reason = "当前无法回收，请检查可用的宝箱选项"
	_show_crate_reason(container, recommendation.reason if recommendation.action == "manual" else "")
	if show_log:
		_log.open()
	_log.write("战后宝箱 | 目标：%s | %s" % [recommendation.goal, source.get_name_text()])
	_log.write(context.coverage.note)
	_log.write(recommendation.priority_note)
	for choice in recommendation.choices:
		_log.write(choice)
	_log.write(recommendation.recycle_note)
	if container._ban_button.is_visible_in_tree():
		_log.write("封禁可回收 %d 材料，消耗 1 枚封禁令（剩余 %d），该条目从常规候选池移除，留给手动选择" % [refund, adapter.run.players_data[0].remaining_ban_token])
	_log.write("推荐%s%s：%s" % [{"take": "保留", "recycle": "回收", "manual": "手动选择"}[recommendation.action], "（" + recommendation.get("choice_text", "") + "）" if recommendation.get("choice", -1) >= 0 else "", recommendation.reason])
	_highlight([container._take_button, container._discard_button], {"take": 0, "recycle": 1}.get(recommendation.action, -1))
	return recommendation


func _show_crate_reason(container, reason: String) -> void:
	if reason.empty():
		if _crate_hint != null:
			_crate_hint.hide()
		return
	if _crate_hint == null:
		var buttons = container._take_button.get_parent()
		_crate_hint = Label.new()
		_crate_hint.autowrap = true
		_crate_hint.align = Label.ALIGN_CENTER
		_crate_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var font = DynamicFont.new()
		font.font_data = load("res://resources/fonts/raw/NotoSansSC-Medium.otf")
		font.size = 22
		_crate_hint.add_font_override("font", font)
		buttons.add_child(_crate_hint)
		buttons.move_child(_crate_hint, container._take_button.get_index())
	_crate_hint.text = "请手动处理宝箱：" + reason
	_crate_hint.show()


func execute() -> void:
	if not is_active():
		return
	var container = ui._get_player_container(0)
	if container._button_pressed:
		return
	_confirm(_refresh(false), container)


func _confirm(result: Dictionary, container) -> bool:
	if result.empty() or not result.get("automatic", true):
		return false
	if container.is_showing_item():
		if result.action == "manual" or result.data != container._item_data:
			return false
		if result.action == "take":
			if result.get("choice", -1) >= 0 and result.choice != container._meca_effect_choice_selected:
				container._meca_effect_choice_selected = result.choice
				container.update_effect_choice_buttons_visuals()
			if container._take_button.disabled:
				return false
			_log.write("已保留宝箱物品：" + result.data.get_name_text())
			container._on_TakeButton_pressed()
		else:
			if container._discard_button.disabled or not container._discard_button.is_visible_in_tree():
				return false
			_log.write("已回收宝箱物品：" + result.data.get_name_text())
			container._on_DiscardButton_pressed()
		manager.previous_route = result.route
		return true
	if result.ranked.empty():
		return false
	var row = result.ranked[0]
	var card = container._get_upgrade_uis()[row.index]
	if card.upgrade_data != row.data or not card.visible or card.button.disabled:
		return false
	manager.previous_route = result.route
	_log.write("已选择属性：第 %d 项 %s；%s" % [row.index + 1, row.name, row.changes])
	# 经过原生卡片、节流与升级信号链，只确认本次显示的一级。
	card._on_ChooseButton_pressed()
	return true


func toggle_log() -> void:
	_log.toggle()


func _manual_coverage(context: Dictionary, show_log: bool, controls: Array) -> Dictionary:
	recommendation = {"automatic": false, "action": "manual", "ranked": [], "coverage": context.coverage}
	_log.clear_page()
	if show_log:
		_log.open()
	_log.write("当前角色：" + context.character)
	_log.write(context.coverage.note)
	_log.write("请手动选择当前属性或宝箱，执行快捷键不会确认或回收。")
	_highlight(controls, -1)
	return recommendation


func log_rect(size: Vector2) -> Rect2:
	if ui._get_player_container(0).is_showing_item():
		return Rect2(16, 24, min(500, size.x * 0.27), min(630, size.y - 48))
	return Rect2(16, size.y - 376, min(820, size.x * 0.48), 360)


func _highlight(cards: Array, recommended_index: int) -> void:
	for i in range(cards.size()):
		var frame = cards[i].get_node_or_null("PotatoRecommendation")
		if frame == null:
			frame = ReferenceRect.new()
			frame.name = "PotatoRecommendation"
			frame.editor_only = false
			frame.border_color = Color(0.35, 1.0, 0.65)
			frame.border_width = 4
			frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cards[i].add_child(frame)
			frame.set_anchors_and_margins_preset(Control.PRESET_WIDE)
		frame.visible = i == recommended_index
