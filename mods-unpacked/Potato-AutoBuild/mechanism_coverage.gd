extends Reference

# 按实际效果核对；角色 ID 不参与评分或自动执行许可。
# “已覆盖”仅指核心规则，不表示战斗轨迹、清场或胜率能精确预测。
const EXACT_KEYS = ["weapon_slot", "max_melee_weapons", "max_ranged_weapons", "no_melee_weapons", "no_ranged_weapons", "no_duplicate_weapons", "min_weapon_tier", "max_weapon_tier", "lock_current_weapons", "weapon_set_bonus", "all_weapons_count_for_sets", "dodge_cap", "no_heal", "die_in_one_hit", "items_price", "weapons_price", "recycling_gains", "minimum_weapons_in_shop", "disable_item_locking", "meca_only", "mutant_only", "no_level_upgrades", "more_horde", "extra_starting_weapon_choices"]
const EXACT_ARRAYS = ["remove_shop_items", "starting_weapon", "starting_item", "cursed_starting_item", "specific_items_price", "guaranteed_shop_items", "additional_weapon_effects", "tier_i_weapon_effects", "tier_iv_weapon_effects", "unique_weapon_effects", "weapon_scaling_stats"]
const APPROX_KEYS = {
	"upgraded_baits": "强化鱼饵按持有量估计额外敌群的数量和刷新时点",
	"number_of_enemies": "生成量已读取，击杀和拾取份额估计", "enemy_health": "原生生命倍率与分组清场估计", "enemy_damage": "原生敌伤与参考接触频率",
	"enemy_speed": "移速对接触压力采用有限估计", "map_size": "地图改变后的接敌与拾取距离未逐点模拟", "group_structures": "建筑集中布局用覆盖率估计",
	"trees": "树木生成、破坏与掉落估计", "trees_start_wave": "树木生成已读，破坏时点估计", "harvesting_growth": "收获取整，未来波次收益折现",
	"next_level_xp_needed": "原生经验门槛，未来经验与升级数估计", "xp_gain": "经验倍率与未来升级估计", "weapon_slot_upgrades": "原生槽位上限，未来升级数估计",
	"gold_drops": "活动掉落与收集比例估计", "enemy_gold_drops": "活动掉落与收集比例估计", "pickup_range": "拾取效率估计",
	"pacifist": "存活敌人数估计，结算按原生取整", "cryptid": "活树与留树奖励估计", "lose_hp_per_second": "自伤频率独立，恢复与缺血时序估计",
	"gain_pct_gold_start_wave": "波初取整已覆盖，未来余额估计", "destroy_weapons": "下店销毁已覆盖，下一波武器输出估计", "hp_shop": "生命付款及转换，活动预算保守估计",
	"materials_as_health": "购物扣除防护，承伤材料损耗估计", "can_attack_while_moving": "连续移动观测，遗留弹丸和燃烧估计",
	"explosion_damage": "原生伤害，范围命中估计", "projectiles": "原生弹丸数，散布命中估计", "piercing": "穿透命中与衰减估计", "accuracy": "散布命中估计",
	"damage_against_bosses": "首领伤害与有效攻击覆盖估计", "knockback": "控场收益有限估计", "consumable_heal": "食物可用量和有效治疗估计", "enemy_fruit_drops": "食物生成和实际拾取份额估计"
}
const APPROX_ARRAYS = ["stats_on_level_up", "stats_end_of_wave", "consumable_stats_while_max", "temp_stats_while_moving", "temp_stats_while_not_moving", "stats_below_half_health", "temp_stats_on_hit", "temp_stats_on_dodge"]
const MISSING = {
	"beast_master_effect": "宠物专属成长和召唤收益", "boosted_wanted_item_tag": "宠物标签额外商店分布",
	"bonus_weapon_class_damage_against_cursed_enemies": "类别对诅咒敌人的条件伤害", "extra_loot_aliens": "额外战利品外星人收益", "stronger_loot_aliens_on_kill": "外星人击杀后增强风险",
	"convert_bonus_gold": "特殊材料转炮塔成长", "max_turret_count": "特殊炮塔替换与上限", "level_upgrades_modifications": "属性升级奖励倍率",
	"bonus_non_elemental_damage_against_burning_targets": "燃烧目标的非元素伤害加成", "explode_on_consumable_burning": "拾取燃烧爆炸", "stats_on_fruit": "水果永久成长", "poisoned_fruit": "毒水果伤害与收益",
	"gain_stat_when_attack_killed_enemies": "单次攻击多杀成长", "item_steals": "偷窃收益和额外敌人代价", "item_steals_spawns_random_elite": "偷窃产生随机精英", "stronger_elites_on_kill": "精英击杀后增强",
	"enemy_percent_damage_taken": "标记目标的条件易伤", "gain_stat_for_every_step_after_equip": "步数收入及生命成长", "increase_material_value": "材料单位价值改变", "reload_when_pickup_gold": "拾取触发装填",
	"explode_on_overkill": "溢出伤害爆炸", "charm_on_hit": "魅惑敌人伤害与控制", "no_cure_between_wave": "跨波保留血量及购物后的血量变化", "no_fruit_attracted_end_of_wave": "波末食物不自动吸收",
	"dig_sites": "挖掘点事件收益", "item_box_recycling_gains": "特殊宝箱回收成长", "meca_parts_on_level_up": "未来机械零件及改造机会价值",
	"time_shift_on_hit": "受击改变波次时间", "effect_mixing_up_wave": "混合波次时间和生成变化", "effect_mutate_end_of_wave": "未来随机变异", "mutate_into_better_tier_chance": "随机变异升档机会",
	"fog_of_war_permanent": "永久迷雾下的视野压力", "burn_weapon": "武器献祭收益", "burn_primitive_bonus": "献祭后的类别收益", "fire_explosion": "地面火焰输出", "fire_puddle_on_burning_death": "死亡扩散火焰",
	"dual_evolution": "双重进化和变异分支", "mutation_fruit_chance": "变异水果事件", "gain_stat_for_killed_enemies_in_zone": "区域击杀永久成长", "poacher_zone_materials": "区域材料收集",
	"effect_crate_give_weapon": "宝箱武器来源与未来替换机会", "effect_no_weapon_in_shop": "无商店武器时的宝箱机会价值"
}

static func inspect(character, context: Dictionary) -> Dictionary:
	var result = {"status": "covered", "automatic": true, "approximate": [], "missing": []}
	if character == null:
		result.missing.append("当前角色数据不可用")
	else:
		for e in character.effects:
			var rule = e.custom_key if e.custom_key != "" and (e.storage_method == 1 or e.custom_key in EXACT_ARRAYS or MISSING.has(e.custom_key)) else e.key
			if MISSING.has(rule):
				_add(result.missing, MISSING[rule])
			elif e.get_id() in ["class_bonus", "stat_gains_modifications"]:
				continue
			elif e.get_id() == "gain_stat_for_every_stat":
				if e.stat_scaled.begins_with("stat_") or e.stat_scaled in ["materials", "free_weapon_slots", "structure", "pet", "different_item", "common_item", "legendary_item", "duplicate_item", "item_bait"]:
					continue
				elif e.stat_scaled in ["living_tree", "living_enemy", "burning_enemy", "percent_player_missing_health"]:
					_add(result.approximate, "活动属性联动按观测或公开的覆盖率估计")
				else:
					_add(result.missing, "属性联动来源：" + e.stat_scaled)
			elif e.get_id() == "convert_stat" and e.custom_key in ["convert_stats_end_of_wave", "convert_stats_half_wave"]:
				_add(result.approximate, "原生转换顺序和取整，波内活动与未来收益估计")
			elif e.get_id() == "chance_stat_damage" and e.custom_key in ["dmg_when_pickup_gold", "dmg_when_heal", "dmg_on_dodge"]:
				_add(result.approximate, "原生触发伤害，有效事件数和目标覆盖估计")
			elif e.get_id() == "item_exploding" and e.key in ["explode_on_hit", "explode_on_consumable"] and not e.scale_with_missing_health:
				_add(result.approximate, "爆炸次数受实际受伤、食物与生存约束，范围命中估计")
			elif e.get_id() in ["effect", "double_value"] and rule in APPROX_ARRAYS:
				_add(result.approximate, "成长或状态效果按事件时点和连续活动估计")
			elif e.get_id() == "effect" and (rule in EXACT_ARRAYS or rule in EXACT_KEYS or (e.storage_method != 1 and (e.key.begins_with("stat_") or e.key == ""))):
				continue
			elif e.get_id() == "effect" and APPROX_KEYS.has(rule):
				_add(result.approximate, APPROX_KEYS[rule])
			else:
				_add(result.missing, "未建模效果：" + e.get_id() + "/" + rule)
	for weapon in context.get("weapons", []):
		for note in weapon.get("approximate", []):
			_add(result.approximate, note)
		for pending in weapon.get("unmeasured", []):
			_add(result.approximate, "保留已有" + weapon.name + "，特殊效果仅部分计分：" + pending)
	if not result.missing.empty():
		result.status = "missing"
		result.automatic = false
	elif not result.approximate.empty():
		result.status = "approximate"
	result.note = {"covered": "核心机制已覆盖", "approximate": "核心机制含明确近似", "missing": "核心机制未覆盖，暂停自动操作"}[result.status]
	result.note += "：" + PoolStringArray(result.missing if not result.automatic else result.approximate).join("；") if result.status != "covered" else ""
	return result


static func _add(values: Array, value: String) -> void:
	if not value in values:
		values.append(value)
