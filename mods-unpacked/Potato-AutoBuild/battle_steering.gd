extends Reference

const HORIZON = 0.66
const NEAR = 0.22
const HEADINGS = 16
const MAX_BODIES = 24
const MAX_PROJECTILES = 32
const ENEMY_RADIUS = 390.0
const SHOT_RADIUS = 650.0

var _headings = [Vector2.ZERO]
var _projectile_windows = {}


func _init() -> void:
	for index in range(HEADINGS):
		_headings.append(Vector2.RIGHT.rotated(TAU * index / HEADINGS))


func choose(main, player, character: String, evasive: bool, previous: Vector2) -> Vector2:
	var origin = player.global_position
	var speed = player.get_move_speed()
	var bounds = Rect2(ZoneService.current_zone_min_position, ZoneService.current_zone_max_position - ZoneService.current_zone_min_position)
	var hurt_shape = player._hurtbox.get_node_or_null("Collision")
	var hurt_center = hurt_shape.global_position if hurt_shape != null else origin
	var body = _radius(hurt_shape, 24.0)
	var health = max(1, player.current_stats.health)
	var maximum = max(1, player.max_stats.health)
	var armor = RunData.get_armor_coef(player.current_stats.armor)
	var stationary = not RunData.get_player_effect(Keys.can_attack_while_moving_hash, 0)
	var bodies = _bodies(main._entity_spawner.get_all_enemies(false), hurt_center, body, armor)
	var projectiles = _projectiles(main, hurt_center, body, armor)
	var hp_ratio = float(health) / maximum
	var pacifist = character == "character_pacifist"
	# 和平主义者暴走时优先维持安全路线，仍可转向治疗和宝箱。
	var looting = _pickup(main, origin, hp_ratio, not (pacifist and main._is_horde_wave))
	var target = bodies.front() if not bodies.empty() else {}
	var reach = _reach(player)
	var can_shoot_here = not target.empty() and target.offset.length() <= reach
	var standing_value = _standing_value(player, target.empty() and hp_ratio >= 0.80, can_shoot_here)
	var blast = _bull_damage(player) if character == "character_bull" and not evasive and hp_ratio > 0.68 else 0.0
	var engage = not target.empty() and _blast_kills(target, blast)
	var patrol = _patrol(origin, bounds, pacifist)
	var worst = -INF
	var heading = Vector2.ZERO
	for direction in _headings:
		var velocity = direction * speed
		var end = origin + velocity * HORIZON
		var score = -_wall_cost(end, bounds, body)
		var contact_cost = _danger(bodies, velocity, health, blast, pacifist)
		var shot_cost = _danger(projectiles, velocity, health)
		score -= contact_cost + shot_cost
		score += previous.dot(direction) * 0.14
		score += direction.dot(patrol) * (0.75 if pacifist else 0.22)
		if not looting.empty():
			var detour = looting.position - origin
			var gain = detour.length() - (looting.position - end).length()
			# 经过有接触风险的路线时，降低拾取收益，避免为材料冲进追击者或弹道。
			score += looting.weight * clamp(gain / 95.0, -1.0, 1.0) / (1.0 + contact_cost + shot_cost)
		if not target.empty() and not pacifist:
			if engage:
				var near = _path_distance(target.offset, target.offset + (target.velocity - velocity) * NEAR, Vector2.ZERO)
				var gain = target.offset.length() - near
				score += clamp(gain / 95.0, -1.0, 1.0) * 1.5
				# 公牛靠承受一次可控的接触触发爆炸，经过目标即可触发。
				if near <= target.radius and target.damage < health * 0.20 and player._invincibility_timer.time_left < NEAR:
					score += 2.5
			elif reach > 0.0:
				var separation = end.distance_to(origin + target.offset + target.velocity * HORIZON)
				if separation > reach:
					score -= min(1.0, (separation - reach) / 220.0) * 0.48
		if direction == Vector2.ZERO:
			if stationary and can_shoot_here:
				score += 0.85
			# 仅在预计接触和弹道均安全时保留站定计时，治疗和拾取仍与站定竞争。
			if contact_cost == 0.0 and shot_cost == 0.0:
				score += standing_value
		if score > worst:
			worst = score
			heading = direction
	return heading


func _standing_value(player, safe_to_earn: bool, can_shoot_here: bool) -> float:
	var has_next_shop = RunData.current_wave < RunData.nb_of_waves or RunData.is_endless_run
	var value = 0.0
	for effect in RunData.get_player_effect(Keys.temp_stats_while_not_moving_hash, 0):
		if effect[1] <= 0:
			continue
		if effect[0] != Keys.percent_materials_hash:
			if can_shoot_here:
				value = max(value, 0.55)
		elif has_next_shop and safe_to_earn and effect[2] > 0:
			var income = min(effect[2], max(1, int(effect[1] * RunData.get_player_gold(0) / 100.0)))
			var due = player._not_moving_timer.time_left
			# 优先等完已开始的材料计时，避免反复停走。单次仅值一材料时仍照常走位。
			if income > 1 and due > 0.0 and due < NEAR:
				value = max(value, 0.36 + 0.08 * min(5, income))
	return value


func _bodies(enemies: Array, origin: Vector2, body: float, armor: float) -> Array:
	var nearby = []
	for unit in enemies:
		if not is_instance_valid(unit) or unit.dead or unit._pending_die:
			continue
		var offset = unit.global_position - origin
		if offset.length_squared() > ENEMY_RADIUS * ENEMY_RADIUS:
			continue
		var velocity = unit.get_linear_velocity()
		var lead = 0.0
		var until = HORIZON
		var attack = unit.get("_current_attack_behavior")
		if attack is ChargingAttackBehavior:
			if unit._move_locked and attack._unlock_move_timer.time_left > 0.0:
				until = min(until, attack._unlock_move_timer.time_left)
			elif not unit._can_move and attack._recovery_timer.is_stopped():
				# 冲锋起步前预留横移空间。随机方向只在原生已选定时预测。
				var direction = attack._charge_direction.normalized()
				if direction == Vector2.ZERO and attack.target == ChargingAttackBehavior.TargetType.PLAYER:
					direction = -offset.normalized()
				velocity = direction * (unit.current_stats.speed + attack.charge_speed)
				lead = 0.24
		# 可被武器击中的范围可能大于怪物接触伤害的碰撞范围。
		var hitbox = unit.get("_hitbox")
		var collision = hitbox.get_node_or_null("Collision") if is_instance_valid(hitbox) else null
		var radius = _radius(collision, 25.0)
		var contact_offset = collision.global_position - origin if collision != null else offset
		var priority = offset.length_squared()
		nearby.append({"offset": contact_offset - velocity * lead, "velocity": velocity, "radius": radius + body, "axis": Vector2.ZERO,
			"damage": max(1, unit.current_stats.damage * armor), "priority": priority, "start": lead, "end": until, "stops": until < HORIZON,
			"hp": unit.current_stats.health, "target_armor": unit.current_stats.armor, "boss": unit is Boss})
	nearby.sort_custom(self, "_closer")
	nearby.resize(min(MAX_BODIES, nearby.size()))
	return nearby


func _projectiles(main, origin: Vector2, body: float, armor: float) -> Array:
	var hazards = []
	for node in main._enemy_projectiles.get_children():
		if node is Projectile:
			_add_projectile(hazards, node, origin, body, armor)
		elif node is Node2D:
			for shot in node.get_children():
				if shot is Projectile:
					_add_projectile(hazards, shot, origin, body, armor)
	for boss in main._entity_spawner.bosses:
		if not is_instance_valid(boss) or boss.dead:
			continue
		for node in boss.get_children():
			if node is Pivot:
				for shot in node.get_children():
					if shot is Projectile:
						_add_projectile(hazards, shot, origin, body, armor)
	hazards.sort_custom(self, "_closer")
	hazards.resize(min(MAX_PROJECTILES, hazards.size()))
	return hazards


func _add_projectile(hazards: Array, shot: Projectile, origin: Vector2, body: float, armor: float) -> void:
	var hitbox = shot._hitbox
	if not is_instance_valid(hitbox) or not hitbox.active:
		return
	var collision = hitbox._collision
	if not is_instance_valid(collision) or collision.shape == null:
		return
	var offset = collision.global_position - origin
	if offset.length_squared() > SHOT_RADIUS * SHOT_RADIUS:
		return
	var velocity = shot.velocity + shot.sinusoidal_offset
	var parent = shot.get_parent()
	if parent is Pivot:
		var radial = shot.global_position - parent.global_position
		velocity += Vector2(-radial.y, radial.x) * parent.rotation_speed * parent.direction
	var window = _active_window(shot._animation_player, hitbox.is_disabled())
	if window.x >= HORIZON or window.y <= 0.0:
		return
	var axis = Vector2.ZERO
	var radius = _radius(collision, 16.0) + body
	if collision.shape is RectangleShape2D:
		var size = collision.shape.extents * collision.global_scale.abs()
		var long = Vector2.RIGHT if size.x >= size.y else Vector2.DOWN
		radius = min(size.x, size.y) + body
		axis = long.rotated(collision.global_rotation) * abs(size.x - size.y)
	# 优先保留这一段时间能靠近玩家的弹道，远离玩家的弹不占近身名额。
	var arrival = clamp(-offset.dot(velocity) / max(1.0, velocity.length_squared()), window.x, window.y)
	var priority = max(0.0, (offset + velocity * arrival).length() - axis.length() - radius)
	hazards.append({"offset": offset, "velocity": velocity, "radius": radius, "axis": axis,
		"damage": max(1, hitbox.damage * armor), "priority": priority, "start": window.x, "end": window.y})


func _active_window(player, disabled: bool) -> Vector2:
	var active = Vector2(0.0, HORIZON) if not disabled else Vector2(HORIZON, HORIZON)
	if not is_instance_valid(player) or not player.is_playing() or player.playback_speed <= 0 or not player.has_animation(player.current_animation):
		return active
	var animation = player.get_animation(player.current_animation)
	var key = animation.get_instance_id()
	if not _projectile_windows.has(key):
		var times = []
		for track in range(animation.get_track_count()):
			if animation.track_get_type(track) != Animation.TYPE_METHOD:
				continue
			for index in range(animation.track_get_key_count(track)):
				var method = animation.method_track_get_name(track, index)
				if method in ["enable_hitbox", "disable_hitbox"]:
					times.append([animation.track_get_key_time(track, index), method == "enable_hitbox"])
		_projectile_windows[key] = times
	for event in _projectile_windows[key]:
		var delay = (event[0] - player.current_animation_position) / player.playback_speed
		if delay <= 0.0 or delay >= HORIZON:
			continue
		if disabled and event[1]:
			active.x = min(active.x, delay)
		elif not event[1] and delay > active.x:
			active.y = min(active.y, delay)
	return active


func _danger(hazards: Array, velocity: Vector2, hp: float, blast: float = 0.0, disengage: bool = false) -> float:
	var loss = 0.0
	for hazard in hazards:
		var relative = hazard.velocity - velocity
		var first = hazard.offset + relative * hazard.start
		var last = hazard.offset + relative * hazard.end
		var distance = _path_distance(first, last, hazard.axis)
		if hazard.get("stops", false):
			distance = min(distance, _path_distance(last, last - velocity * (HORIZON - hazard.end), hazard.axis))
		var space = distance - hazard.radius
		if space > 86.0:
			continue
		var early = _path_distance(first, hazard.offset + relative * clamp(NEAR, hazard.start, hazard.end), hazard.axis) <= hazard.radius
		var contact = max(0.0, 1.0 - space / 86.0)
		var weight = 0.6 + 5.5 * hazard.damage / hp
		if _blast_kills(hazard, blast):
			weight *= 0.46
		loss += weight * (0.25 * contact * contact + (2.0 if early else 1.0) * clamp(1.0 - space / 24.0, 0.0, 1.5))
		if disengage and hazard.start == 0.0 and hazard.offset.length_squared() <= hazard.radius * hazard.radius:
			# 已贴身时，各方向的最短距离都从重叠处起算。再比较短时间后能否拉开。
			var escape = (hazard.offset + relative * min(NEAR, hazard.end)).length() - hazard.radius
			loss += weight * 0.55 * clamp(1.0 - escape / 24.0, 0.0, 1.5)
	return loss


func _path_distance(first: Vector2, last: Vector2, axis: Vector2) -> float:
	var along = last - first
	if axis == Vector2.ZERO:
		return (first + along * clamp(-first.dot(along) / max(0.001, along.length_squared()), 0.0, 1.0)).length()
	if Geometry.segment_intersects_segment_2d(first, last, -axis, axis) != null:
		return 0.0
	var from_path = min(first.distance_squared_to(Geometry.get_closest_point_to_segment_2d(first, -axis, axis)),
		last.distance_squared_to(Geometry.get_closest_point_to_segment_2d(last, -axis, axis)))
	var from_blade = min(axis.distance_squared_to(Geometry.get_closest_point_to_segment_2d(axis, first, last)),
		(-axis).distance_squared_to(Geometry.get_closest_point_to_segment_2d(-axis, first, last)))
	return sqrt(min(from_path, from_blade))


func _wall_cost(end: Vector2, bounds: Rect2, body: float) -> float:
	var clearance = min(min(end.x - bounds.position.x, bounds.end.x - end.x), min(end.y - bounds.position.y, bounds.end.y - end.y))
	return max(0.0, body - clearance) * 0.08 + max(0.0, 78.0 - clearance) * 0.012


func _patrol(origin: Vector2, bounds: Rect2, orbit: bool) -> Vector2:
	var center = bounds.position + bounds.size * 0.5
	var delta = origin - center
	if not orbit:
		return -delta.normalized() if delta.length() > 85.0 else Vector2.ZERO
	var edge = Vector2(max(70.0, bounds.size.x * 0.5 - 140.0), max(70.0, bounds.size.y * 0.5 - 140.0))
	var radial = delta / edge
	var outward = radial.normalized() if radial.length_squared() > 0.0025 else Vector2.RIGHT
	return (Vector2(-outward.y, outward.x) + outward * clamp(2.5 * (1.0 - radial.length()), -1.0, 1.0)).normalized()


func _pickup(main, origin: Vector2, hp_ratio: float, collect_gold: bool) -> Dictionary:
	var target = {}
	var best = 0.0
	for gold in main._active_golds if collect_gold else []:
		if not is_instance_valid(gold) or not is_instance_valid(gold.get_parent()):
			continue
		var weight = 0.58 + 0.1 * min(4, gold.value)
		var benefit = weight - origin.distance_to(gold.global_position) / 340.0
		if benefit > best:
			target = {"position": gold.global_position, "weight": weight}
			best = benefit
	for item in main._consumables:
		if not is_instance_valid(item) or item.consumable_data == null or not RunData.can_pick_up_consumable(item.consumable_data, 0):
			continue
		var data = item.consumable_data
		if data.my_id_hash in [Keys.consumable_poisoned_fruit_hash, Keys.consumable_meca_fruit_hash, Keys.consumable_mutant_fruit_hash]:
			continue
		var weight = 1.9
		if item.has_healing_effect():
			if hp_ratio >= 0.93:
				continue
			weight = lerp(1.0, 3.8, 1.0 - hp_ratio)
		var benefit = weight - origin.distance_to(item.global_position) / 145.0
		if benefit > best:
			target = {"position": item.global_position, "weight": weight}
			best = benefit
	return target


func _reach(player) -> float:
	var total = 0.0
	for weapon in player.current_weapons:
		if is_instance_valid(weapon):
			total += max(75.0, weapon.current_stats.max_range)
	return total / max(1, player.current_weapons.size())


func _bull_damage(player) -> float:
	var damage = 0.0
	for effect in player._explode_on_hit_stats:
		if effect.chance >= 1.0:
			damage += player._explode_on_hit_stats[effect].damage + effect.get_additional_scaling_damage(player.player_index)
	return damage


func _blast_kills(target: Dictionary, blast: float) -> bool:
	return blast > 0.0 and not target.get("boss", true) and blast * RunData.get_armor_coef(target.target_armor) >= target.hp


func _radius(collision, fallback: float) -> float:
	if not is_instance_valid(collision):
		return fallback
	if collision.shape is CircleShape2D:
		return collision.shape.radius * max(abs(collision.global_scale.x), abs(collision.global_scale.y))
	return fallback


func _closer(a: Dictionary, b: Dictionary) -> bool:
	return a.priority < b.priority
