extends Reference

const WaveProfile = preload("res://mods-unpacked/Potato-AutoBuild/wave_profile.gd")
const Combat = preload("res://mods-unpacked/Potato-AutoBuild/combat_model.gd")
const Coverage = preload("res://mods-unpacked/Potato-AutoBuild/mechanism_coverage.gd")

const STAT_DEFAULTS = ["max_hp", "armor", "dodge", "speed", "hp_regeneration", "lifesteal", "percent_damage", "attack_speed", "melee_damage", "ranged_damage", "elemental_damage", "engineering", "evolution", "curse"]
var run
var items
var keys
var utils
var service
var _Args
var _DLC2
var player = 0
var _cache = {}
var _merges = {}
var _sets = {}
var _wave_seconds = 60.0
const ITEM_BONUSES = ["items_price", "weapons_price", "reroll_price", "free_rerolls", "trees", "structures_can_crit", "burning_spread", "piercing", "piercing_damage", "bounce", "bounce_damage", "number_of_enemies", "knockback", "consumable_heal", "hit_protection", "hp_start_wave", "torture", "lose_hp_per_second", "explosion_damage", "explosion_size", "damage_against_bosses", "bonus_crit_damage", "gain_pct_gold_start_wave", "xp_gain", "enemy_damage", "enemy_health"]
const WAVE_MODIFIERS = ["xp_gain", "enemy_damage", "enemy_health", "enemy_speed"]
const SECONDARY_EFFECTS = ["pickup_range", "instant_gold_attracting", "gold_drops", "enemy_gold_drops", "chance_double_gold", "item_box_gold", "recycling_gains", "harvesting_growth", "one_shot_trees", "heal_when_pickup_gold", "heal_on_kill", "heal_on_crit_kill", "enemy_fruit_drops", "enemy_speed", "hp_start_next_wave", "fog_visibility", "knockback_aura", "consumable_heal_over_time", "dodge_cap", "structure_attack_speed", "structure_range", "fossil_count", "weapon_slot", "gold_on_crit_kill", "extra_item_in_crate", "burning_cooldown_reduction", "burning_stacks", "accuracy", "jellyshield_count"]
const REPLACE_EFFECTS = ["knockback_aura", "consumable_heal_over_time", "dodge_cap"]
const LINK_SOURCES = ["materials", "free_weapon_slots", "knockback", "fossil_count", "structure", "pet", "different_item", "common_item", "legendary_item", "duplicate_item", "living_enemy", "burning_enemy", "living_tree", "item_bait"]


func setup(tree: SceneTree) -> void:
	run = tree.root.get_node("RunData")
	items = tree.root.get_node("ItemService")
	keys = tree.root.get_node("Keys")
	utils = tree.root.get_node("Utils")
	service = tree.root.get_node("WeaponService")
	_Args = load("res://singletons/weapon_service_init_stats_args.gd")
	_DLC2 = load("res://dlcs/dlc_2/dlc_2_data.gd")


func snapshot(shop = null) -> Dictionary:
	_cache.clear()
	_merges.clear()
	_sets.clear()
	var zone = run.get_node("/root/ZoneService").get_zone_data(run.current_zone)
	var index = run.time_shifter_wave_mapping.get(run.get_next_wave(), run.get_next_wave()) - 1
	var next_wave = zone.waves_data[index] if zone != null and index >= 0 and index < zone.waves_data.size() else null
	_wave_seconds = float(next_wave.wave_duration) if next_wave != null else 60.0
	var stats = {}
	var permanent_stats = {}
	var unlinked_stats = {}
	var gains = {}
	var effects = run.get_player_effects(player)
	# 从本局实际效果表发现属性；包括新版本属性、增益倍率及模组属性。
	for hash_key in effects:
		var stat_key = str(keys.hash_to_string.get(hash_key, ""))
		if (stat_key.begins_with("stat_") or stat_key in WAVE_MODIFIERS) and _numeric(effects[hash_key]):
			var stat = stat_key.trim_prefix("stat_")
			stats[stat] = utils.get_stat(hash_key, player)
			permanent_stats[stat] = run.get_stat(hash_key, player)
			unlinked_stats[stat] = permanent_stats[stat] + run.get_node("/root/TempStats").get_stat(hash_key, player)
			gains[stat] = run.get_stat_gain(hash_key, player)
	for stat in STAT_DEFAULTS:
		if not stats.has(stat):
			stats[stat] = 0.0
			gains[stat] = 1.0
	stats.max_hp = run.get_player_max_health(player)
	var weapons = []
	for weapon in run.get_player_weapons(player):
		weapons.append(describe(weapon))
	var offers = []
	var slots = shop._get_shop_items_container(player)._shop_items if shop != null else []
	for i in range(slots.size()):
		var slot = slots[i]
		if not slot.active or slot.item_data == null:
			continue
		if not slot.item_data.has_method("get_weapon_id_hash"):
			var item = describe_item(slot.item_data)
			offers.append({"index": i, "kind": "item", "price": slot.value, "item": item, "blocked": item.blocked})
			continue
		var options = []
		for effect in slot.item_data.effects:
			if effect.get_id() == "effect_option":
				options.append(effect)
		if slot.item_data.is_meca and options.size() == 2:
			for choice in range(2):
				# 原生转换函数会修改资源，必须在深拷贝上计算两个选项。
				var selected = _DLC2.change_effect_option_to_modular_effect(clone_weapon(slot.item_data), choice)
				offers.append({"index": i, "choice": choice, "choice_text": tr(options[choice].key.to_upper()) + " +" + str(options[choice].value), "price": slot.value, "weapon": describe(selected), "blocked": ""})
		else:
			offers.append({"index": i, "choice": -1, "price": slot.value, "weapon": describe(slot.item_data), "blocked": "机械选项数据不完整" if slot.item_data.is_meca and not options.empty() else ""})
	for offer in offers:
		offer.slot_key = str(slots[offer.index].item_data.get_instance_id())
		offer.locked = slots[offer.index].locked
		offer.lockable = slots[offer.index].item_data.is_lockable and effect("disable_item_locking") == 0
		offer.pricing = _pricing(slots[offer.index].item_data, slots[offer.index].wave_value, slots[offer.index]._get_meca_weapon_markup())
	var rules = {
		"slots": int(effect("weapon_slot", 6)), "max_melee": int(effect("max_melee_weapons", 999)), "max_ranged": int(effect("max_ranged_weapons", 999)),
		"no_melee": effect("no_melee_weapons") > 0, "no_ranged": effect("no_ranged_weapons") > 0,
		"unique": effect("no_duplicate_weapons") > 0, "locked": effect("lock_current_weapons") > 0,
		"min_tier": int(effect("min_weapon_tier")), "max_tier": int(effect("max_weapon_tier", 99))
	}
	var threat = "normal"
	for spawn in run.elites_spawn:
		if spawn[0] == run.get_next_wave():
			threat = "elite" if spawn[1] == 0 else "horde"
	var character = run.get_player_character(player)
	var dlcs = run.enabled_dlcs.duplicate()
	var context = {
		"weapons": weapons, "offers": offers, "stats": stats, "gains": gains, "rules": rules, "set_bonuses": _sets,
		"money": run.get_player_currency(player), "gold": run.get_player_gold(player), "wave": run.current_wave, "final_wave": run.nb_of_waves, "difficulty": run.current_difficulty,
		"hp_shop": effect("hp_shop") > 0, "pacifist": effect("pacifist") > 0, "character": character.get_name_text() if character != null else "未知角色",
		"character_id": character.my_id if character != null else "", "dlcs": dlcs, "threat": threat,
		"all_sets": effect("all_weapons_count_for_sets") > 0, "set_bonus": int(effect("weapon_set_bonus")), "dodge_cap": effect("dodge_cap", 60),
		"merge": funcref(self, "merge"), "growth": _growth(), "stat_labels": {},
		"meca_parts": run.get_player_meca_parts(player), "meca_only": effect("meca_only") > 0, "mutant_only": effect("mutant_only") > 0,
		"pets": run.get_nb_pets(player), "links": _links(), "harvesting_growth": effect("harvesting_growth", 5)
	}
	context.raw_max_hp = utils.get_stat(keys.generate_hash("stat_max_hp"), player)
	context.preferred_flavor = -1 if run.is_dual_evolution(player) else items.get_preferred_flavor(player)
	context.same_weapon = funcref(items, "is_same_weapon")
	context.copy_purchase = _transaction_effect(effects, "duplicate_item")
	context.refresh_tier = _transaction_effect(effects, "increase_tier_on_reroll")
	context.hp_currency_fraction = run.get_stat(keys.stat_max_hp_hash, player) - context.money if context.hp_shop else 0.0
	context.missing_health = service.apply_inverted_health_bonus(1, 1, run.get_player_current_health(player), run.get_player_max_health(player))
	context.permanent_stats = permanent_stats
	context.unlinked_stats = unlinked_stats
	context.lifesteal_amount = 2 if effect("stat_double_lifesteal_bonus") > 0 else 1
	context.half_wave_conversions = []
	for conversion in effects.get(keys.convert_stats_half_wave_hash, []):
		var from_stat = keys.hash_to_string.get(conversion.key_hash, "")
		var to_stat = keys.hash_to_string.get(conversion.to_stat_hash, "")
		if from_stat.begins_with("stat_") and to_stat.begins_with("stat_") and conversion.value > 0:
			context.half_wave_conversions.append({"from_stat": from_stat.trim_prefix("stat_"), "to_stat": to_stat.trim_prefix("stat_"),
				"portion": conversion.pct_converted / 100.0, "cost": conversion.value, "reward": conversion.to_value})
	context.price_effects = {"items_price": effect("items_price"), "weapons_price": effect("weapons_price"), "reroll_price": effect("reroll_price")}
	var manager = run.get_node_or_null("/root/PotatoAutoBuild")
	if manager != null and manager.income_wave == run.current_wave:
		context.last_wave_income = manager.wave_income
		context.last_activity_income = manager.wave_activity_income
		context.income_ledger = manager.income_ledger.duplicate()
	context.progression = {"level": run.get_player_level(player), "xp": run.get_player_xp(player), "needed": funcref(run, "get_xp_needed"), "factor": 1.0 + effect("next_level_xp_needed") / 100.0, "upgrades": effect("no_level_upgrades") == 0, "slot_limit": effect("weapon_slot_upgrades"), "level_stats": {"max_hp": 1}}
	if manager != null and manager.xp_wave == run.current_wave and manager.wave_base_xp > 0.0:
		context.progression.base_xp = max(0.0, manager.wave_base_xp - manager.wave_harvest_xp)
	for entry in effects.get(keys.stats_on_level_up_hash, []):
		var stat = str(keys.hash_to_string.get(entry[0], "")).trim_prefix("stat_")
		context.progression.level_stats[stat] = context.progression.level_stats.get(stat, 0) + entry[1]
	context.next_wave_effects = {}
	for entry in effects.get(keys.stats_next_wave_hash, []):
		var stat = keys.hash_to_string.get(entry[0], "")
		if stat in WAVE_MODIFIERS:
			context.next_wave_effects[stat] = entry[1]
	context.hp_cap = effect("hp_cap", 999999)
	context.speed_cap = effect("speed_cap", 999999)
	context.crit_cap = effect("crit_chance_cap", 999999)
	context.bonus_crit_damage = effect("bonus_crit_damage")
	context.structures_can_crit = effect("structures_can_crit") > 0
	context.gold_start_pct = effect("gain_pct_gold_start_wave")
	context.resources = {"conversions": [], "destroy_weapons": effect("destroy_weapons") > 0,
		"materials_as_health": effect("materials_as_health") > 0,
		"damage_taken_on_materials": effect("damage_taken_on_materials") > 0,
		"die_in_one_hit": effect("die_in_one_hit") > 0, "supported": true}
	for conversion in effects.get(keys.convert_stats_end_of_wave_hash, []):
		context.resources.conversions.append(_conversion(conversion))
		if conversion.value <= 0:
			context.resources.supported = false
	context.boss_damage = effect("damage_against_bosses")
	context.enemy_count = effect("number_of_enemies")
	context.burst = _burst_reference(run.get_next_wave())
	context.pressure_reference = _pressure_reference(zone, next_wave, threat)
	context.combat_profile = WaveProfile.build(self, zone, next_wave, threat)
	if manager != null and manager.battle_observation.get("wave", -1) == run.current_wave and manager.battle_observation.get("character", "") == context.character_id:
		context.battle_observation = manager.battle_observation
		var observed_index = run.time_shifter_wave_mapping.get(run.current_wave, run.current_wave) - 1
		if zone != null and observed_index >= 0 and observed_index < zone.waves_data.size():
			var wave_limit = zone.waves_data[observed_index].max_enemies
			context.observed_enemy_limit = int(wave_limit + (run.get_player_count() - 1) * wave_limit / 8.0)
		context.automatic_battle = manager.auto_enabled and manager.battle_movement
	context.no_heal = effect("no_heal") > 0
	context.events = []
	for trigger in ["projectiles_on_death", "alien_eyes"]:
		var shots = effects.get(keys.generate_hash(trigger), [])
		if shots.size() >= 3 and shots[0] > 0:
			context.events.append(_projectile_event(trigger, shots[1], shots[0], shots[2], shots[3] if shots.size() > 3 else -1))
	for trigger in ["dmg_when_pickup_gold", "dmg_when_heal", "dmg_on_dodge", "dmg_when_death"]:
		for entry in effects.get(keys.generate_hash(trigger), []):
			context.events.append({"trigger": trigger, "stat": str(keys.hash_to_string.get(entry[0], "")).trim_prefix("stat_"), "ratio": entry[1] / 100.0, "chance": entry[2] / 100.0})
	for trigger in ["explode_on_hit", "explode_on_consumable"]:
		for entry in effects.get(keys.generate_hash(trigger), []):
			context.events.append(_event_explosion(entry, trigger))
	context.wave_duration = _wave_seconds
	context.tree_profile = _tree_profile(zone, next_wave, threat)
	context.secondary = {}
	for name in SECONDARY_EFFECTS:
		context.secondary[name] = effect(name)
	context.secondary.hp_start_next_wave = effect("hp_start_next_wave", 100)
	context.secondary.harvesting_growth = context.harvesting_growth
	context.secondary.dodge_cap = context.dodge_cap
	for name in ["gold_on_crit_kill", "extra_item_in_crate"]:
		for entry in effects.get(keys.generate_hash(name), []):
			context.secondary[name] += entry[1]
	context.fog_share = 0.0
	for wave in run.events_fog_of_war:
		if wave >= run.get_next_wave():
			context.fog_share += 1.0 / max(1, run.nb_of_waves - run.current_wave)
	if run.get_next_wave() in run.events_fog_of_war:
		context.fog_share = max(0.5, context.fog_share)
	context.still_share = 0.15
	context.can_attack_while_moving = effect("can_attack_while_moving", 1) != 0
	context.activity_effects = {"pacifist": effect("pacifist"), "cryptid": effect("cryptid"), "materials_per_living_enemy": effect("materials_per_living_enemy")}
	context.gold_ticks = []
	context.conditional = []
	for when in ["temp_stats_while_not_moving", "temp_stats_while_moving", "stats_below_half_health", "temp_stats_on_hit", "temp_stats_on_dodge"]:
		for entry in effects.get(keys.generate_hash(when), []):
			var stat = str(keys.hash_to_string.get(entry[0], ""))
			if stat.begins_with("stat_"):
				context.conditional.append({"stat": stat.trim_prefix("stat_"), "value": entry[1], "when": when})
			elif stat == "percent_materials":
				context.gold_ticks.append({"moving": when == "temp_stats_while_moving", "percent": entry[1], "cap": entry[2]})
	context.link_sources = {"structure": run.get_nb_structures(player), "pet": context.pets, "knockback": effect("knockback"), "fossil_count": effect("fossil_count"), "different_item": run.get_nb_different_items_of_tier(-1, player), "common_item": run.get_nb_different_items_of_tier(0, player), "legendary_item": run.get_nb_different_items_of_tier(3, player), "duplicate_item": run.get_duplicate_items_count(player)}
	context.item_counts = {}
	context.link_sources.item_bait = run.get_nb_item(keys.item_bait_hash, player)
	context.unique_weapon_stats = {}
	context.weapon_count_stats = []
	for rule in ["additional_weapon_effects", "tier_i_weapon_effects", "tier_iv_weapon_effects"]:
		for entry in effects.get(keys.generate_hash(rule), []):
			context.weapon_count_stats.append({"stat": str(keys.hash_to_string.get(entry[0], "")).trim_prefix("stat_"), "value": entry[1], "tier": 0 if rule == "tier_i_weapon_effects" else (3 if rule == "tier_iv_weapon_effects" else -1)})
	for entry in effects.get(keys.generate_hash("unique_weapon_effects"), []):
		var stat = str(keys.hash_to_string.get(entry[0], "")).trim_prefix("stat_")
		context.unique_weapon_stats[stat] = context.unique_weapon_stats.get(stat, 0.0) + entry[1]
	context.damage_ramps = []
	for ramp in effects.get(keys.generate_hash("temp_stats_per_interval"), []):
		if keys.hash_to_string.get(ramp[0], "") == "stat_percent_damage" and not ramp[3]:
			context.damage_ramps.append({"value": ramp[1], "interval": ramp[2]})
	context.explosion_damage = effect("explosion_damage")
	context.explosion_size = effect("explosion_size")
	var minimums = effects.get(keys.generate_hash("minimum_weapon_cooldowns"), [])
	context.minimum_cooldown = minimums.back() if not minimums.empty() else 0
	context.burn_time = max(0.1, 0.5 * (1.0 + (effect("burning_cooldown_increase") - effect("burning_cooldown_reduction")) / 100.0))
	var global_burn = effects.get(keys.generate_hash("burn_chance"))
	context.global_burn = _burn_profile(global_burn) if global_burn != null else {}
	context.structure_speed = service.get_structure_attack_speed(player)
	context.structure_speed_scaling = {}
	for entry in effects.get(keys.generate_hash("structures_cooldown_reduction"), []):
		var stat = str(keys.hash_to_string.get(entry[0], "")).trim_prefix("stat_")
		context.structure_speed_scaling[stat] = context.structure_speed_scaling.get(stat, 0.0) + entry[1] / 100.0
	context.item_structure = 0.0
	context.item_structure_scaling = 0.0
	context.structure_components = []
	context.support_structures = []
	context.wave_growth = {}
	for entry in effects.get(keys.generate_hash("stats_end_of_wave"), []):
		var stat = str(keys.hash_to_string.get(entry[0], "")).trim_prefix("stat_")
		context.wave_growth[stat] = context.wave_growth.get(stat, 0.0) + entry[1]
	context.regen_conditions = []
	for entry in effects.get(keys.generate_hash("hp_regen_bonus"), []):
		context.regen_conditions.append({"multiplier": entry[0], "below": entry[1]})
	context.survival_effects = {}
	for name in ["consumable_heal", "hit_protection", "hp_start_wave", "torture", "lose_hp_per_second"]:
		context.survival_effects[name] = effect(name, 100 if name == "hp_start_wave" else 0)
	var dodge_heal = 0.0
	for entry in effects.get(keys.generate_hash("heal_on_dodge"), []):
		dodge_heal += entry[1] * entry[2] / 100.0
	context.survival_effects.heal_on_dodge = dodge_heal
	context.full_health_growth = []
	for entry in effects.get(keys.generate_hash("consumable_stats_while_max"), []):
		var stat = str(keys.hash_to_string.get(entry[0], ""))
		if stat.begins_with("stat_") or stat == "explosion_damage":
			context.full_health_growth.append({"stat": stat.trim_prefix("stat_"), "value": entry[1], "cap": entry[2] if entry.size() > 2 else INF})
	for entry in effects.get(keys.generate_hash("temp_consumable_stats_while_max"), []):
		if entry[0] == keys.stat_hp_regeneration_hash:
			context.survival_effects.full_health_regen = context.survival_effects.get("full_health_regen", 0.0) + entry[1]
	for owned in run.get_player_items(player):
		var payload = describe_item(owned)
		if payload.has("ice_mark"):
			context.ice_mark = payload.ice_mark
		context.item_counts[owned.my_id] = context.item_counts.get(owned.my_id, 0) + 1
		context.item_structure += payload.get("structure", 0.0)
		context.item_structure_scaling += payload.get("structure_scaling", 0.0)
		context.structure_components.append_array(payload.get("structure_components", []))
		context.support_structures.append_array(payload.get("support_structures", []))
		for name in ["pet_heal_boost", "pet_control", "pet_pickup", "pet_double", "slow_step", "slow_limit", "slow_time", "wandering_bots"]:
			context.secondary[name] = context.secondary.get(name, 0.0) + payload.bonuses.get(name, 0.0)
		context.survival_effects.regen_ramp = context.survival_effects.get("regen_ramp", 0.0) + payload.bonuses.get("regen_ramp", 0.0)
	for stat in stats:
		context.stat_labels[stat] = tr("STAT_" + stat.to_upper())
	if shop != null and shop.has_method("_get_reroll_button"):
		context.reroll_price = shop._reroll_price[player]
		context.next_reroll_price = shop._get_reroll_price_after(shop._paid_reroll_count[player] + 1, player)
		context.reroll_count = shop._reroll_count[player]
		context.fresh_slots = items.NB_SHOP_ITEMS - run.get_player_locked_shop_items(player).size()
		context.free_refresh = _free_refresh_profile(shop)
	else:
		context.free_refresh = _free_refresh_profile(null)
	context.coverage = Coverage.inspect(character, context)
	return context


func _transaction_effect(effects: Dictionary, rule: String) -> Dictionary:
	var entries = effects.get(keys.generate_hash(rule), [])
	if entries.empty():
		return {}
	var entry = entries[0]
	var source = run.get_player_item(entry[0], player)
	if source == null or source.effects.size() != 1 or entries.size() > 1 and rule == "duplicate_item":
		return {"manual": true}
	var unit = source.effects[0]
	if unit.custom_key != rule or unit.key_hash != entry[0] or unit.value <= 0:
		return {"manual": true}
	if rule == "duplicate_item" and (unit.value != 1 or entry[1] != run.get_nb_item(entry[0], player)):
		return {"manual": true}
	for held in run.get_player_items(player):
		if held.my_id_hash == entry[0] and (held.effects.size() != 1 or held.effects[0].value != unit.value):
			return {"manual": true}
	return {"id": source.my_id, "tier": source.tier, "value": entry[1], "count": run.get_nb_item(entry[0], player)}


func _event_explosion(effect, trigger: String) -> Dictionary:
	var args = _Args.new()
	args.effects = [load("res://effects/weapons/exploding_effect.gd").new()]
	var stats = service.init_base_stats(effect.stats, player, args)
	var type = 0 if effect.stats is MeleeWeaponStats else (1 if effect.stats is RangedWeaponStats else -1)
	return {"trigger": trigger, "model": _damage_model(effect.stats, stats, args, type),
		"chance": effect.chance, "scale": effect.scale, "missing_health": effect.scale_with_missing_health}


func _projectile_event(trigger: String, base, count: int, aimed: bool, cooldown: float) -> Dictionary:
	var args = _Args.new()
	var stats = service.init_ranged_stats(base, player, true, args)
	var model = _damage_model(base, stats, args, 1)
	model.projectile_chain = _projectile_chain(base, stats)
	return {"trigger": trigger, "count": count, "model": model, "aimed": aimed, "reach": stats.max_range, "cooldown": cooldown}


func _conversion(conversion) -> Dictionary:
	return {"from_stat": str(keys.hash_to_string.get(conversion.key_hash, "")).trim_prefix("stat_"),
		"to_stat": str(keys.hash_to_string.get(conversion.to_stat_hash, "")).trim_prefix("stat_"),
		"portion": conversion.pct_converted / 100.0, "cost": conversion.value, "reward": conversion.to_value}


func _burst_reference(next_wave: int) -> Dictionary:
	if effect("materials_as_health") > 0 or next_wave > run.nb_of_waves:
		return {}
	var wave = run.nb_of_waves if run.nb_of_waves <= next_wave + 1 else 0
	var elite_id = 0
	for spawn in run.elites_spawn:
		if spawn[1] == 0 and spawn[0] >= next_wave and spawn[0] <= next_wave + 1 and (wave == 0 or spawn[0] < wave):
			wave = spawn[0]
			elite_id = spawn[2]
	if wave == 0:
		return {}
	var zones = run.get_node("/root/ZoneService")
	var enemies = zones.get_elites_from_zone(run.current_zone) if elite_id != 0 else zones.get_bosses_from_zone(run.current_zone)
	var selected = []
	for enemy in enemies:
		if (elite_id != 0 and keys.generate_hash(enemy.my_id) == elite_id) or (elite_id == 0 and enemy.my_id in run.bosses_spawn):
			selected.append(enemy)
	if selected.empty():
		selected = enemies
	var base_hit = 0.0
	for enemy in selected:
		base_hit = max(base_hit, _contact_damage(enemy.scene, wave))
	if base_hit <= 0.0:
		return {}
	# 正常通关波次的单人倍率，与原生伤害初始化一致，不写入游戏的敌人缓存。
	var base_damage = base_hit * max(0.01, 1.0 + effect("danger_enemy_damage") / 100.0) * run.current_run_accessibility_settings.damage
	var enemy_factor = max(0.01, 1.0 + utils.get_stat(keys.enemy_damage_hash, player) / 100.0)
	return {"wave": wave, "next": wave == next_wave, "base_damage": base_damage, "damage": max(1, int(round(base_damage * enemy_factor)))}


func _pressure_reference(zone, wave, threat: String) -> Dictionary:
	if wave == null:
		return {}
	var total = 0.0
	var weight = 0.0
	var peak = 0.0
	var next = run.get_next_wave()
	# 用有效生成组的数量、概率估计代表接触伤害；不把它当作实测遭遇分布。
	for group in zone.groups_data_in_all_waves + wave.groups_data:
		if group.is_neutral or group.spawn_timing >= _wave_seconds or run.current_difficulty < group.min_difficulty or run.current_difficulty > group.max_difficulty or next < group.min_wave or next > group.max_wave:
			continue
		if (threat == "elite" and group.prevent_if_elite) or (threat == "horde" and group.prevent_if_horde):
			continue
		for unit in group.wave_units_data:
			if unit.type != EntityType.ENEMY or unit.unit_scene == null:
				continue
			var amount = group.spawn_chance * unit.spawn_chance * (unit.min_number + unit.max_number) / 2.0
			var damage = _contact_damage(unit.unit_scene, next)
			if amount > 0.0 and damage > 0.0:
				total += damage * amount
				weight += amount
				peak = max(peak, damage)
	if weight <= 0.0:
		return {}
	var factor = max(0.01, 1.0 + effect("danger_enemy_damage") / 100.0) * run.current_run_accessibility_settings.damage
	return {"mean": total / weight * factor, "peak": peak * factor}


func _contact_damage(scene: PackedScene, wave: int) -> float:
	var stats = _scene_stats(scene)
	return stats.get_base_damage(wave) if stats != null else 0.0


func _scene_stats(scene: PackedScene):
	if scene == null:
		return null
	var state = scene.get_state()
	for i in range(state.get_node_property_count(0)):
		if state.get_node_property_name(0, i) == "stats":
			var stats = state.get_node_property_value(0, i)
			if stats != null:
				return stats
	return _scene_stats(state.get_node_instance(0))


func _pricing(source, wave: int, markup: int = 0) -> Dictionary:
	var specific = 0.0
	for entry in run.get_player_effects(player).get(keys.generate_hash("specific_items_price"), []):
		if keys.hash_to_string.get(entry[0], "") in source.my_id:
			specific = entry[1]
			break
	var inflation = effect("inflation_modifier")
	return {"base": source.value, "wave": wave, "weapon": source.has_method("get_weapon_id_hash"), "specific": specific, "inflation": (1.0 + inflation / 100.0) / 10.0 if inflation > 0 else 0.1, "endless": run.get_endless_factor(wave) / 5.0, "markup": markup}


func _free_refresh_profile(shop) -> Dictionary:
	var owned = int(effect("free_rerolls"))
	var fees = []
	for wave in range(run.current_wave, run.nb_of_waves):
		var paid = shop._paid_reroll_count[player] if shop != null and wave == run.current_wave else 0
		var price = items.get_reroll_price(wave, paid, player)
		fees.append(price[0] + price[1])
	return {"fees": fees, "owned": owned, "available": shop._free_rerolls[player] if shop != null else owned, "empty_bonus": shop != null and shop._has_bonus_free_reroll[player]}


func _tree_profile(zone, wave, threat: String) -> Dictionary:
	if wave == null:
		return {}
	var base = 0.0
	var per_bonus = 0.0
	var tree_stats = null
	for group in zone.groups_data_in_all_waves + wave.groups_data:
		if not group.is_neutral or run.current_difficulty < group.min_difficulty or run.current_difficulty > group.max_difficulty:
			continue
		if (threat == "elite" and group.prevent_if_elite) or (threat == "horde" and group.prevent_if_horde):
			continue
		var batches = group.spawn_chance if group.spawn_timing < _wave_seconds or effect("trees_start_wave") > 0 else 0.0
		var interval = group.repeating_interval
		var timing = group.spawn_timing + interval
		for _i in range(group.repeating):
			if timing >= _wave_seconds:
				break
			batches += 1.0
			interval = max(group.min_repeating_interval, interval - group.reduce_repeating_interval)
			timing += interval
		for unit in group.wave_units_data:
			if unit.type != EntityType.NEUTRAL or unit.unit_scene == null or not unit.unit_scene.resource_path.get_file() in ["tree.tscn", "tree_jungle.tscn"]:
				continue
			if tree_stats == null:
				tree_stats = _scene_stats(unit.unit_scene)
			var spawned = batches * unit.spawn_chance
			base += spawned * (unit.min_number + unit.max_number) / 2.0
			per_bonus += spawned
	if tree_stats == null:
		return {}
	var materials = tree_stats.value * max(0.5, 1.0 + (effect("gold_drops") + effect("neutral_gold_drops")) / 100.0)
	var crate_chance = tree_stats.item_drop_chance * max(0.0, 1.0 + effect("crate_chance") / 100.0)
	# 用一件低价道具的原生回收价估计未知箱内物品的收益。
	var crate_value = items.get_item_box_recycling_value(run.get_next_wave(), 15, player)
	return {"base": base, "per_bonus": per_bonus, "owned": effect("trees"), "materials": materials, "preserve_value": effect("cryptid"), "food_chance": tree_stats.base_drop_chance, "crate_chance": crate_chance, "crate_value": crate_value}


func _tier_probabilities(wave: int, luck: float) -> Dictionary:
	var higher = 0.0
	var probabilities = {}
	for tier in range(items._tiers_data.size() - 1, -1, -1):
		var data = items._tiers_data[tier]
		var wave_bonus = max(0.0, (wave - 1 - data[5]) * data[7])
		wave_bonus *= (1.0 + luck) if luck >= 0 else 1.0 / (1.0 + abs(luck))
		var threshold = clamp(data[6] + wave_bonus, 0.0, data[8])
		probabilities[tier] = max(0.0, threshold - higher)
		higher = max(higher, threshold)
	return probabilities


func upgrade_reroll_pool(level: int, current: Array, context: Dictionary) -> Dictionary:
	var probabilities = _tier_probabilities(level, context.stats.get("luck", 0.0) / 100.0)
	if level == 5:
		probabilities = {1: 1.0}
	elif level in [10, 15, 20]:
		probabilities = {2: 1.0}
	elif level % 5 == 0:
		probabilities = {3: 1.0}
	var excluded = []
	for card in current:
		excluded.append(card.upgrade_id)
	var character = run.get_player_character(player)
	if character != null and context.wave < context.final_wave:
		excluded.append_array(character.banned_upgrades)
	var modification = 1.0 + effect("level_upgrades_modifications") / 100.0
	var groups = {}
	for tier in probabilities:
		if probabilities[tier] <= 0.0:
			continue
		var pool = items.get_pool(tier, items.TierData.UPGRADES)
		if pool.empty():
			return {}
		for upgrade in pool:
			if upgrade.upgrade_id in excluded:
				continue
			var stats = effect_stats(upgrade.effects)
			for stat in stats:
				stats[stat] = int(stats[stat] * modification)
			if not groups.has(upgrade.upgrade_id):
				groups[upgrade.upgrade_id] = []
			groups[upgrade.upgrade_id].append({"stats": stats, "weight": probabilities[tier] / pool.size()})
	return groups


func reroll_catalogue(shop, context: Dictionary) -> Array:
	# 读取当前版本已解锁池和概率，不调用抽样函数，也不查看下一次随机结果。
	var result = []
	var by_id = {}
	var excluded = {}
	context.shop_distribution = shop_distribution(context)
	var probabilities = context.shop_distribution.tiers
	if not context.get("future_shop", false):
		for slot in shop._get_shop_items_container(player)._shop_items:
			if slot.active:
				excluded[slot.item_data.my_id] = true
	# 锁定/解除建议由控制器在调用前写入快照，按实际将刷新的货位计保底。
	var locked_slots = {}
	for offer in context.offers:
		if offer.get("locked", false) and offer.get("kind", "weapon") == "weapon" and not locked_slots.has(offer.index):
			context.shop_distribution.locked_weapons += 1
			locked_slots[offer.index] = true
	var weapon_chance = items.CHANCE_WEAPON
	if context.wave <= items.MAX_WAVE_TWO_WEAPONS_GUARANTEED:
		weapon_chance = max(weapon_chance, 2.0 / items.NB_SHOP_ITEMS)
	elif context.wave <= items.MAX_WAVE_ONE_WEAPON_GUARANTEED:
		weapon_chance = max(weapon_chance, 1.0 / items.NB_SHOP_ITEMS)
	if context.rules.slots <= 0 or effect("effect_no_weapon_in_shop") > 0:
		weapon_chance = 0.0
	for type in [1, 2]:
		for tier in probabilities:
			var adjusted = int(clamp(tier, context.rules.min_tier, context.rules.max_tier)) if type == 2 else tier
			var pool = items.get_pool(adjusted, type)
			var backup = pool.duplicate()
			items.update_pools(pool, backup, player, adjusted, type)
			var eligible = []
			for source in pool:
				if not excluded.has(source.my_id) and _pool_allowed(source, type, context):
					eligible.append(source)
			if eligible.empty():
				continue
			var weights = _pool_weights(eligible, type, context)
			var total = 0.0
			for weight in weights:
				total += weight
			for i in range(eligible.size()):
				var source = eligible[i]
				var price = items.get_value(context.wave, source.value, player, true, type == 2, source.my_id_hash)
				if context.hp_shop:
					price = int(ceil(price / 20.0))
				var weight = probabilities[tier] * (weapon_chance if type == 2 else 1.0 - weapon_chance) * weights[i] / total
				var row = {"index": -1, "id": source.my_id, "tier": adjusted, "price": price, "weight": weight, "kind": "weapon" if type == 2 else "item",
					"source": source, "pricing": _pricing(source, context.wave)}
				var flags = _pool_flags(source, type, context)
				for key in flags:
					row[key] = flags[key]
				# 品质被职业上下限夹住时，同一池只保留一份。
				if by_id.has(row.id):
					by_id[row.id].weight += row.weight
				else:
					result.append(row)
					by_id[row.id] = row
	for entry in run.get_player_effects(player).get(keys.generate_hash("guaranteed_shop_items"), []):
		var source = items.get_element(items.get_items(), entry[0])
		if source == null:
			continue
		context.shop_distribution.fixed.append(source.my_id)
		var price = items.get_value(context.wave, source.value, player, true, false, source.my_id_hash)
		result.append({"index": -1, "id": source.my_id, "tier": source.tier, "fixed": true, "price": int(ceil(price / 20.0)) if context.hp_shop else price,
			"weight": 1.0, "kind": "item", "source": source, "pricing": _pricing(source, context.wave)})
	return result


func shop_distribution(context: Dictionary) -> Dictionary:
	var families = {}
	for held in context.weapons:
		families[held.family] = true
	var early = max(0, items.MAX_WAVE_ONE_WEAPON_GUARANTEED + 1 - context.wave) / float(items.MAX_WAVE_ONE_WEAPON_GUARANTEED)
	var unique_count = min(families.size(), items.MAX_UNIQUE_WEAPONS_FOR_SHOP_BONUS)
	var minimum = 2 if context.wave <= items.MAX_WAVE_TWO_WEAPONS_GUARANTEED else (1 if context.wave <= items.MAX_WAVE_ONE_WEAPON_GUARANTEED else 0)
	var tiers = _tier_probabilities(context.wave, context.stats.get("luck", 0.0) / 100.0)
	if not context.get("future_shop", false):
		var shift = context.get("refresh_tier", {}).get("value", 0)
		if shift != 0:
			var shifted = {}
			for tier in tiers:
				var target = int(clamp(tier + shift, 0, 3))
				shifted[target] = shifted.get(target, 0.0) + tiers[tier]
			tiers = shifted
	return {"minimum": max(minimum, effect("minimum_weapons_in_shop")), "locked_weapons": 0,
		"exact": context.wave <= items.MAX_WAVE_TWO_WEAPONS_GUARANTEED, "no_weapons": context.rules.slots <= 0 or effect("effect_no_weapon_in_shop") > 0,
		"weapon_chance": items.CHANCE_WEAPON, "tiers": tiers, "fixed": [],
		"own_chance": items.CHANCE_SAME_WEAPON + early * items.BONUS_CHANCE_SAME_WEAPON + unique_count * items.CHANCE_SAME_WEAPON_PER_UNIQUE_WEAPON,
		"set_chance": items.CHANCE_SAME_WEAPON_SET + early * items.BONUS_CHANCE_SAME_WEAPON_SET + unique_count * items.CHANCE_SAME_WEAPON_SET_PER_UNIQUE_WEAPON,
		"wanted_chance": items.BOOSTED_WANTED_ITEM_TAG if effect("stat_boosted_wanted_item_tag") > 0 else items.CHANCE_WANTED_ITEM_TAG}


func _pool_flags(source, type: int, context: Dictionary) -> Dictionary:
	var owned = false
	var same_set = false
	if type == 2:
		for held in context.weapons:
			owned = owned or held.family == source.weapon_id
			for set in source.sets:
				same_set = same_set or set.my_id in held.sets
	return {"owned": owned, "same_set": same_set and not owned, "wanted": type == 1 and items.shares_tag(source, run.get_player_character(player).wanted_tags)}


func describe_reroll_offer(offer: Dictionary) -> Dictionary:
	var probe = offer.duplicate()
	if probe.kind == "weapon":
		probe.weapon = describe(probe.source)
	else:
		probe.item = describe_item(probe.source)
		probe.blocked = probe.item.blocked
	return probe


func _pool_weights(pool: Array, type: int, context: Dictionary) -> Array:
	var result = []
	var owned = []
	var same_set = []
	var wanted = []
	var families = {}
	var sets = {}
	for held in context.weapons:
		families[held.family] = true
		for set_id in held.sets:
			sets[set_id] = true
	for source in pool:
		var is_owned = type == 2 and families.has(source.weapon_id)
		var is_set = false
		if type == 2:
			for set in source.sets:
				is_set = is_set or sets.has(set.my_id)
		owned.append(is_owned)
		same_set.append(is_set and not is_owned)
		wanted.append(type == 1 and items.shares_tag(source, run.get_player_character(player).wanted_tags))
	var early = max(0, items.MAX_WAVE_ONE_WEAPON_GUARANTEED + 1 - context.wave) / float(items.MAX_WAVE_ONE_WEAPON_GUARANTEED)
	var unique_count = min(families.size(), items.MAX_UNIQUE_WEAPONS_FOR_SHOP_BONUS)
	var own_chance = items.CHANCE_SAME_WEAPON + early * items.BONUS_CHANCE_SAME_WEAPON + unique_count * items.CHANCE_SAME_WEAPON_PER_UNIQUE_WEAPON
	var set_chance = max(own_chance, items.CHANCE_SAME_WEAPON_SET + early * items.BONUS_CHANCE_SAME_WEAPON_SET + unique_count * items.CHANCE_SAME_WEAPON_SET_PER_UNIQUE_WEAPON)
	var wanted_chance = items.BOOSTED_WANTED_ITEM_TAG if effect("stat_boosted_wanted_item_tag") > 0 else items.CHANCE_WANTED_ITEM_TAG
	var owned_count = owned.count(true)
	var other_count = pool.size() - owned_count
	var set_count = same_set.count(true)
	var wanted_count = wanted.count(true)
	for i in range(pool.size()):
		var weight = 0.0
		if type == 2:
			weight += own_chance / owned_count if owned[i] else 0.0
			weight += (set_chance - own_chance) / set_count if same_set[i] else 0.0
			weight += (1.0 - set_chance) / other_count if not owned[i] else 0.0
			weight += ((own_chance if owned_count == 0 else 0.0) + (set_chance - own_chance if set_count == 0 else 0.0) + (1.0 - set_chance if other_count == 0 else 0.0)) / pool.size()
		else:
			weight = (1.0 - wanted_chance) / pool.size()
			weight += wanted_chance / wanted_count if wanted[i] else (wanted_chance / pool.size() if wanted_count == 0 else 0.0)
		result.append(weight)
	return result


func _pool_allowed(source, type: int, context: Dictionary) -> bool:
	var banned = run.players_data[player].banned_items
	if source.my_id in banned or source.my_id_hash in banned:
		return false
	if type == 2:
		if (source.type == 0 and context.rules.no_melee) or (source.type == 1 and context.rules.no_ranged):
			return false
		if context.rules.unique:
			for held in context.weapons:
				if held.family == source.weapon_id and (source.tier < held.tier or (source.my_id == held.id and source.upgrades_into == null)):
					return false
		if keys.generate_hash("structure") in run.get_player_effects(player).get(keys.generate_hash("remove_shop_items"), []) and run.get_node("/root/EntityService").is_weapon_spawning_structure(source):
			return false
		return true
	if source.max_nb >= 0 and run.get_remaining_max_nb_item(source, player) <= _projected_count(source, context):
		return false
	var character = run.get_player_character(player)
	if source.my_id in character.banned_items:
		return false
	for group in character.banned_item_groups:
		if items.item_groups.has(group) and source.my_id in items.item_groups[group]:
			return false
	for tag in run.get_player_effects(player).get(keys.generate_hash("remove_shop_items"), []):
		if keys.hash_to_string.get(tag, "") in source.tags:
			return false
	return true


func _projected_count(source, context: Dictionary) -> int:
	var counts = context.get("new_item_counts", {})
	var count = counts.get(source.my_id, 0)
	if not counts.empty():
		for descendant in items.get_limited_item_descendants(source.my_id_hash):
			count += counts.get(keys.hash_to_string.get(descendant, ""), 0)
	return count


func describe_item(source) -> Dictionary:
	var payload = {"id": source.my_id, "name": source.get_name_text(), "tier": source.tier, "stats": {}, "bonuses": {}, "overrides": {}, "caps": {}, "stat_factors": {}, "level_growth": {}, "unique_weapon_stats": {}, "conditional": [], "damage_ramps": [], "wave_growth": {}, "links": [], "regen_conditions": [], "structure": 0.0, "structure_scaling": 0.0, "structure_components": [], "remaining": run.get_remaining_max_nb_item(source, player), "unmeasured": [], "blocked": ""}
	if source.max_nb >= 0:
		payload.limited_descendants = []
		for descendant in items.get_limited_item_descendants(source.my_id_hash):
			payload.limited_descendants.append(keys.hash_to_string.get(descendant, ""))
	for e in source.effects:
		if e.get_id() == "percent_damage" and e.source_id == "item_ice_cube" and e.custom_key == "enemy_percent_damage_taken" and e.max_procs == 1 and e.max_stacks == 1:
			payload.ice_mark = {"stat": e.key.trim_prefix("stat_"), "percent": e.value, "duration": e.duration_secs, "chance": e.chance / 100.0}
			continue
		if e.get_id() == "convert_stat" and e.custom_key == "convert_stats_end_of_wave" and e.value > 0:
			if not payload.has("conversions"):
				payload.conversions = []
			payload.conversions.append(_conversion(e))
			continue
		if e.get_id() == "effect" and e.key == "":
			continue
		if e.get_id() == "effect" and e.key == "tree_turrets" and e.value > 0:
			var turret = items.get_item_from_id(keys.generate_hash("item_turret"))
			var component = _structure_output(turret.effects[0]).component
			component.tree_turret = true
			component.rate *= e.value
			payload.structure_components.append(component)
			continue
		if e.get_id() == "effect" and e.storage_method == 1 and e.custom_key == "consumable_stats_while_max" and (e.key.begins_with("stat_") or e.key == "explosion_damage"):
			if not payload.has("full_health_growth"):
				payload.full_health_growth = []
			payload.full_health_growth.append({"stat": e.key.trim_prefix("stat_"), "value": e.value, "cap": INF})
			continue
		if e.get_id() == "effect" and e.storage_method == 1:
			if e.custom_key in ["additional_weapon_effects", "tier_i_weapon_effects", "tier_iv_weapon_effects"] and e.key.begins_with("stat_"):
				if not payload.has("weapon_count_stats"):
					payload.weapon_count_stats = []
				payload.weapon_count_stats.append({"stat": e.key.trim_prefix("stat_"), "value": e.value, "tier": 0 if e.custom_key == "tier_i_weapon_effects" else (3 if e.custom_key == "tier_iv_weapon_effects" else -1)})
				continue
			if e.custom_key in ["gold_on_crit_kill", "extra_item_in_crate"]:
				payload.bonuses[e.custom_key] = payload.bonuses.get(e.custom_key, 0.0) + e.value
				continue
			if e.key.begins_with("stat_"):
				var stat = e.key.trim_prefix("stat_")
				if e.custom_key in ["structures_cooldown_reduction", "weapon_scaling_stats"]:
					var bonus = ("structure_scaling_" if e.custom_key == "structures_cooldown_reduction" else "weapon_scaling_") + stat
					payload.bonuses[bonus] = payload.bonuses.get(bonus, 0.0) + e.value / 100.0
					continue
				if e.custom_key == "stats_on_level_up":
					payload.level_growth[stat] = payload.level_growth.get(stat, 0.0) + e.value
					continue
				if e.custom_key == "unique_weapon_effects":
					payload.unique_weapon_stats[stat] = payload.unique_weapon_stats.get(stat, 0.0) + e.value
					continue
				if e.custom_key in ["temp_stats_while_not_moving", "temp_stats_while_moving", "stats_below_half_health", "temp_stats_on_hit", "temp_stats_on_dodge"]:
					payload.conditional.append({"stat": stat, "value": e.value, "when": e.custom_key})
					continue
				if stat == "hp_regeneration" and e.custom_key == "temp_consumable_stats_while_max":
					payload.bonuses.full_health_regen = payload.bonuses.get("full_health_regen", 0.0) + e.value
					continue
		if e.get_id() == "double_value" and e.storage_method == 1 and e.key == "stat_max_hp" and e.custom_key == "consumable_stats_while_max" and e.value > 0 and e.value2 > 0:
			if not payload.has("full_health_growth"):
				payload.full_health_growth = []
			payload.full_health_growth.append({"stat": "max_hp", "value": e.value, "cap": e.value2})
			continue
		if e.get_id() == "effect" and e.storage_method == 2 and e.key in REPLACE_EFFECTS:
			payload.overrides[e.key] = e.value
			continue
		if e.get_id() == "stat_cap" and e.key in ["hp_cap", "speed_cap"]:
			payload.caps[e.key] = {"stat": e.set_cap_to_current_stat.trim_prefix("stat_"), "value": e.value}
			payload.blocked = "永久限制属性成长，本店跳过"
			continue
		if e.get_id() == "multiply_value" and e.key == "stat_evolution":
			payload.stat_factors.evolution = payload.stat_factors.get("evolution", 1.0) * e.value
			payload.stats.evolution = payload.stats.get("evolution", 0.0) * e.value
			continue
		if e.get_id() == "extra_enemy" and e.key == "extra_enemies_next_wave" and e.extra_group_data == WaveProfile.BAIT_GROUP:
			payload.bonuses.bait_groups = payload.bonuses.get("bait_groups", 0) + e.value
			continue
		if e.get_id() == "weapon_cooldown" and e.key == "minimum_weapon_cooldowns":
			payload.overrides.cooldown_floor = e.value
			continue
		if e.get_id() == "burn_chance" and e.burning_data != null:
			payload.burn = _burn_profile(e.burning_data)
			continue
		if e.get_id() == "double_value" and e.key == "remove_speed":
			payload.bonuses.slow_step = e.value
			payload.bonuses.slow_limit = e.value2
			continue
		if e.get_id() == "slow_time_when_below_hp":
			payload.bonuses.slow_time = e.value / 100.0 * e.duration_secs
			continue
		if e is PetEffect and _describe_pet(e, payload):
			continue
		if e.get_id() == "effect" and e.storage_method == 1 and e.custom_key == "stats_next_wave" and e.key in WAVE_MODIFIERS:
			var bonus = "next_" + e.key
			payload.bonuses[bonus] = payload.bonuses.get(bonus, 0.0) + e.value
			continue
		if e.get_id() == "effect" and e.storage_method == 1 and e.custom_key == "stats_end_of_wave" and (e.key.begins_with("stat_") or e.key == "xp_gain"):
			var stat = e.key.trim_prefix("stat_")
			payload.wave_growth[stat] = payload.wave_growth.get(stat, 0.0) + e.value
			continue
		if e.get_id() == "double_value" and e.key == "hp_regen_bonus" and e.storage_method == 0 and e.sum_strategy == 1:
			payload.regen_conditions.append({"multiplier": e.value, "below": e.value2})
			continue
		if e.get_id() == "gain_stat_for_every_stat" and (e.key.begins_with("stat_") or e.key in ["xp_gain", "explosion_damage", "explosion_size", "structure_attack_speed"]) and (e.stat_scaled.begins_with("stat_") or e.stat_scaled in LINK_SOURCES or e.stat_scaled == "percent_player_missing_health") and e.nb_stat_scaled != 0:
			payload.links.append({"target": e.key.trim_prefix("stat_"), "source": e.stat_scaled.trim_prefix("stat_"), "value": e.value, "per": e.nb_stat_scaled, "permanent": e.perm_stats_only})
			continue
		if e.get_id() == "chance_stat_damage" and e.custom_key == "heal_on_dodge" and e.key == "":
			payload.bonuses.heal_on_dodge = payload.bonuses.get("heal_on_dodge", 0.0) + e.value * e.chance / 100.0
			continue
		if e.get_id() == "chance_stat_damage" and e.custom_key in ["dmg_when_pickup_gold", "dmg_when_heal", "dmg_on_dodge", "dmg_when_death"]:
			if not payload.has("events"):
				payload.events = []
			payload.events.append({"trigger": e.custom_key, "stat": e.key.trim_prefix("stat_"), "ratio": e.value / 100.0, "chance": e.chance / 100.0})
			continue
		if e.get_id() == "projectile" and (e.key == "projectiles_on_death" or (e.key == "alien_eyes" and e.cooldown > 0)) and e.weapon_stats is RangedWeaponStats and e.value > 0:
			if not payload.has("events"):
				payload.events = []
			payload.events.append(_projectile_event(e.key, e.weapon_stats, e.value, e.auto_target_enemy, e.cooldown))
			continue
		if e.get_id() == "item_exploding" and e.key in ["explode_on_hit", "explode_on_consumable"] and not e.scale_with_missing_health:
			if not payload.has("events"):
				payload.events = []
			payload.events.append(_event_explosion(e, e.key))
			continue
		if e.get_id() == "temp_stats_per_interval" and e.key == "stat_hp_regeneration" and not e.reset_on_hit and e.interval > 0:
			payload.bonuses.regen_ramp = payload.bonuses.get("regen_ramp", 0.0) + e.value * _wave_seconds / (2.0 * e.interval)
			continue
		if e.get_id() == "temp_stats_per_interval" and e.key == "stat_percent_damage" and not e.reset_on_hit and e.interval > 0:
			payload.damage_ramps.append({"value": e.value, "interval": e.interval})
			continue
		if e.get_id() == "turret" and e.stats != null and e.stats.is_healing and e.effects.empty():
			payload.bonuses.structure_count = payload.bonuses.get("structure_count", 0) + 1
			var structure_args = _Args.new()
			structure_args.effects = e.effects
			var structure = service.init_structure_stats(e.stats, player, structure_args)
			var garden = e.scene.resource_path == "res://entities/structures/turret/garden/garden.tscn"
			if not payload.has("support_structures"):
				payload.support_structures = []
			payload.support_structures.append({"frames": structure.cooldown, "amount": e.value if garden else e.value * max(0, structure.damage), "garden": garden, "heal_amount": max(1.0, structure.damage)})
			continue
		if e.get_id() == "turret" and e.key == "wandering_bot":
			payload.bonuses.wandering_bots = payload.bonuses.get("wandering_bots", 0.0) + e.value
			payload.bonuses.structure_count = payload.bonuses.get("structure_count", 0) + 1
			continue
		# 普通射击炮塔和一次性地雷与武器建筑共用同一估值；特殊攻击效果仍须单独适配。
		if e.get_id() in ["structure", "turret"] and e.stats != null and not e.stats.is_healing and (e.effects.empty() or (e.scene != null and e.scene.resource_path == "res://entities/structures/landmine/landmine.tscn")):
			payload.bonuses.structure_count = payload.bonuses.get("structure_count", 0) + 1
			var output = _structure_output(e)
			payload.structure += output.damage
			payload.structure_scaling += output.scaling
			payload.structure_components.append(output.component)
			continue
		if e.get_id() in ["effect", "modular"] and e.storage_method == 0:
			if e.key.begins_with("stat_") and _numeric(e.value):
				var stat = e.key.trim_prefix("stat_")
				payload.stats[stat] = payload.stats.get(stat, 0.0) + e.get_applied_value(player)
				continue
			if e.key in ITEM_BONUSES or e.key in SECONDARY_EFFECTS:
				payload.bonuses[e.key] = payload.bonuses.get(e.key, 0.0) + e.value
				continue
		if payload.unmeasured.empty():
			payload.first_unmeasured_effect = source.effects.find(e) + 1
		payload.unmeasured.append(_effect_evidence(e))
	if not payload.unmeasured.empty():
		payload.blocked = "特殊效果尚未估值，本店跳过"
	if payload.remaining <= 0:
		payload.blocked = "已达到道具持有上限"
	return payload


func _effect_evidence(e) -> String:
	var label = e.key if e.key != "" else e.custom_key
	var params = [str(e.value)]
	for name in ["value2", "chance", "interval", "duration", "duration_secs", "hp_threshold", "nb_stat_scaled"]:
		if _has_property(e, name):
			params.append("%s=%s" % [name, str(e.get(name))])
	for arg in e.get_args_tool():
		var value = str(arg)
		if value != "" and not value in params:
			params.append(value)
	return "%s(%s) [%s]" % [e.get_id(), label, PoolStringArray(params).join("，")]


func crate_offers(source) -> Array:
	var variants = [{"data": source, "choice": -1, "choice_text": ""}]
	var options = []
	for e in source.effects:
		if e.get_id() == "effect_option":
			options.append(e)
	if source.is_meca and options.size() == 2:
		variants.clear()
		for choice in range(2):
			variants.append({"data": _DLC2.change_effect_option_to_modular_effect(clone_weapon(source), choice), "choice": choice, "choice_text": tr(options[choice].key.to_upper()) + " +" + str(options[choice].value)})
	var offers = []
	for variant in variants:
		var offer = {"index": 0, "price": 0, "choice": variant.choice, "choice_text": variant.choice_text, "blocked": ""}
		if source.has_method("get_weapon_id_hash"):
			offer.weapon = describe(variant.data)
		else:
			offer.kind = "item"
			offer.item = describe_item(variant.data)
			offer.blocked = offer.item.blocked
			if not offer.item.caps.empty():
				var cap = offer.item.caps.values()[0]
				offer.blocked = "拿取后会永久限制%s" % tr("STAT_" + cap.stat.to_upper())
		var facts = offer.get("item", offer.get("weapon", {}))
		if facts.has("first_unmeasured_effect"):
			var position = facts.first_unmeasured_effect
			var line = variant.data.effects[position - 1].get_text(player, false).strip_edges()
			if line.empty() or "[" in line or line.length() > 80:
				line = "第 %d 项特殊效果" % position
			offer.blocked = "尚未估算「%s」的收益" % line
		offers.append(offer)
	return offers


func effect(name: String, fallback = 0):
	var value = run.get_player_effects(player).get(keys.generate_hash(name), fallback)
	return value if _numeric(value) else fallback


func describe(source) -> Dictionary:
	var cache_key = str(source.get_instance_id())
	if _cache.has(cache_key):
		return _cache[cache_key]
	var args = _Args.new()
	args.sets = source.sets
	args.effects = source.effects
	var current = service.init_melee_stats(source.stats, player, args) if source.type == 0 else service.init_ranged_stats(source.stats, player, false, args)
	var interval = current.get_cooldown_value(player, 1.0)
	if current.additional_cooldown_every_x_shots > 0:
		interval += current.cooldown * (current.additional_cooldown_multiplier - 1.0) / (60.0 * current.additional_cooldown_every_x_shots)
	interval = max(0.03, interval)
	var projectiles = max(1, _prop(current, "nb_projectiles", 1))
	var projectile_spread = _prop(current, "projectile_spread", 0.0)
	var hit_rate = Combat.hit_chance(current.accuracy, min(250.0, current.max_range), 18.0, 2.0, projectile_spread) if source.type == 1 else 1.0
	var dps = _expected_hit(current) / interval
	var boss = dps * projectiles
	var clear = dps * projectiles
	var contact = 1.0
	var melee_targets = 1.0
	if source.type == 0:
		# 短程近战需要接敌并躲避，不能把整波都视作贴身满频攻击；覆盖率属于估计。
		contact = clamp(0.3 + current.max_range / 700.0, 0.35, 0.75)
		boss *= contact
		clear *= contact
		melee_targets = 1.65 if _prop(current, "attack_type", 0) == 1 else 1.25
		if _prop(current, "deal_dmg_on_return", false):
			melee_targets *= 1.35
		clear *= melee_targets
	var facts = {
		"key": cache_key, "id": source.my_id, "family": source.weapon_id, "name": source.get_name_text(), "type": source.type, "tier": source.tier,
		"sets": [], "scaling": _scaling(current.scaling_stats), "damage": current.damage, "damage_multiplier": max(0, 1.0 + utils.get_stat(keys.generate_hash("stat_percent_damage"), player) / 100.0),
		"damage_model": _damage_model(source.stats, current, args, source.type), "damage_components": [],
		"attack_speed_mod": current.attack_speed_mod, "projectile_spread": projectile_spread, "raw_hits_per_second": projectiles / interval * contact,
		"boss": boss, "clear": clear, "reach": current.max_range, "knockback": current.knockback, "healing": 0.0, "lifesteal": current.lifesteal,
		"explosive": false,
		"interval": interval, "cooldown_floor": 0.0,
		"projectile_life": current.max_range / max(1.0, _prop(current, "projectile_speed", 3000)) if source.type == 1 else 0.0,
		"stats": effect_stats(source.effects), "plain": items.get_flavor(source) == 0, "flavor": items.get_flavor(source), "source": source,
		"burn": 0.0, "burn_coverage": 0.0, "structure": 0.0, "structure_scaling": 0.0, "structure_components": [], "unmeasured": [],
		"crit_chance": current.crit_chance, "crit_damage": current.crit_damage, "accuracy": current.accuracy, "contact": contact, "stacks": [], "farm_stats": {}, "control": max(0, -current.speed_percent_modifier) / 15.0, "hits_per_second": projectiles / interval * contact * hit_rate
	}
	var minimums = run.get_player_effects(player).get(keys.generate_hash("minimum_weapon_cooldowns"), [])
	if not minimums.empty():
		facts.cooldown_floor = minimums.back() / 60.0
	if source.type == 1:
		facts.damage_model.projectile_chain = _projectile_chain(source.stats, current)
	var timing = _attack_timing(source, current)
	if not timing.empty():
		facts.attack_timing = timing
	if current.is_healing:
		facts.boss = 0.0
		facts.clear = 0.0
		facts.healing += current.damage / interval
	_cache[cache_key] = facts
	facts.can_sell = effect("burn_weapon_give_primitive_bonus") == 0
	if facts.plain and source.effects.empty():
		facts.trade_key = str([source.my_id, source.stats, source.sets, source.upgrades_into, source.value])
	var price_factor = 1.0
	for special in run.get_player_effects(player).get(keys.generate_hash("specific_items_price"), []):
		if keys.hash_to_string.get(special[0], "") in source.my_id:
			price_factor = special[1]
			break
	facts.refund = items.get_recycling_value(run.current_wave, int(source.value * price_factor), player, true)
	for e in source.effects:
		if "price" in e.key:
			facts.can_sell = false
	for set in source.sets:
		facts.sets.append(set.my_id)
		if not _sets.has(set.my_id):
			var bonuses = []
			for bonus in set.set_bonuses:
				bonuses.append(effect_stats(bonus))
			_sets[set.my_id] = bonuses
	var base_burn = source.stats.burning_data
	for e in source.effects:
		if e.get_id() == "weapon_burning":
			base_burn = e.burning_data
	var burn = current.burning_data
	facts.native_burn = not base_burn.is_not_burning()
	if not burn.is_not_burning():
		var global_burn = run.get_player_effects(player).get(keys.generate_hash("burn_chance"))
		var raw = 0 if base_burn.is_not_burning() else base_burn.damage
		if not base_burn.is_global_burn and global_burn != null:
			raw += global_burn.damage
		facts.burn_model = {"raw": raw + service.sum_scaling_stat_values(burn.scaling_stats, player), "damage": burn.damage, "multiplier": 1.0 + utils.get_stat(keys.generate_hash("stat_percent_damage"), player) / 100.0, "scaling": _scaling(burn.scaling_stats)}
		# 原生燃烧每 0.5 秒结算；同一目标通常只保留最强燃烧，不按武器数量叠加。
		var burn_time = max(0.1, 0.5 * (1.0 + (effect("burning_cooldown_increase") - effect("burning_cooldown_reduction")) / 100.0))
		facts.burn = burn.damage / burn_time * clamp(burn.chance, 0.0, 1.0)
		facts.burn_chance = clamp(burn.chance, 0.0, 1.0)
		facts.burn_duration = burn.duration
		facts.burn_coverage = clamp(projectiles / interval * (1.0 + min(4, _prop(current, "piercing", 0)) * 0.5) * burn.duration * 0.25, 1.0, 8.0)
	for effect in source.effects:
		var id = effect.get_id()
		if id == "weapon_burning":
			continue
		elif id == "weapon_exploding" or id == "weapon_delayed_exploding":
			facts.explosive = true
			if source.type == 1 and id == "weapon_exploding":
				var impacts = facts.damage_model.get("impact_explosions", [])
				impacts.append(Vector2(effect.chance, effect.scale))
				facts.damage_model.impact_explosions = impacts
			else:
				facts.clear *= 1.0 + float(_prop(effect, "chance", 1.0)) * 0.8
		elif id == "weapon_stack":
			facts.stacks.append({"family": effect.weapon_stacked_id, "value": effect.value, "stat": effect.stat_name})
		elif id == "weapon_gain_stat_every_killed_enemies":
			facts.farm_stats[effect.stat.trim_prefix("stat_")] = float(effect.stat_nb) / max(1, effect.value)
		elif id == "weapon_null" and effect.key in ["pierce_on_crit", "bounce_on_crit"] and facts.damage_model.has("projectile_chain"):
			facts.damage_model.projectile_chain[effect.key] = effect.value
		elif id == "weapon_null" and effect.key == "gold_on_crit_kill":
			facts.crit_gold_chance = effect.value / 100.0
		elif id == "gain_stat_for_every_stat" and effect.key == "stat_lifesteal" and effect.stat_scaled == "percent_player_missing_health" and effect.nb_stat_scaled > 0:
			facts.missing_health_steal = {"value": effect.value, "per": effect.nb_stat_scaled}
		elif id == "weapon_projectiles_on_hit" and effect.weapon_stats != null:
			var secondary = service.init_ranged_stats(effect.weapon_stats, player, true)
			var component = _damage_model(effect.weapon_stats, secondary, _Args.new(), 1)
			component.projectile_chain = _projectile_chain(effect.weapon_stats, secondary)
			# 每个被直接击中的目标各发一组弹丸，原生弹丸跳过触发它的目标。
			component.clear = _expected_hit(secondary) * effect.value / interval * 0.65 * contact * melee_targets
			component.boss = 0.0
			if source.type == 0:
				facts.melee_trigger_targets = melee_targets
			facts.damage_components.append(component)
			facts.clear += component.clear
			facts.boss += component.boss
		elif id == "weapon_timed_slow_on_hit" or id == "weapon_slow_area_on_hit":
			facts.control += min(4.0, abs(effect.value) * effect.duration / 25.0)
		elif id == "weapon_slow_in_zone":
			var projectile = _prop(source.stats, "projectile_scene", null)
			var folder = projectile.resource_path.get_base_dir().get_file() if projectile != null else ""
			# 电击枪的原生区域脚本扣除 200 速度。
			if folder == "bullet_taser":
				facts.zone_slow_speed = 200.0
				facts.approximate = ["投射物区域减速按单个目标的减速与恢复估计"]
			else:
				facts.approximate = ["投射物范围减速的额外控场收益暂未计分"]
		elif id == "structure" or id == "weapon_spawn_structure_every_killed_enemies" or _has_property(effect, "spawn_cooldown"):
			var structure_effect = effect.structure_effect if id == "weapon_spawn_structure_every_killed_enemies" else effect
			if structure_effect != null and structure_effect.stats != null:
				var output = _structure_output(structure_effect)
				facts.structure += output.damage
				facts.structure_scaling += output.scaling
				facts.structure_components.append(output.component)
				if output.mine_interval > 0:
					facts.mine_interval = output.mine_interval
					facts.mine_damage = output.mine_damage
		elif not id in ["effect", "modular", "null", "effect_option", "weapon_slow_on_hit", "weapon_gain_stat_for_every_stat", "weapon_damage_multiplier_if_stat", "weapon_player_health_stat"]:
			if facts.unmeasured.empty():
				facts.first_unmeasured_effect = source.effects.find(effect) + 1
			facts.unmeasured.append(_effect_evidence(effect))
	if source.upgrades_into != null:
		facts.upgrade = {"tier": source.upgrades_into.tier}
	var direct = facts.damage_model.duplicate()
	direct.direct_weapon = true
	direct.clear = facts.clear
	direct.boss = facts.boss
	for component in facts.damage_components:
		direct.clear -= component.clear
		direct.boss -= component.boss
	facts.damage_components.push_front(direct)
	return facts


func _burn_profile(data) -> Dictionary:
	return {"chance": data.chance, "damage": data.damage, "duration": data.duration, "spread": data.spread, "scaling": _scaling(data.scaling_stats)}


func _describe_pet(e, payload: Dictionary) -> bool:
	var id = e.get_id()
	match id:
		"lootworm":
			payload.bonuses.pet_double = e.double_chance * 0.5
			payload.bonuses.pet_pickup = 0.04
		"doc_moth":
			# 原生区域内翻倍的是再生与吸血。进入区域的时间依玩家路线估计。
			payload.bonuses.pet_heal_boost = clamp(e.boost_zone_scale * 0.25, 0.0, 0.5)
		"scapegoat":
			var stats = _scene_stats(e.scene)
			if stats == null:
				return false
			payload.bonuses.pet_control = min(1.5, stats.health * 0.25)
		"pet":
			# 水母由原生计数字段生成，PetEffect 本身没有场景。
			return e.scene == null and payload.bonuses.get("jellyshield_count", 0) > 0
		"ratzilla", "mosquitor", "catling_gun", "bonk_dog", "blazemander", "bot_o_mine":
			if e.weapon_stats == null:
				return false
			var coverage = 0.70 if id == "catling_gun" else (0.50 if e.weapon_stats is RangedWeaponStats else 0.35)
			_pet_attack(payload, e.weapon_stats, coverage, e.is_structure)
			if id == "bonk_dog" and e.explosion_effect != null:
				_pet_attack(payload, e.explosion_effect.stats, 0.30, false, e.explosion_effect)
			if id == "bot_o_mine" and e.landmine_effect_stat != null:
				var mine = e.landmine_effect_stat
				_pet_attack(payload, mine.stats, 0.40, true, null, mine.spawn_cooldown)
			if id == "blazemander":
				_pet_attack(payload, e.ranged_weapon_stats, 0.40, false)
				if e.burning_data != null:
					var burn = service.init_burning_data(e.burning_data, player, false, true)
					var dot = {"raw": e.burning_data.damage + service.sum_scaling_stat_values(burn.scaling_stats, player), "multiplier": 1.0 + utils.get_stat(keys.stat_percent_damage_hash, player) / 100.0, "damage": burn.damage, "scaling": _scaling(burn.scaling_stats), "can_crit": false, "rate": 0.55 * clamp(burn.chance, 0.0, 1.0)}
					payload.structure += dot.damage * dot.rate
					payload.structure_components.append(dot)
		_:
			return false
	payload.bonuses.pet_count = payload.bonuses.get("pet_count", 0) + 1
	if e.is_structure:
		payload.bonuses.structure_count = payload.bonuses.get("structure_count", 0) + 1
	return true


func _pet_attack(payload: Dictionary, base, coverage: float, structure: bool, explosion = null, spawn_frames: int = 0) -> void:
	if base == null:
		return
	var args = _Args.new()
	var stats
	var type = 1 if base is RangedWeaponStats else 0
	if explosion != null:
		args.effects = [explosion]
		stats = service.init_base_stats(base, player, args, false, false, true)
	elif structure:
		stats = service.init_structure_pet_stats(base, player, args)
	else:
		stats = service.init_ranged_pet_stats(base, player, false, args) if type == 1 else service.init_melee_pet_stats(base, player, args)
	var component = _damage_model(base, stats, args, type, structure)
	if structure:
		component.multiplier += utils.get_stat(keys.stat_percent_damage_hash, player) / 100.0
		component.structure_pet = true
	component.direct_weapon = true
	var cooldown = service.apply_structure_attack_speed_effects(spawn_frames, player) if spawn_frames > 0 else stats.cooldown
	component.rate = coverage * max(1, _prop(stats, "nb_projectiles", 1)) * 60.0 / max(1.0, cooldown)
	payload.structure += _expected_hit(stats) * component.rate
	payload.structure_components.append(component)


func _projectile_chain(base_stats, current) -> Dictionary:
	return {"pierces": current.piercing, "pierce_reduction": base_stats.piercing_dmg_reduction - utils.get_stat(keys.generate_hash("piercing_damage"), player) / 100.0,
		"bounces": current.bounce, "bounce_reduction": base_stats.bounce_dmg_reduction - utils.get_stat(keys.generate_hash("bounce_damage"), player) / 100.0, "can_bounce": base_stats.can_bounce}


func _attack_timing(source, current) -> Dictionary:
	# 记录攻速和玩家范围生效前的值，供购买与升级预览重算。
	var raw = {"cooldown": source.stats.cooldown, "max_range": source.stats.max_range}
	var effects = run.get_player_effects(player)
	for entry in effects.get(keys.generate_hash("weapon_type_bonus"), []):
		var stat = keys.hash_to_string.get(entry[1], "")
		if entry[0] == source.type and raw.has(stat):
			raw[stat] = int(raw[stat] + entry[2])
	for entry in effects.get(keys.generate_hash("weapon_class_bonus"), []):
		var stat = keys.hash_to_string.get(entry[1], "")
		if raw.has(stat):
			for category in source.sets:
				if category.my_id_hash == entry[0]:
					raw[stat] = int(raw[stat] + entry[2])
	for e in source.effects:
		# 条件改变基础冷却或射程的词条继续从当前原生间隔近似。
		if (e.get_id() == "weapon_stack" and raw.has(e.stat_name)) or (e.get_id() == "weapon_gain_stat_for_every_stat" and raw.has(e.increased_stat_name)):
			return {}
	var attack_speed = (utils.get_stat(keys.generate_hash("stat_attack_speed"), player) + current.attack_speed_mod) / 100.0
	var maximums = effects.get(keys.generate_hash("maximum_weapon_cooldowns"), [])
	var timing = {"frames": raw.cooldown, "recoil": current.recoil_duration * max(1.0, 1.0 + attack_speed),
		"max_frames": maximums.front() if not maximums.empty() else INF, "reload_shots": current.additional_cooldown_every_x_shots,
		"reload_multiplier": source.stats.additional_cooldown_multiplier}
	if source.type == 0:
		timing.base_range = raw.max_range
		timing.min_range = service.MIN_RANGE + current.min_range
		timing.attack_duration = current.attack_duration
		timing.animation_speed = max(0.01, current.animation_speed)
	return timing


func _damage_model(base_stats, current, args, type: int, structure: bool = false) -> Dictionary:
	# 保留原生截断前的值；不能从已保底为 1 的伤害反推出属性收益。
	var base = float(base_stats.damage)
	var class_damage = 0.0
	for bonus in run.get_player_effects(player).get(keys.generate_hash("weapon_type_bonus"), []):
		if bonus[0] == type and keys.hash_to_string.get(bonus[1], "") == "damage":
			base += bonus[2]
	for bonus in run.get_player_effects(player).get(keys.generate_hash("weapon_class_bonus"), []):
		for set in args.sets:
			if set.my_id_hash == bonus[0]:
				var stat = keys.hash_to_string.get(bonus[1], "")
				if stat == "stat_percent_damage":
					class_damage += bonus[2] / 100.0
				elif stat == "damage":
					base += bonus[2]
	var exploding = false
	var initial_base = base
	var base_effects = []
	for e in args.effects:
		var id = e.get_id()
		if id == "weapon_stack" and e.stat_name == "damage":
			var count = 0
			for held in run.get_player_weapons(player):
				if held.weapon_id == e.weapon_stacked_id:
					count += 1
			base += e.value * max(0, count - 1)
			base_effects.append({"kind": "stack", "family": e.weapon_stacked_id, "value": e.value})
		elif id == "weapon_damage_multiplier_if_stat":
			base_effects.append({"kind": "multiply", "source": e.stat_name, "current": run.get_player_effect(keys.generate_hash(e.stat_name), player), "threshold": e.value, "factor": e.damage_multiplier})
			if e.is_active(player):
				base = round(base * e.damage_multiplier)
		elif id == "weapon_gain_stat_for_every_stat" and e.increased_stat_name == "damage":
			base += run.get_scaling_bonus(e.value, e.stat_scaled, e.nb_stat_scaled, true, player)
			base_effects.append({"kind": "link", "source": e.stat_scaled, "value": e.value, "per": e.nb_stat_scaled})
		elif e is ExplodingEffect:
			exploding = true
	var percent = utils.get_stat(keys.generate_hash("structure_percent_damage" if structure else "stat_percent_damage"), player)
	var multiplier = 1.0 + percent / 100.0 + class_damage
	if exploding:
		multiplier += utils.get_stat(keys.generate_hash("explosion_damage"), player) / 100.0
	return {"raw": base + service.sum_scaling_stat_values(current.scaling_stats, player), "base": initial_base, "applied_base": base, "base_effects": base_effects, "multiplier": multiplier, "damage": current.damage, "scaling": _scaling(current.scaling_stats), "structure": structure, "exploding": exploding, "crit_chance": current.crit_chance, "crit_damage": current.crit_damage, "can_crit": not structure or effect("structures_can_crit") > 0}


func _expected_hit(stats) -> float:
	return lerp(float(stats.damage), max(1.0, round(stats.damage * stats.crit_damage)), clamp(stats.crit_chance, 0.0, 1.0))


func _structure_output(source) -> Dictionary:
	var args = _Args.new()
	args.effects = source.effects
	var stats = service.init_structure_stats(source.stats, player, args)
	var mine = source.scene != null and source.scene.resource_path == "res://entities/structures/landmine/landmine.tscn"
	var rate = 0.0
	var clear_multiplier = 1.3
	var interval = 0
	var base_cooldown = source.spawn_cooldown if mine else stats.cooldown
	var cooldown = service.apply_structure_attack_speed_effects(base_cooldown, player)
	if mine:
		# 地雷触发一次后销毁。spawn_cooldown 是生成间隔（秒），stats.cooldown 并非反复攻击间隔。
		interval = cooldown
		rate = source.value * 0.65 / max(1.0, interval)
	else:
		# 炮塔的射击间隔以帧为单位；原生建筑攻速同时作用于该间隔。
		var chain = 1.0 + max(0, stats.piercing) * (1.0 - stats.piercing_dmg_reduction) * 0.4 + max(0, stats.bounce) * (1.0 - stats.bounce_dmg_reduction) * 0.4
		rate = source.value * max(1, stats.nb_projectiles) * 60.0 / max(1, cooldown) * 0.65
		if stats.projectile_spread >= PI / 2.0:
			# 按半射程处的目标截面估计散射命中。原生基础弹丸与普通敌人受击圆的半径分别是 44 和 32。
			var distance = max(1.0, source.stats.max_range * 0.5)
			var hit_angle = asin(min(1.0, 76.0 / distance))
			rate *= hit_angle / stats.projectile_spread
			clear_multiplier *= chain
		else:
			rate *= chain
	var multiplier = max(0, 1.0 + utils.get_stat(keys.generate_hash("structure_percent_damage"), player) / 100.0)
	var component = _damage_model(source.stats, stats, args, 1, true)
	component.rate = rate
	component.clear_multiplier = clear_multiplier
	component.structure_timing = {"base": base_cooldown, "current": cooldown, "reach": stats.max_range if not mine else 0}
	return {"damage": (_expected_hit(stats) if component.can_crit else stats.damage) * rate, "scaling": _scaling(stats.scaling_stats).get("engineering", 0.0) * rate * multiplier, "component": component, "mine_interval": interval, "mine_damage": stats.damage}


func merge(a: Dictionary, b: Dictionary) -> Dictionary:
	var key = a.key + ":" + b.key
	if _merges.has(key):
		return _merges[key]
	var source_a = clone_weapon(a.source)
	var source_b = clone_weapon(b.source)
	var flavor = a.flavor if a.flavor != 0 else b.flavor
	var upgraded
	if flavor == 1:
		# 原生诅咒合成会掷随机数；预览用最低保留增幅，绝不消耗游戏随机序列。
		var dlc = items.get_dlc_data_by_id("abyssal_terrors")
		upgraded = dlc.curse_item(source_a.upgrades_into, player, true, max(source_a.curse_factor, source_b.curse_factor))
	else:
		# 机械合成传入深拷贝，防止原生模块合并改变持有武器的效果值。
		upgraded = items.get_combined_weapon(source_a, source_b, player)
	var result = describe(upgraded)
	result.estimated = flavor == 1
	_merges[key] = result
	return result


func clone_weapon(source):
	# Godot 3 的 duplicate(true) 也会复制脚本资源，破坏导出包中的类型身份。
	# 只复制原生转换函数会写入的武器和效果，不复制脚本与场景。
	var copy = source.duplicate()
	var effects = []
	for effect in source.effects:
		effects.append(effect.duplicate())
	copy.effects = effects
	return copy


func effect_stats(effects: Array) -> Dictionary:
	var stats = {}
	for effect in effects:
		if effect.get_id() == "effect_option" or effect.storage_method != 0:
			continue
		if effect.key.begins_with("stat_") and _numeric(effect.value):
			var stat = effect.key.substr(5)
			stats[stat] = stats.get(stat, 0.0) + effect.value
	return stats


func _growth() -> Dictionary:
	var result = {}
	for upgrade in items.upgrades:
		if upgrade.tier != 0:
			continue
		for stat in effect_stats(upgrade.effects):
			# 用当前版本最低级升级选项估计投入单位，非承诺每波获得该属性。
			result[stat] = abs(effect_stats(upgrade.effects)[stat]) * 0.25
	return result


func _links() -> Array:
	var result = []
	for link in run.get_player_effects(player).get(keys.generate_hash("stat_links"), []):
		result.append({"target": str(keys.hash_to_string.get(link[0], "")).trim_prefix("stat_"), "value": link[1], "source": str(keys.hash_to_string.get(link[2], "")).trim_prefix("stat_"), "per": link[3], "permanent": link[4]})
	return result


func _scaling(values: Array) -> Dictionary:
	var result = {}
	for value in values:
		var stat = keys.hash_to_string.get(value[0], "") if value[0] is int else str(value[0])
		result[str(stat).trim_prefix("stat_")] = value[1]
	return result


func _numeric(value) -> bool:
	return value is int or value is float


func _prop(object, name: String, fallback):
	var value = object.get(name)
	return fallback if value == null else value


func _has_property(object, name: String) -> bool:
	for property in object.get_property_list():
		if property.name == name:
			return true
	return false
