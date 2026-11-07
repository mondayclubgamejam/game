extends Node
## Test autopilot (--bot). Plays the local player's role so two headless
## instances can run the full fire / throw / recall / throw loop over a real
## network connection and log what happened.

var game: Node
var shots_dir := ""      ## --shots=DIR: save the bot's view every SHOT_EVERY seconds
var _cool := 0.0
var _shot_t := 1.0
var _shot_n := 0

const SHOT_EVERY := 0.5


func _process(delta: float) -> void:
	if shots_dir == "" or game.phase == game.Phase.LOBBY:
		return
	_shot_t -= delta
	if _shot_t <= 0.0:
		_shot_t = SHOT_EVERY
		if _shot_n == 0:
			await _overview()
		var img := get_viewport().get_texture().get_image()
		img.save_png(shots_dir.path_join("shot_%03d.png" % _shot_n))
		_shot_n += 1


## One high-angle shot of the whole room.
func _overview() -> void:
	var cam := Camera3D.new()
	game.add_child(cam)
	cam.position = Vector3(18, 34, 46)
	cam.look_at(Vector3(18, 0, 13))
	cam.fov = 60.0
	cam.make_current()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(shots_dir.path_join("overview.png"))
	cam.queue_free()
	game.local_player.camera.make_current()


var _stats_t := 12.0


## Prints engine counters once, 12 s into the session.
func _print_stats() -> void:
	var P := Performance
	print("STATS fps=%d draw_calls=%d primitives=%d process_ms=%.2f physics_ms=%.2f static_mem_mb=%.1f objects=%d nodes=%d" % [
		P.get_monitor(P.TIME_FPS), P.get_monitor(P.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		P.get_monitor(P.RENDER_TOTAL_PRIMITIVES_IN_FRAME), P.get_monitor(P.TIME_PROCESS) * 1000.0,
		P.get_monitor(P.TIME_PHYSICS_PROCESS) * 1000.0, P.get_monitor(P.MEMORY_STATIC) / 1048576.0,
		P.get_monitor(P.OBJECT_COUNT), P.get_monitor(P.OBJECT_NODE_COUNT)])


func _physics_process(delta: float) -> void:
	if _stats_t > 0.0:
		_stats_t -= delta
		if _stats_t <= 0.0:
			_print_stats()
	var me: CharacterBody3D = game.local_player
	if me == null or not me.alive or game.phase != game.Phase.PLAYING:
		return
	_cool -= delta
	me.bot_move = Vector2.ZERO
	me.bot_crouch = false
	var gun: Node3D = game.gun
	var partner: Node3D = game.partner

	if game.i_hold_gun():
		if game.can_fire():
			var e := _nearest_enemy(me, partner)
			if e != null:
				_look_at(me, e.global_position + Vector3(0, 1.1, 0))
				if _cool <= 0.0:
					game.try_primary()
					_cool = 0.5
			else:
				me.bot_move = Vector2(1, 0)  # partner in the way of every shot: sidestep
		elif game.can_recall():
			# If my last recall got stuck on a wall, walk toward the bullet to
			# find a clear path, like a player would.
			var lodge: Vector3 = game.bullet.lodge_pos
			var unsafe := _recall_hits(me, partner)
			if (game.bullet.shooter == me or unsafe) and me.global_position.distance_to(lodge) > 3.0:
				_look_at(me, Vector3(lodge.x, me.eye_pos().y, lodge.z))
				me.bot_move = Vector2(0.8 if unsafe else 0.0, -1)
			if _cool <= 0.0 and not unsafe:
				game.try_primary()
				_cool = 0.9
		elif game.bullet.state == game.bullet.FORWARD or game.bullet.state == game.bullet.RECALL:
			pass
		elif partner != null:
			_look_at(me, partner.chest_pos())
			if _cool <= 0.0:
				game.try_throw()
				_cool = 1.0
	elif gun.state == gun.GROUND:
		_look_at(me, gun.global_position + Vector3(0, 1.6, 0))
		me.bot_move = Vector2(0, -1)
	elif partner != null:
		_look_at(me, partner.chest_pos())
		me.bot_crouch = gun.state == gun.HELD  # crouch while the partner has the gun


## True if the recall curve would pass through the partner.
func _recall_hits(me: Node3D, partner: Node3D) -> bool:
	if partner == null or not partner.alive:
		return false
	var traj = game.Traj
	var p0: Vector3 = game.bullet.lodge_pos
	var target: Vector3 = me.muzzle_pos()
	var p1: Vector3 = traj.recall_control(p0, game.bullet.lodge_dir, target)
	for i in 21:
		var q: Vector3 = traj.bezier(p0, p1, target, i / 20.0)
		var d: Vector3 = q - partner.global_position
		if Vector2(d.x, d.z).length() < 1.0 and q.y < 2.2:
			return true
	return false


## Nearest living enemy whose line of fire doesn't pass through the partner.
func _nearest_enemy(me: Node3D, partner: Node3D) -> Node3D:
	var best: Node3D = null
	var best_d := INF
	var eye: Vector3 = me.eye_pos()
	for e in game.enemies:
		if e.alive:
			if partner != null and partner.alive:
				var aim: Vector3 = e.global_position + Vector3(0, 1.1, 0)
				var far_end: Vector3 = eye + (aim - eye).normalized() * 80.0
				var closest := Geometry3D.get_closest_point_to_segment(partner.chest_pos(), eye, far_end)
				if closest.distance_to(partner.chest_pos()) < 1.0:
					continue
			var d: float = me.global_position.distance_to(e.global_position)
			if d < best_d:
				best = e
				best_d = d
	return best


func _look_at(me: Node3D, point: Vector3) -> void:
	var eye: Vector3 = me.eye_pos()
	var d := point - eye
	me.rotation.y = atan2(-d.x, -d.z)
	me.head.rotation.x = atan2(d.y, Vector2(d.x, d.z).length())
