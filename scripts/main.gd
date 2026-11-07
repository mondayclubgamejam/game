extends Node3D
## Entry point and the only network router. Every RPC lives on this node, so
## node paths always match on both peers, and moving to a dedicated server
## later only means changing who runs the host-side branches here.
##
## Authority (lowest latency first):
##   - each player owns their own movement and the bullet they launch
##   - each player decides hits on themselves (enemy shots, melee, friendly fire)
##   - the host owns the room seed, enemy brains, enemy deaths and gun pickups
##
## The "host" is either a player (LAN play) or a dedicated server started
## with --server, which plays nobody and relays between two clients. Players
## reach the server over UDP, or over a WebSocket on HTTPS (port 443) when
## UDP is blocked. Players connect by the server's IP address. The server
## has its own certificate, and builds carry a copy of it (assets/server.crt),
## so players verify they've reached the right server.

const Palette := preload("res://scripts/palette.gd")
const RoomGen := preload("res://scripts/room_gen.gd")
const RoomBuilder := preload("res://scripts/room_builder.gd")
const Traj := preload("res://scripts/trajectory.gd")
const WorldFx := preload("res://scripts/world_fx.gd")
const Player := preload("res://scripts/player.gd")
const Enemy := preload("res://scripts/enemy.gd")
const Gun := preload("res://scripts/gun.gd")
const Bullet := preload("res://scripts/bullet.gd")
const Tracers := preload("res://scripts/tracers.gd")
const Debris := preload("res://scripts/debris.gd")
const AimLine := preload("res://scripts/aim_line.gd")
const Hud := preload("res://scripts/hud.gd")
const Hand := preload("res://scripts/hand.gd")
const Lobby := preload("res://scripts/lobby.gd")
const Bot := preload("res://scripts/bot.gd")
const LanDiscovery := preload("res://scripts/lan_discovery.gd")
const DualServerPeer := preload("res://scripts/dual_server_peer.gd")
const Clock := preload("res://scripts/clock.gd")
const PauseMenu := preload("res://scripts/pause_menu.gd")
const Maps := preload("res://scripts/maps.gd")
const MenuStage := preload("res://scripts/menu_stage.gd")

enum Phase { LOBBY, PLAYING, OVER }

const ROLE_FORWARD := 0
const ROLE_REVERSE := 1
const CATCH_RADIUS := 1.6
const PICKUP_RADIUS := 1.3
const THROWER_GRACE := 0.35
const MELEE_REACH := 2.1
const THROW_ASSIST_DEG := 20.0
const ENEMY_SYNC_INTERVAL := 0.05
const PING_INTERVAL := 0.5
const RESTART_DELAY := 1.6
const NEXT_ROOM_DELAY := 2.4
const RUN_OVER_DELAY := 3.0
## Tutorial B: [title, what NORMAL does, what INVERTED does] for each step.
const TUT_STEPS := [
	["GRAB THE GUN", "WALK OVER THE GUN TO PICK IT UP", "LET YOUR NORMAL PARTNER PICK UP THE GUN"],
	["ONE BULLET, MANY TARGETS", "SHOOT ALL THREE TARGETS: THE BULLET GOES STRAIGHT THROUGH THEM",
		"WATCH: ONLY NORMAL CAN FIRE"],
	["PASS THE GUN", "RIGHT CLICK TO THROW THE EMPTY GUN TO YOUR PARTNER", "CATCH THE GUN: STAND IN ITS WAY"],
	["BRING IT HOME", "ONLY INVERTED CAN RECALL: KEEP OUT OF THE BLUE LINE",
		"RECALL THROUGH THE NEW TARGET: MOVE TO BEND THE BLUE LINE"],
	["WATCH YOUR PARTNER", "THE BULLET KILLS TEAMMATES TOO. A RED LINE MEANS SOMEONE'S IN THE WAY. DO ONE MORE LOOP",
		"THE BULLET KILLS TEAMMATES TOO. A RED LINE MEANS SOMEONE'S IN THE WAY. DO ONE MORE LOOP"],
	["FOR REAL", "CLEAR THE ROOM. STAND STILL TO SLOW TIME; CROUCH (CTRL) BEHIND CRATES",
		"CLEAR THE ROOM. STAND STILL TO SLOW TIME; CROUCH (CTRL) BEHIND CRATES"],
]
## Tutorial B: the step that wakes each enemy group.
const TUT_WAKE := {1: 1, 2: 3, 3: 5}
const TUT_BANNER_HOLD := 2.5   ## tutorial B's banners stay up long enough to read
const MASK_WORLD := 1
const MASK_ENEMY := 2
const MASK_PLAYER := 4
const KILL_WORDS := ["", "KILL!", "DOUBLE!", "TRIPLE!", "QUAD!"]
## Network protocol version. Bump it whenever an RPC's arguments change, so
## mismatched builds refuse each other with a clear message instead of
## failing on individual RPCs.
const PROTOCOL := 13
const MAX_PLAYERS := 4
const WS_PORT := 443           ## dedicated server's encrypted WebSocket (HTTPS) port
const SERVER_CERT := "res://assets/server.crt"  ## the server certificate players trust
const SERVER_NAME := "one-gun-one-bullet"       ## the name inside that certificate
const SLOW_IN_RATE := 3.0     ## how fast time eases into slow motion (per second)
const SLOW_OUT_RATE := 4.0    ## and how fast it speeds back up when someone moves
const UDP_TRY_SECONDS := 2.5   ## how long to try UDP before falling back to WebSocket
const WS_TRY_SECONDS := 8.0

var phase := Phase.LOBBY
var room_seed := 0
var room_no := 1
var attempt := 1          ## tries at the current room: +1 on every restart, 1 on a new room
var roster: Array = []    ## this round's players: [peer id, role, name] each
var bullet_seq := 0       ## newest bullet action; older results are ignored
var round_id := 0         ## bumps every round so stale timers do nothing
var rtt := 0.0

var fx: WorldFx
var hud: Hud
var hand: Hand
var lobby: Lobby
var round_root: Node3D
var room: RefCounted
var astar: AStarGrid2D
var players := {}         ## peer id -> player
var local_player: Player
var enemies: Array = []
var gun: Gun
var bullet: Bullet
var tracers: Tracers
var debris: Debris
var aim_line: AimLine
var lan: LanDiscovery
var pause: PauseMenu

var _claim_pending := false
var _action_kills := 0
var _enemies_left := 0
var _sync_t := 0.0
var _ping_t := 0.0
var _enemy_buf := PackedFloat32Array()
var _preview_pts := PackedVector3Array()
var _targeted: Array = []
var _ray := PhysicsRayQueryParameters3D.new()
var _seg_exclude: Array[RID] = []
var _log := false
var _peaceful := false
var _bot_mode := false
var _net_role := "offline"
var _auto_join_lan := false
var _slowmo_enabled := false   ## host: chosen in the match lobby (off by default)
var _map_id := Lobby.DEFAULT_MAP  ## host: chosen in the match lobby
var _round_mode := Lobby.DEFAULT_MAP  ## the map / mode of the round being played
var _tut_step := 0             ## tutorial B: the current step (0-5)
var _tut_mark := 0             ## tutorial B: recalls done when the step began
var _recalls_done := 0         ## bullets recalled into the gun this round
var _host_time_target := 1.0   ## the host's slow-motion decision, as last received
var _party := {}               ## host: match lobby members, peer id -> {name, role, ready}
var _party_order: Array[int] = []
var _party_resume := false     ## host: the next start continues the current room
var _round_end := ""           ## host: "", "died" or "cleared": how the current round ended
var _hosting_args: Array = []  ## LAN host: what the hosting screen shows, to show it again
var _bot_swap_pending := false ## test bot: swap roles at the next match lobby
var _bot_wait_players := 2     ## test bot: ready up once this many are in the lobby
var _advertising := false      ## LAN host: announcing the game on the network
var _spec_target: Player = null  ## who a dead player is watching
var _spec_cam: Camera3D = null
var _dedicated := false        ## this process is a --server
var _relayed := false          ## this client plays through a dedicated server
var _conn_stage := ""          ## client: "", "udp" or "ws" while connecting online
var _conn_attempt := 0
var _online_ws_url := ""


func _ready() -> void:
	if _relaunch_if_software_rendering():
		return
	if OS.get_cmdline_user_args().has("--view"):
		# Look-only mode: the world and UI with no game running (scripts/viewer.gd).
		get_tree().change_scene_to_file.call_deferred("res://scenes/viewer.tscn")
		return
	process_physics_priority = 100  # run after the players have moved
	_setup_input()
	fx = WorldFx.new()
	add_child(fx)
	_preview_pts.resize(AimLine.MAX_SEGMENTS + 1)

	var ui := CanvasLayer.new()
	add_child(ui)
	hand = Hand.new()
	hand.visible = false
	ui.add_child(hand)
	hud = Hud.new()
	hud.visible = false
	ui.add_child(hud)
	lobby = Lobby.new()
	ui.add_child(lobby)
	lobby.host_requested.connect(host_game)
	lobby.join_requested.connect(join_game)
	pause = PauseMenu.new()
	ui.add_child(pause)
	pause.resume_requested.connect(_close_pause)
	pause.roles_requested.connect(func():
		_close_pause(false)
		_to_host("request_party"))
	pause.leave_requested.connect(func(): _back_to_lobby("", false))
	pause.quit_requested.connect(func(): get_tree().quit())

	lan = LanDiscovery.new()
	add_child(lan)
	lan.hosts_changed.connect(_on_lan_hosts)
	lobby.cancel_requested.connect(func(): _back_to_lobby("", false))
	lobby.online_requested.connect(join_online)
	# Scan the network only while the JOIN A GAME page is open.
	lobby.join_page.connect(func(opened: bool):
		if opened:
			_search_lan()
		else:
			lan.stop_searching())
	lobby.role_chosen.connect(func(role: int): _to_host("party_pick", [role]))
	lobby.ready_toggled.connect(func(ready: bool): _to_host("party_ready", [ready]))
	lobby.slowmo_toggled.connect(func(on: bool): _to_host("party_set_slowmo", [on]))
	lobby.move_requested.connect(func(id: int, role: int): _to_host("party_move", [id, role]))
	lobby.map_chosen.connect(func(id: String): _to_host("party_set_map", [id]))

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_parse_args()
	# The live scene behind the menus (not on a server or a headless test run).
	if not _dedicated and DisplayServer.get_name() != "headless":
		var stage := MenuStage.new()
		stage.game = self
		add_child(stage)


## Vulkan on the CPU (no proper GPU driver, common on managed or remote
## machines) is too slow to play and can freeze. Restart on the much lighter
## OpenGL renderer instead. Pass --no-gl-fallback to skip this.
func _relaunch_if_software_rendering() -> bool:
	if DisplayServer.get_name() == "headless" \
			or RenderingServer.get_current_rendering_method() != "forward_plus" \
			or RenderingServer.get_video_adapter_type() != RenderingDevice.DEVICE_TYPE_CPU \
			or OS.get_cmdline_user_args().has("--no-gl-fallback"):
		return false
	var args := OS.get_cmdline_args()
	args.append_array(PackedStringArray(["--rendering-method", "gl_compatibility"]))
	var user := OS.get_cmdline_user_args()
	if not user.is_empty():
		args.append("--")
		args.append_array(user)
	print("Software rendering (%s) detected: restarting with the OpenGL renderer." \
		% RenderingServer.get_video_adapter_name())
	OS.create_process(OS.get_executable_path(), args)
	get_tree().quit()
	return true


func _parse_args() -> void:
	var port := Lobby.DEFAULT_PORT
	var ws_port := WS_PORT
	var ws_bind := "*"
	var tls_dir := ""
	var host := false
	var server := false
	var join := ""
	var online := ""
	for arg in OS.get_cmdline_user_args():
		if arg == "--host":
			host = true
		elif arg == "--server":
			server = true
		elif arg.begins_with("--ws-port="):
			ws_port = arg.trim_prefix("--ws-port=").to_int()
		elif arg.begins_with("--ws-bind="):
			ws_bind = arg.trim_prefix("--ws-bind=")
		elif arg.begins_with("--online="):
			online = arg.trim_prefix("--online=")
		elif arg.begins_with("--tls-dir="):
			tls_dir = arg.trim_prefix("--tls-dir=")  # server: where its key and certificate live
		elif arg == "--join=lan":
			_auto_join_lan = true  # join the first game found on the LAN
			_search_lan()
		elif arg.begins_with("--join="):
			join = arg.trim_prefix("--join=")
		elif arg.begins_with("--port="):
			port = arg.trim_prefix("--port=").to_int()
		elif arg == "--log":
			_log = true
		elif arg == "--peaceful":
			_peaceful = true
		elif arg == "--slowmo":
			_slowmo_enabled = true  # host/server: start with slow motion on
		elif arg.begins_with("--map=") and Lobby.map_available(arg.substr(6)):
			_map_id = arg.substr(6)  # host/server: start on this map
		elif arg == "--bot":
			_bot_mode = true
			_log = true
			var bot := Bot.new()
			bot.game = self
			add_child(bot)
		elif arg.begins_with("--wait-players="):
			_bot_wait_players = arg.trim_prefix("--wait-players=").to_int()
		elif arg.begins_with("--swap-after="):
			# Test bot: ask to change roles after this many seconds of play.
			var after := arg.trim_prefix("--swap-after=").to_float()
			get_tree().create_timer(after).timeout.connect(func():
				_bot_swap_pending = true
				_to_host("request_party"))
		elif arg.begins_with("--shots="):
			for child in get_children():
				if child is Bot:
					child.shots_dir = arg.trim_prefix("--shots=")
					DirAccess.make_dir_recursive_absolute(child.shots_dir)
		elif arg.begins_with("--quit-after="):
			get_tree().create_timer(arg.trim_prefix("--quit-after=").to_float()).timeout.connect(get_tree().quit)
	if server:
		_start_dedicated(port, ws_port, ws_bind, tls_dir)
	elif host:
		host_game(port)
	elif join != "":
		join_game(join, port)
	elif online != "":
		join_online(online)


# --- Connection ------------------------------------------------------------------

func host_game(port: int) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		lobby.show_menu("Couldn't host on port %d (error %d). Is another copy already hosting?" % [port, err], true)
		return
	multiplayer.multiplayer_peer = peer
	_net_role = "host"
	lan.stop_searching()
	var answering := lan.start_advertising(port, lobby.player_name())
	_advertising = true
	_hosting_args = [port, LanDiscovery.best_addresses(), _firewall_hint(port), answering]
	lobby.show_hosting(port, _hosting_args[1], _hosting_args[2], answering)
	_party_reset()
	_party_add(multiplayer.get_unique_id(), lobby.player_name())
	_log_event("hosting on port %d" % port)


## The exact command to open the game's ports on this machine's firewall.
func _firewall_hint(port: int) -> String:
	var ports := "%d-%d" % [port, LanDiscovery.PORT] if port + 1 == LanDiscovery.PORT \
		else "%d and %d" % [port, LanDiscovery.PORT]
	if OS.has_feature("windows"):
		return "If Windows asks, allow the game on private networks."
	if FileAccess.file_exists("/usr/bin/firewall-cmd"):
		return "If your partner can't see you, open UDP %s:\nsudo firewall-cmd --add-port=%d/udp --add-port=%d/udp" \
			% [ports, port, LanDiscovery.PORT]
	if FileAccess.file_exists("/usr/sbin/ufw"):
		return "If your partner can't see you, open UDP %s:\nsudo ufw allow %d/udp && sudo ufw allow %d/udp" \
			% [ports, port, LanDiscovery.PORT]
	return "If your partner can't see you, let UDP %s through your firewall." % ports


func join_game(address: String, port: int) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		lobby.show_menu("Couldn't start a connection to %s (error %d)." % [address, err], true)
		return
	# Give up after ~6 s instead of ENet's default ~30 s.
	peer.get_peer(1).set_timeout(0, 3000, 6000)
	multiplayer.multiplayer_peer = peer
	_net_role = "client"
	_auto_join_lan = false
	lan.stop_searching()
	lobby.show_busy("CONNECTING TO %s" % address)


func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		welcome.rpc_id(id, PROTOCOL)
		_member_join(id)


func _on_connected() -> void:
	var via: String = {"udp": "UDP", "ws": "WebSocket"}.get(_conn_stage, "UDP")
	_conn_stage = ""
	lobby.show_busy("CONNECTED")
	party_hello.rpc_id(1, lobby.player_name(), PROTOCOL)
	_log_event("connected as %d via %s" % [multiplayer.get_unique_id(), via])


func _on_connection_failed() -> void:
	if _conn_stage == "udp":
		_try_ws()
		return
	if _conn_stage == "ws":
		_online_failed()
		return
	_back_to_lobby("Couldn't reach that game. Is it still open, and is the host's firewall letting UDP %d in?"
		% Lobby.DEFAULT_PORT, true)


func _search_lan() -> void:
	lan.start_searching()
	lobby.set_lan_hosts(lan.hosts())


func _on_lan_hosts(hosts: Array) -> void:
	lobby.set_lan_hosts(hosts)
	_log_event("LAN games: %s" % [hosts])
	if _auto_join_lan and not hosts.is_empty() and phase == Phase.LOBBY:
		join_game(hosts[0]["ip"], hosts[0]["port"])


func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		_member_left(id)


func _on_server_disconnected() -> void:
	_back_to_lobby("Lost the connection to the server." if _relayed else "The host left.", _relayed)


func _back_to_lobby(message: String, is_error := false) -> void:
	_log_event("back to lobby: " + message)
	_clear_round()
	phase = Phase.LOBBY
	_relayed = false
	_conn_stage = ""
	_conn_attempt += 1
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	hud.visible = false
	hand.visible = false
	lobby.visible = true
	lobby.show_menu(message, is_error)
	lan.stop_advertising()
	_advertising = false
	lan.stop_searching()
	_party_reset()
	pause.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# --- Dedicated server -----------------------------------------------------------

## `tls_dir` holds the server's key and certificate (made there on first
## run). Empty means an unencrypted WebSocket, for local testing only.
func _start_dedicated(udp_port: int, ws_port: int, ws_bind: String, tls_dir: String) -> void:
	_dedicated = true
	_net_role = "server"
	_log = true
	Engine.max_fps = 120  # no rendering; just keep relays prompt without spinning
	var tls: TLSOptions = null
	if tls_dir != "":
		tls = _server_tls(tls_dir)
		if tls == null:
			get_tree().quit(1)
			return
	var peer := DualServerPeer.new()
	var err := peer.listen(udp_port, ws_port, ws_bind, tls)
	if err != OK:
		printerr("Couldn't start the server (error %d). Are UDP %d and TCP %d free (ports below 1024 need permission)?"
			% [err, udp_port, ws_port])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	print("Super Tenet server: UDP %d, %s on TCP %d. Waiting for players."
		% [udp_port, "HTTPS WebSocket" if tls != null else "plain WebSocket (testing)", ws_port])


## Loads the server's key and certificate from `dir`, making them the first
## time. The certificate (not the key) is what goes into assets/server.crt.
func _server_tls(dir: String) -> TLSOptions:
	var key_path := dir.path_join("server.key")
	var cert_path := dir.path_join("server.crt")
	var key := CryptoKey.new()
	var cert := X509Certificate.new()
	var have := FileAccess.file_exists(key_path) and FileAccess.file_exists(cert_path)
	if not have or key.load(key_path) != OK or cert.load(cert_path) != OK:
		DirAccess.make_dir_recursive_absolute(dir)
		var crypto := Crypto.new()
		key = crypto.generate_rsa(2048)
		cert = crypto.generate_self_signed_certificate(key, "CN=%s,O=Super Tenet" % SERVER_NAME,
			"20250101000000", "20450101000000")
		if key.save(key_path) != OK or cert.save(cert_path) != OK:
			printerr("Couldn't write the server key and certificate to ", dir)
			return null
		print("Made a new server certificate: ", cert_path)
	return TLSOptions.server(key, cert)


## Host side (LAN host or dedicated server): someone connected. They join the
## match lobby if there's room and no game is running.
func _member_join(id: int) -> void:
	var how := "UDP"
	if multiplayer.multiplayer_peer.has_method("transport_of"):
		how = multiplayer.multiplayer_peer.transport_of(id)
	if phase != Phase.LOBBY or _party_order.size() >= MAX_PLAYERS:
		_log_event("player %d (%s) turned away: game full or already running" % [id, how])
		server_busy.rpc_id(id)
		get_tree().create_timer(0.5).timeout.connect(func():
			if multiplayer.multiplayer_peer != null:
				multiplayer.multiplayer_peer.disconnect_peer(id))
		return
	if _party_order.is_empty():
		_party_resume = false
	_party_add(id, "PLAYER")
	_log_event("player %d connected via %s (%d/%d)" % [id, how, _party_order.size(), MAX_PLAYERS])
	_update_advertising()
	_party_broadcast("")


## Host side: someone left. A running game carries on while both roles are
## still covered; otherwise everyone goes back to the match lobby (same room).
func _member_left(id: int) -> void:
	if not _party.has(id):
		return
	var who: String = _party[id]["name"]
	_log_event("player %d left" % id)
	_party_remove(id)
	if phase != Phase.LOBBY and _in_roster(id):
		if _party_viable():
			player_left.rpc(id)
			return
		_clear_round()
		round_id += 1
		phase = Phase.LOBBY
		_party_resume = _can_resume()
	if _party_order.is_empty():
		_party_resume = false
	_update_advertising()
	if not _dedicated and _party_order.size() <= 1:
		_host_show_waiting("%s left." % who)
	else:
		_party_broadcast("%s left." % who)


## LAN host alone again: back to the hosting screen (still hosting).
func _host_show_waiting(note: String) -> void:
	_party_resume = false
	hud.visible = false
	hand.visible = false
	pause.visible = false
	lobby.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	lobby.show_hosting(_hosting_args[0], _hosting_args[1], _hosting_args[2], true, note)


## LAN host: announce the game while the lobby has room, stop otherwise.
func _update_advertising() -> void:
	if _dedicated or _net_role != "host":
		return
	var want := phase == Phase.LOBBY and _party_order.size() < MAX_PLAYERS
	if want and not _advertising:
		lan.start_advertising(_hosting_args[0], lobby.player_name())
	elif not want and _advertising:
		lan.stop_advertising()
	_advertising = want


func _in_roster(id: int) -> bool:
	for r in roster:
		if r[0] == id:
			return true
	return false


# --- Match lobby (pick roles, ready up) ---------------------------------------------

func _party_reset() -> void:
	_party.clear()
	_party_order.clear()
	_party_resume = false


## Newcomers join the smaller column (normal on a tie).
func _party_add(id: int, player_name: String) -> void:
	var normal := 0
	var inverted := 0
	for m in _party.values():
		if m["role"] == ROLE_FORWARD:
			normal += 1
		else:
			inverted += 1
	_party[id] = {"name": player_name, "role": ROLE_REVERSE if inverted < normal else ROLE_FORWARD, "ready": false}
	_party_order.append(id)


## A game needs at least one normal and one inverted player.
func _party_viable() -> bool:
	var roles := {}
	for m in _party.values():
		roles[m["role"]] = true
	return roles.has(ROLE_FORWARD) and roles.has(ROLE_REVERSE)


func _party_remove(id: int) -> void:
	_party.erase(id)
	_party_order.erase(id)
	for m in _party.values():
		m["ready"] = false


## Calls a host-side handler: directly when we are the host, else by RPC.
func _to_host(method: String, args: Array = []) -> void:
	if multiplayer.is_server():
		callv(method, args)
	else:
		var call_args := [1]
		call_args.append_array(args)
		Callable(self, method).rpc_id.callv(call_args)


## Who sent the RPC being handled (ourselves when called directly).
func _sender() -> int:
	var id := multiplayer.get_remote_sender_id()
	return id if id != 0 else multiplayer.get_unique_id()


func _party_broadcast(note: String) -> void:
	var members := []
	for id in _party_order:
		var m: Dictionary = _party[id]
		members.append([id, m["name"], m["role"], m["ready"]])
	var info := "NEW GAME"
	if _party_resume and Maps.is_fixed(_round_mode):
		info = "%s  ·  ATTEMPT %d" % [Maps.display_name(_round_mode), _resume_attempt()]
	elif _party_resume and _round_mode == "endless":
		info = "ROOM %d  ·  SAME RUN" % (room_no + (1 if _round_end == "cleared" else 0))
	elif _party_resume:
		info = "ROOM %d  ·  ATTEMPT %d  ·  SAME MAP" % [room_no, _resume_attempt()]
	party_state.rpc(members, info, note, _slowmo_enabled, _party_leader(), _map_id)


## Host -> a new client: which protocol the host speaks.
@rpc("authority", "call_remote", "reliable")
func welcome(host_protocol: int) -> void:
	if host_protocol != PROTOCOL:
		_back_to_lobby(_version_message(host_protocol), true)


func _version_message(other: int) -> String:
	return "Version mismatch: the other side runs game version %d, you run %d. Use the same build on both (and on the server)." \
		% [other, PROTOCOL]


@rpc("authority", "call_remote", "reliable")
func version_refused(host_protocol: int) -> void:
	_back_to_lobby(_version_message(host_protocol), true)


@rpc("any_peer", "call_remote", "reliable")
func party_hello(player_name: String, client_protocol: int) -> void:
	var id := _sender()
	if not multiplayer.is_server():
		return
	if client_protocol != PROTOCOL:
		_log_event("player %d refused: protocol %d, ours %d" % [id, client_protocol, PROTOCOL])
		version_refused.rpc_id(id, PROTOCOL)
		_party_remove(id)
		get_tree().create_timer(0.5).timeout.connect(func():
			if multiplayer.multiplayer_peer != null:
				multiplayer.multiplayer_peer.disconnect_peer(id))
		_party_broadcast("")
		return
	if _party.has(id):
		_party[id]["name"] = player_name.strip_edges().to_upper().left(16)
		_party_broadcast("")


## The match lobby's host: the LAN player who hosted, or online the player
## who joined the server first. Only they pick roles and options.
func _party_leader() -> int:
	return _party_order[0] if not _party_order.is_empty() else 0


## Anyone: join the normal or inverted column. Everyone's ready resets.
@rpc("any_peer", "call_remote", "reliable")
func party_pick(role: int) -> void:
	_party_set_role(_sender(), role)


## The host: move a player to the other column.
@rpc("any_peer", "call_remote", "reliable")
func party_move(target: int, role: int) -> void:
	if _sender() == _party_leader():
		_party_set_role(target, role)


func _party_set_role(id: int, role: int) -> void:
	if not multiplayer.is_server() or not _party.has(id) or phase != Phase.LOBBY or role < 0 or role > 1:
		return
	if _party[id]["role"] == role:
		return
	_party[id]["role"] = role
	for m in _party.values():
		m["ready"] = false
	_party_broadcast("")


@rpc("any_peer", "call_remote", "reliable")
func party_ready(ready: bool) -> void:
	var id := _sender()
	if not multiplayer.is_server() or not _party.has(id) or phase != Phase.LOBBY:
		return
	_party[id]["ready"] = ready
	var all_ready := _party.size() >= 2 and _party_viable()
	for m in _party.values():
		all_ready = all_ready and m["ready"]
	if all_ready:
		_party_start()
	else:
		_party_broadcast("")


## The host turns "time slows while both stand still" on or off.
@rpc("any_peer", "call_remote", "reliable")
func party_set_slowmo(on: bool) -> void:
	var id := _sender()
	if not multiplayer.is_server() or id != _party_leader() or phase != Phase.LOBBY:
		return
	_slowmo_enabled = on
	for m in _party.values():
		m["ready"] = false
	_party_broadcast("The host turned time slowing %s." % ("on" if on else "off"))


## The host picks the map (only maps that are ready to play).
@rpc("any_peer", "call_remote", "reliable")
func party_set_map(id: String) -> void:
	if not multiplayer.is_server() or _sender() != _party_leader() or phase != Phase.LOBBY \
			or not Lobby.map_available(id) or id == _map_id:
		return
	_map_id = id
	_party_resume = false  # a different map is a new game
	for m in _party.values():
		m["ready"] = false
	_party_broadcast("")


## Either player, in game: everyone back to the match lobby, same room.
@rpc("any_peer", "call_remote", "reliable")
func request_party() -> void:
	if not multiplayer.is_server() or phase == Phase.LOBBY or _party.size() < 2:
		return
	var who: String = _party.get(_sender(), {}).get("name", "YOUR PARTNER")
	_clear_round()
	round_id += 1  # cancels any pending restart
	phase = Phase.LOBBY
	_party_resume = _can_resume()
	for m in _party.values():
		m["ready"] = false
	_party_broadcast("%s wants to change roles." % who)


## Going back to the lobby keeps the game going, except after an Endless
## run has ended: there are no retries.
## Same for a hand-made map that was just cleared.
func _can_resume() -> bool:
	if _round_mode == "endless" and _round_end == "died":
		return false
	return not (Maps.is_fixed(_round_mode) and _round_end == "cleared")


## The attempt number a resumed game continues with: a death that just
## happened still counts, going to the lobby itself doesn't.
func _resume_attempt() -> int:
	return attempt + 1 if _round_end == "died" else attempt


func _party_start() -> void:
	var team := []
	for id in _party_order:
		team.append([id, _party[id]["role"], _party[id]["name"]])
	for m in _party.values():
		m["ready"] = false
	# A different number of players means a different room.
	var same_team_size := team.size() == roster.size()
	if _party_resume and _round_end != "cleared" and same_team_size:
		start_round.rpc(room_seed, room_no, _resume_attempt(), team, _map_id)
	elif _party_resume:
		start_round.rpc(_new_seed(), room_no + (1 if _round_end == "cleared" else 0), 1, team, _map_id)
	else:
		start_round.rpc(_new_seed(), 1, 1, team, _map_id)
	_party_resume = false


## Host -> everyone: the match lobby as it stands. Leaves any running round.
@rpc("authority", "call_local", "reliable")
func party_state(members: Array, info: String, note: String, slowmo: bool, leader: int, map_id: String) -> void:
	if _dedicated:
		return
	if phase != Phase.LOBBY:
		_clear_round()
		phase = Phase.LOBBY
	hud.visible = false
	hand.visible = false
	pause.visible = false
	lobby.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var list := []
	for m in members:
		list.append({"id": m[0], "name": m[1], "role": m[2], "ready": m[3]})
	lobby.show_party(list, multiplayer.get_unique_id(), leader, info, slowmo, map_id, note)
	_log_event("match lobby: %s" % [members])
	# The test bot readies up as soon as it has company.
	if _bot_mode and members.size() >= _bot_wait_players:
		for m in list:
			if m["id"] == multiplayer.get_unique_id() and not m["ready"]:
				if _bot_swap_pending and leader == multiplayer.get_unique_id():
					# Test: the host swaps sides with everyone on the other side.
					_bot_swap_pending = false
					var mine: int = m["role"]
					get_tree().create_timer(0.2).timeout.connect(func():
						for other in list:
							if other["id"] != m["id"] and other["role"] != mine:
								_to_host("party_move", [other["id"], mine])
						_to_host("party_pick", [1 - mine]))
				else:
					get_tree().create_timer(0.2).timeout.connect(func(): _to_host("party_ready", [true]))


@rpc("authority", "call_remote", "reliable")
func server_busy() -> void:
	_back_to_lobby("That game is full or already playing. Try again in a bit.", true)


# --- Joining a server online ---------------------------------------------------------

## `address` is an IP (or host name), "ip:udp_port", or a full ws:// / wss:// URL.
func join_online(address: String) -> void:
	var text := address.strip_edges()
	if text == "":
		lobby.show_menu("Set the server address first.", true)
		return
	_relayed = true
	_auto_join_lan = false
	lan.stop_searching()
	if text.begins_with("ws://") or text.begins_with("wss://"):
		_online_ws_url = text
		_try_ws()
		return
	var host := text
	var port := Lobby.DEFAULT_PORT
	if text.count(":") == 1:
		host = text.get_slice(":", 0)
		port = text.get_slice(":", 1).to_int()
	_online_ws_url = "wss://%s:%d" % [host, WS_PORT]
	_try_udp(host, port)


func _try_udp(host: String, port: int) -> void:
	_conn_stage = "udp"
	_conn_attempt += 1
	var attempt := _conn_attempt
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(host, port) != OK:
		_try_ws()
		return
	multiplayer.multiplayer_peer = peer
	_net_role = "client"
	lobby.show_busy("CONNECTING TO %s" % host.to_upper())
	_log_event("trying UDP to %s:%d" % [host, port])
	get_tree().create_timer(UDP_TRY_SECONDS).timeout.connect(func():
		if attempt == _conn_attempt and _conn_stage == "udp":
			_try_ws())


func _try_ws() -> void:
	_conn_stage = "ws"
	_conn_attempt += 1
	var attempt := _conn_attempt
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	var peer := WebSocketMultiplayerPeer.new()
	var tls: TLSOptions = null
	if _online_ws_url.begins_with("wss://"):
		tls = _pinned_tls()
		if tls == null:
			_back_to_lobby("This build has no server certificate (assets/server.crt), so it can't use the HTTPS route. See server/README.md.", true)
			return
	if peer.create_client(_online_ws_url, tls) != OK:
		_online_failed()
		return
	multiplayer.multiplayer_peer = peer
	_net_role = "client"
	lobby.show_busy("CONNECTING OVER HTTPS")
	_log_event("trying WebSocket %s" % _online_ws_url)
	get_tree().create_timer(WS_TRY_SECONDS).timeout.connect(func():
		if attempt == _conn_attempt and _conn_stage == "ws":
			_online_failed())


## Trust exactly our server's certificate (checked in full, including its
## name), rather than the usual certificate authorities: the server has an
## IP address, not a domain, so no public authority could vouch for it.
func _pinned_tls() -> TLSOptions:
	if not FileAccess.file_exists(SERVER_CERT):
		return null
	var cert := X509Certificate.new()
	if cert.load(SERVER_CERT) != OK:
		return null
	return TLSOptions.client(cert, SERVER_NAME)


func _online_failed() -> void:
	_back_to_lobby("Couldn't reach the server over UDP or HTTPS. Check the address, and that the server is running.", true)


func _connected() -> bool:
	var p := multiplayer.multiplayer_peer
	return p != null and not (p is OfflineMultiplayerPeer) \
		and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _new_seed() -> int:
	return randi() & 0x7fffffff


# --- Rounds ------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
## `team`: [peer id, role, name] for every player in this round. `mode`: the
## map picked in the match lobby; Endless gets harder with every room.
func start_round(seed_in: int, number: int, try_no: int, team: Array, mode: String) -> void:
	_clear_round()
	round_id += 1
	room_seed = seed_in
	room_no = number
	attempt = try_no
	_round_end = ""
	_round_mode = mode
	_tut_step = clampi(number - 1, 0, TUT_STEPS.size() - 1) if mode == "tutorial_b" else 0
	_tut_mark = 0
	_recalls_done = 0
	roster = team
	if Maps.is_fixed(mode):
		room = Maps.build(mode, team.size())
	else:
		room = RoomGen.generate(seed_in, team.size(), _difficulty(mode, number))
	astar = RoomBuilder.build_astar(room)
	round_root = Node3D.new()
	round_root.name = "Round"
	add_child(round_root)
	round_root.add_child(RoomBuilder.build(room))

	var me := multiplayer.get_unique_id()
	var first_normal := 0
	for i in team.size():
		var entry: Array = team[i]
		var p := Player.new()
		p.setup(entry[0], entry[1], entry[0] == me)
		p.player_name = entry[2]
		round_root.add_child(p)
		p.place(RoomGen.cell_center(room.spawns[i]) + Vector3(0, 0.05, 0), PI)
		players[entry[0]] = p
		if first_normal == 0 and entry[1] == ROLE_FORWARD:
			first_normal = entry[0]
	_face_teammates()
	local_player = players.get(me)

	for i in room.enemy_cells.size():
		var e := Enemy.new()
		e.id = i
		e.kind = room.enemy_kinds[i]
		e.pace = room.pace
		e.dummy = room.enemy_dummy[i] == 1
		e.game = self
		e.astar = astar
		e.position = RoomGen.cell_center(room.enemy_cells[i])
		round_root.add_child(e)
		enemies.append(e)
	_enemies_left = enemies.size()
	# Tutorial B: groups from earlier steps are already beaten, later ones wait.
	for i in enemies.size():
		var group: int = room.enemy_groups[i]
		if group > 0:
			if TUT_WAKE[group] < _tut_step:
				enemies[i].die()
				_enemies_left -= 1
			elif TUT_WAKE[group] > _tut_step:
				enemies[i].set_active(false)
	_enemy_buf.resize(enemies.size() * 3 + 1)

	gun = Gun.new()
	round_root.add_child(gun)
	gun.set_loaded(true)
	if room.gun_cell.x >= 0 and _tut_step == 0:
		gun.drop_at(RoomGen.cell_center(room.gun_cell))  # the tutorial gun lies on the floor
	else:
		gun.hold(players[first_normal])
	bullet = Bullet.new()
	round_root.add_child(bullet)
	bullet.enemy_hit.connect(_on_bullet_enemy_hit)
	bullet.player_hit.connect(_on_bullet_player_hit)
	bullet.stopped.connect(_on_bullet_stopped)
	bullet.arrived.connect(_on_bullet_arrived)
	tracers = Tracers.new()
	round_root.add_child(tracers)
	if local_player != null:
		tracers.local_body = local_player
		for mate in teammates():
			tracers.ignore.append(mate.get_rid())  # their own machine decides their hits
		tracers.hit_local.connect(_on_local_shot)
	debris = Debris.new()
	round_root.add_child(debris)
	aim_line = AimLine.new()
	round_root.add_child(aim_line)

	bullet_seq = 0
	_claim_pending = false
	phase = Phase.PLAYING
	_update_carry()

	lan.stop_advertising()  # nobody joins mid-game
	_advertising = false
	lan.stop_searching()
	var normals := []
	var inverts := []
	for entry in team:
		(normals if entry[1] == ROLE_FORWARD else inverts).append(entry[0])
	_log_event("round %d try %d seed %d mode %s: %d players, %d enemies, pace %.2f, normal=%s inverted=%s"
		% [number, try_no, seed_in, mode, team.size(), enemies.size(), room.pace, normals, inverts])
	if local_player == null:
		return  # dedicated server: no screen to update
	lobby.visible = false
	pause.visible = false
	local_player.input_enabled = true
	hud.visible = true
	hand.visible = true
	hud.role = local_player.role
	hand.role = local_player.role
	hand.player = local_player
	hud.clear_banners()
	hud.attempt = try_no
	hud.best = -1
	if mode == "endless":
		hud.room_no = number
		hud.best = Lobby.record_endless(team.size(), number)
	if mode == "tutorial_b":
		_step_banner()
	else:
		hud.banner(Maps.display_name(mode) if Maps.is_fixed(mode) else "ROOM %d" % number, Palette.SIGNAL)
	if not _bot_mode:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Endless rooms follow the Endless curve (room 1 = level 0); others are normal (-1).
static func _difficulty(mode: String, number: int) -> int:
	return number - 1 if mode == "endless" else -1


func _clear_round() -> void:
	if round_root != null:
		remove_child(round_root)
		round_root.queue_free()
	round_root = null
	players.clear()
	enemies.clear()
	_targeted.clear()
	local_player = null
	_spec_target = null
	_spec_cam = null
	hud.spectating = ""
	gun = null
	bullet = null
	tracers = null
	debris = null
	aim_line = null
	Clock.scale = 1.0
	_host_time_target = 1.0


## Runs `fn` after `seconds` unless a new round started in between.
func _later(seconds: float, fn: Callable) -> void:
	var rid := round_id
	get_tree().create_timer(seconds).timeout.connect(func():
		if rid == round_id and phase != Phase.LOBBY:
			fn.call())


@rpc("authority", "call_local", "reliable")
func room_cleared() -> void:
	phase = Phase.OVER
	_round_end = "cleared"
	if Maps.is_tutorial(_round_mode):
		hud.banner("TRAINING COMPLETE", Palette.ENEMY, TUT_BANNER_HOLD)
	else:
		hud.banner("CLEAR!", Palette.ENEMY)
	_log_event("room cleared")
	if Maps.is_fixed(_round_mode):
		# A hand-made map is done once it's cleared: back to the match lobby.
		var map_name := Maps.display_name(_round_mode)
		if not _dedicated:
			Lobby.record_cleared(_round_mode)
		if multiplayer.is_server():
			_later(NEXT_ROOM_DELAY, func(): _finish_game("%s cleared in %d %s!"
				% [map_name, attempt, "try" if attempt == 1 else "tries"]))
		return
	if multiplayer.is_server():
		_later(NEXT_ROOM_DELAY, func(): start_round.rpc(_new_seed(), room_no + 1, 1, roster, _round_mode))


## A player died. The attempt goes on until everyone is down; the dead
## spectate a teammate. A dead player's gun drops where they fell.
@rpc("any_peer", "call_local", "reliable")
func player_down(peer: int, cause: String) -> void:
	if phase != Phase.PLAYING:
		return
	var p: Player = players.get(peer)
	if p == null or not p.alive:
		return
	p.kill()
	var me := peer == multiplayer.get_unique_id()
	hud.banner("YOU DIED" if me else "%s DOWN" % p.player_name, Palette.DANGER)
	if me:
		hud.went_down()
	_log_event("player %d down (%s)" % [peer, cause])
	if gun != null and gun.state == Gun.HELD and gun.holder == p:
		gun.drop_at(p.global_position)
		_update_carry()
	if Maps.is_tutorial(_round_mode):
		# Tutorials don't leave anyone spectating: try the step again.
		phase = Phase.OVER
		_round_end = "died"
		hud.banner("TRY AGAIN", Palette.DANGER)
		if multiplayer.is_server():
			var step := _tut_step
			_later(RESTART_DELAY, func(): start_round.rpc(room_seed, step + 1, attempt + 1, roster, _round_mode))
		return
	if me:
		_later(1.2, _spectate_next)
	if multiplayer.is_server():
		_check_all_down()


## Host: when nobody is left standing, the attempt is over.
func _check_all_down() -> void:
	if phase == Phase.PLAYING and living_players().is_empty():
		all_down.rpc()


@rpc("authority", "call_local", "reliable")
func all_down() -> void:
	phase = Phase.OVER
	_round_end = "died"
	if _round_mode == "endless":
		# No retries: the run is over and everyone goes back to the match lobby.
		hud.banner("RUN OVER  ·  ROOM %d" % room_no, Palette.DANGER)
		_log_event("run over at room %d" % room_no)
		if multiplayer.is_server():
			var reached := room_no
			_later(RUN_OVER_DELAY, func(): _finish_game("Run over at room %d." % reached))
		return
	hud.banner("EVERYONE'S DOWN", Palette.DANGER)
	_log_event("everyone down")
	if multiplayer.is_server():
		_later(RESTART_DELAY, func(): start_round.rpc(room_seed, room_no, attempt + 1, roster, _round_mode))


## Host: an Endless run ended or a hand-made map was cleared. Everyone back
## to the match lobby for a new game.
func _finish_game(note: String) -> void:
	_clear_round()
	round_id += 1
	phase = Phase.LOBBY
	_party_resume = false
	for m in _party.values():
		m["ready"] = false
	_update_advertising()
	if not _dedicated and _party_order.size() <= 1:
		_host_show_waiting(note)
	else:
		_party_broadcast(note)


## Host -> everyone: a player left mid-game and the rest carry on.
@rpc("authority", "call_local", "reliable")
func player_left(peer: int) -> void:
	var p: Player = players.get(peer)
	for i in range(roster.size() - 1, -1, -1):
		if roster[i][0] == peer:
			roster.remove_at(i)
	if p == null:
		return
	hud.banner("%s LEFT" % p.player_name, Palette.DANGER)
	if gun != null and gun.state == Gun.HELD and gun.holder == p:
		gun.drop_at(p.global_position)
	players.erase(peer)
	p.queue_free()
	_update_carry()
	if multiplayer.is_server():
		_check_all_down()


@rpc("any_peer", "call_remote", "reliable")
func request_restart() -> void:
	if multiplayer.is_server() and phase != Phase.LOBBY:
		if _round_mode == "endless":
			start_round.rpc(_new_seed(), 1, 1, roster, _round_mode)  # a fresh run
		else:
			start_round.rpc(room_seed, room_no, attempt + 1, roster, _round_mode)


func _local_died(cause: String) -> void:
	if phase != Phase.PLAYING or local_player == null or not local_player.alive:
		return
	player_down.rpc(multiplayer.get_unique_id(), cause)


# --- Input -------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if phase == Phase.LOBBY:
		return
	if event.is_action_pressed("release_mouse"):
		if pause.visible:
			_close_pause()
		else:
			_open_pause()
		return
	if pause.visible:
		return
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
	elif local_player != null and not local_player.alive \
			and (event.is_action_pressed("primary") or event.is_action_pressed("jump")):
		_spectate_next()
	elif event.is_action_pressed("primary"):
		try_primary()
	elif event.is_action_pressed("throw"):
		try_throw()
	elif event.is_action_pressed("restart"):
		if multiplayer.is_server():
			request_restart()
		else:
			request_restart.rpc_id(1)


## At the start of a round everyone turns to face their teammates (with two
## players, each other).
func _face_teammates() -> void:
	for p in players.values():
		var center := Vector3.ZERO
		for other in players.values():
			if other != p:
				center += other.global_position
		center /= maxf(players.size() - 1, 1)
		var d: Vector3 = center - p.global_position
		if Vector2(d.x, d.z).length() > 0.1:
			p.place(p.global_position, atan2(-d.x, -d.z))


## Everyone else in this round.
func teammates() -> Array:
	var out := []
	for p in players.values():
		if p != local_player:
			out.append(p)
	return out


## Dead players watch a living teammate; click (or Space) for the next one.
func _spectate_next() -> void:
	if local_player == null or local_player.alive or phase == Phase.LOBBY:
		return
	var living := []
	for p in teammates():
		if p.alive:
			living.append(p)
	if living.is_empty():
		return
	var next: Player = living[(living.find(_spec_target) + 1) % living.size()]
	_spec_target = next
	if _spec_cam == null or not is_instance_valid(_spec_cam):
		_spec_cam = Camera3D.new()
		_spec_cam.fov = 82.0
		_spec_cam.near = 0.05
	if _spec_cam.get_parent() != null:
		_spec_cam.get_parent().remove_child(_spec_cam)
	next.head.add_child(_spec_cam)
	_spec_cam.position = Vector3(0, 0.05, -0.32)  # just in front of their visor
	_spec_cam.make_current()
	hud.spectating = next.player_name


func _open_pause() -> void:
	pause.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if local_player != null:
		local_player.input_enabled = false


func _close_pause(capture := true) -> void:
	pause.visible = false
	if local_player != null:
		local_player.input_enabled = true
	if capture and phase != Phase.LOBBY and not _bot_mode:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func i_hold_gun() -> bool:
	return gun != null and gun.state == Gun.HELD and gun.holder == local_player and not _claim_pending


func can_fire() -> bool:
	return phase == Phase.PLAYING and local_player.alive and local_player.role == ROLE_FORWARD \
		and i_hold_gun() and gun.loaded and bullet.state == Bullet.IN_GUN


func can_recall() -> bool:
	return phase == Phase.PLAYING and local_player.alive and local_player.role == ROLE_REVERSE \
		and i_hold_gun() and not gun.loaded and bullet.state == Bullet.LODGED


func try_primary() -> void:
	var me := multiplayer.get_unique_id()
	if can_fire():
		# Simulate from the eye so a gun poking into a wall can't shoot through it.
		bullet_seq += 1
		bullet_fired.rpc(bullet_seq, me, local_player.eye_pos(), local_player.aim_dir())
	elif can_recall():
		bullet_seq += 1
		bullet_recall.rpc(bullet_seq, me)


func try_throw() -> void:
	if phase != Phase.PLAYING or not local_player.alive or not i_hold_gun():
		return
	if bullet.state == Bullet.RECALL:
		return  # the bullet is flying into this gun
	var eye := local_player.eye_pos()
	var from := eye + local_player.aim_dir() * 0.6
	if _ray_world(eye, from) != null:
		from = eye
	gun_thrown.rpc(multiplayer.get_unique_id(), from, _throw_velocity(from))


## Aim assist: if a teammate is roughly in the crosshair and visible, lead
## them and throw on an arc that reaches their chest.
func _throw_velocity(from: Vector3) -> Vector3:
	var aim := local_player.aim_dir()
	# The living teammate closest to the crosshair, if any is near it and visible.
	var best: Player = null
	var best_dot := cos(deg_to_rad(THROW_ASSIST_DEG))
	for mate in teammates():
		if not mate.alive:
			continue
		var dot := aim.dot((mate.chest_pos() - from).normalized())
		if dot > best_dot and _ray_world(from, mate.chest_pos()) == null:
			best = mate
			best_dot = dot
	if best != null:
		var target := best.chest_pos()
		var flight := clampf((target - from).length() / Traj.THROW_SPEED, 0.3, 1.1)
		var lead := best.velocity_estimate() * flight
		lead.y = 0.0
		return Traj.throw_velocity(from, target + lead)
	return Traj.free_throw_velocity(aim)


## Who the gun should go to next: the nearest living teammate who can use it
## (normal players when it's loaded, inverted ones when it's empty).
func pass_target() -> Player:
	var best: Player = null
	var best_d := INF
	var want := ROLE_FORWARD if gun != null and gun.loaded else ROLE_REVERSE
	for mate in teammates():
		if mate.alive and mate.role == want:
			var d := local_player.global_position.distance_to(mate.global_position)
			if d < best_d:
				best = mate
				best_d = d
	return best


# --- Bullet events -------------------------------------------------------------------

@rpc("any_peer", "call_local", "reliable")
func bullet_fired(seq: int, shooter_id: int, from: Vector3, dir: Vector3) -> void:
	var shooter: Player = players.get(shooter_id)
	if shooter == null or bullet == null:
		return
	var mine := shooter_id == multiplayer.get_unique_id()
	bullet_seq = seq
	_action_kills = 0
	gun.set_loaded(false)
	bullet.fire(from, dir, shooter, mine, 0.0 if mine else _one_way())
	if mine:
		hand.play_fire()
	if multiplayer.is_server():
		for e in enemies:
			e.alert()  # everyone heard that
	_log_event("A fired")


@rpc("any_peer", "call_local", "reliable")
func bullet_recall(seq: int, recaller_id: int) -> void:
	var recaller: Player = players.get(recaller_id)
	if recaller == null or bullet == null:
		return
	var mine := recaller_id == multiplayer.get_unique_id()
	bullet_seq = seq
	_action_kills = 0
	bullet.recall(recaller, mine, 0.0 if mine else _one_way())
	_log_event("B recalling")


@rpc("any_peer", "call_local", "reliable")
func bullet_lodged(seq: int, pos: Vector3, dir: Vector3, normal: Vector3, kills: int, was_recall: bool) -> void:
	if bullet == null or seq != bullet_seq:
		return
	bullet.set_lodged(pos, dir, normal)
	_kill_banner(kills, was_recall)
	if was_recall:
		hud.banner("BLOCKED!", Palette.DANGER)
	_log_event("bullet stuck (%s) at %s kills=%d" % ["recall blocked" if was_recall else "shot", pos.snapped(Vector3.ONE * 0.1), kills])


@rpc("any_peer", "call_local", "reliable")
func bullet_arrived(seq: int, kills: int) -> void:
	if bullet == null or seq != bullet_seq:
		return
	bullet.reset()
	gun.set_loaded(true)
	_recalls_done += 1
	if gun.holder == local_player:
		hand.play_recall_catch()
	_kill_banner(kills, true)
	_log_event("bullet back in gun kills=%d" % kills)


func _on_bullet_enemy_hit(enemy: Node3D, dir: Vector3) -> void:
	if not bullet.authority or not enemy.alive:
		return
	_action_kills += 1
	hud.hit()
	if multiplayer.is_server():
		_kill_enemy(enemy.id, dir)
	else:
		request_kill.rpc_id(1, enemy.id, dir)


func _on_bullet_player_hit(p: Node3D) -> void:
	if p == local_player:
		_local_died("friendly fire")


func _on_bullet_stopped(pos: Vector3, dir: Vector3, normal: Vector3) -> void:
	var was_recall: bool = bullet.shooter.role == ROLE_REVERSE
	bullet_lodged.rpc(bullet_seq, pos, dir, normal, _action_kills, was_recall)


func _on_bullet_arrived() -> void:
	bullet_arrived.rpc(bullet_seq, _action_kills)


func _kill_banner(kills: int, was_recall: bool) -> void:
	if kills <= 0:
		return
	var word: String = KILL_WORDS[kills] if kills < KILL_WORDS.size() else "x%d!" % kills
	hud.banner(word, Palette.REVERSE if was_recall else Palette.FORWARD)


# --- Gun events ------------------------------------------------------------------------

@rpc("any_peer", "call_local", "reliable")
func gun_thrown(thrower_id: int, from: Vector3, vel: Vector3) -> void:
	var thrower: Player = players.get(thrower_id)
	if thrower == null or gun == null:
		return
	var mine := thrower_id == multiplayer.get_unique_id()
	gun.throw(from, vel, thrower, 0.0 if mine else _one_way())
	if mine:
		hand.play_throw()
	_update_carry()
	_log_event("gun thrown by %s" % _role_name(thrower))


func _check_gun_pickup() -> void:
	if _claim_pending or gun.state == Gun.HELD:
		return
	var me := local_player
	if gun.thrower == me and gun.since_throw < THROWER_GRACE:
		return
	if gun.state == Gun.FLYING:
		if gun.global_position.distance_to(me.chest_pos()) < CATCH_RADIUS:
			_claim_gun()
	else:
		var d: Vector3 = gun.global_position - me.global_position
		d.y = 0.0
		if d.length() < PICKUP_RADIUS:
			_claim_gun()


func _claim_gun() -> void:
	_claim_pending = true
	if multiplayer.is_server():
		_grant_gun(multiplayer.get_unique_id())
	else:
		request_gun.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func request_gun() -> void:
	if multiplayer.is_server():
		_grant_gun(multiplayer.get_remote_sender_id())


## Host decides who gets a loose gun (first claim wins).
func _grant_gun(peer: int) -> void:
	if gun == null:
		return
	if gun.state == Gun.HELD and gun.holder != null:
		gun_taken.rpc(gun.holder.peer_id)  # deny: repeat the current holder
	else:
		gun_taken.rpc(peer)


@rpc("authority", "call_local", "reliable")
func gun_taken(peer: int) -> void:
	var p: Player = players.get(peer)
	if p == null or gun == null:
		return
	var was_loose: bool = gun.state != Gun.HELD
	gun.hold(p)
	_claim_pending = false
	if p == local_player and was_loose:
		hand.play_catch()
	_update_carry()
	_log_event("gun caught by %s" % _role_name(p))


func _update_carry() -> void:
	for p in players.values():
		p.carrying = gun != null and gun.state == Gun.HELD and gun.holder == p
	hand.holding = i_hold_gun() or (_claim_pending and gun != null and gun.state != Gun.HELD)
	hand.loaded = gun != null and gun.loaded


# --- Enemies ---------------------------------------------------------------------------

func living_players() -> Array:
	var out := []
	for p in players.values():
		if p.alive:
			out.append(p)
	return out


func _kill_enemy(id: int, dir: Vector3) -> void:
	if id < 0 or id >= enemies.size() or not enemies[id].alive:
		return
	enemy_killed.rpc(id, dir)


@rpc("any_peer", "call_remote", "reliable")
func request_kill(id: int, dir: Vector3) -> void:
	if multiplayer.is_server():
		_kill_enemy(id, dir)


@rpc("authority", "call_local", "reliable")
func enemy_killed(id: int, dir: Vector3) -> void:
	if id < 0 or id >= enemies.size() or not enemies[id].alive:
		return
	var e: Node3D = enemies[id]
	e.die()
	debris.burst(e.global_position, dir)
	fx.punch()
	_enemies_left -= 1
	_log_event("enemy %d killed, %d left" % [id, _enemies_left])
	if multiplayer.is_server() and _enemies_left <= 0 and phase == Phase.PLAYING:
		room_cleared.rpc()


func announce_windup(e: Node3D, target: Node3D, seconds: float) -> void:
	if _peaceful:
		return
	enemy_windup.rpc(e.id, target.peer_id if target != null else 0, seconds)


func announce_strike(e: Node3D, origin: Vector3, dir: Vector3) -> void:
	if _peaceful:
		return
	enemy_strike.rpc(e.id, origin, dir)


@rpc("authority", "call_local", "reliable")
func enemy_windup(id: int, target_peer: int, seconds: float) -> void:
	if id >= 0 and id < enemies.size() and enemies[id].alive:
		enemies[id].show_windup(players.get(target_peer), seconds)


@rpc("authority", "call_local", "reliable")
func enemy_strike(id: int, origin: Vector3, dir: Vector3) -> void:
	if id < 0 or id >= enemies.size():
		return
	var e: Node3D = enemies[id]
	e.show_strike()
	if not e.alive or phase != Phase.PLAYING:
		return
	if e.kind == RoomGen.Kind.GUNMAN:
		tracers.spawn(origin, dir, 0.0 if multiplayer.is_server() else _one_way(true))
	elif local_player != null and local_player.alive:
		var to: Vector3 = local_player.global_position - e.global_position
		to.y = 0.0
		var facing: Vector3 = -e.global_basis.z
		if to.length() < MELEE_REACH and facing.dot(to.normalized()) > 0.2:
			_local_died("melee")


func _on_local_shot() -> void:
	_local_died("shot")


## Packed enemy positions (x, z, yaw each), followed by the host's
## slow-motion target as the last value.
@rpc("authority", "call_remote", "unreliable_ordered", 2)
func enemy_sync(data: PackedFloat32Array) -> void:
	if data.is_empty():
		return
	_host_time_target = data[data.size() - 1]
	var n := mini(enemies.size(), (data.size() - 1) / 3)
	for i in n:
		enemies[i].apply_net_state(data[i * 3], data[i * 3 + 1], data[i * 3 + 2])


# --- Per-tick work ----------------------------------------------------------------------

## `flags`: Player.FLAG_CROUCH / FLAG_MOVING.
@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func net_player_state(pos: Vector3, yaw: float, pitch: float, flags: int) -> void:
	var p: Player = players.get(multiplayer.get_remote_sender_id())
	if p != null and not p.is_local:
		p.apply_net_state(pos, yaw, pitch, flags)


@rpc("any_peer", "call_remote", "unreliable")
func net_ping(t: int) -> void:
	net_pong.rpc_id(multiplayer.get_remote_sender_id(), t)


@rpc("any_peer", "call_remote", "unreliable")
func net_pong(t: int) -> void:
	var sample := (Time.get_ticks_usec() - t) / 1_000_000.0
	# Drop fast after a hitch, rise slowly: frame stalls shouldn't inflate it.
	rtt = sample if rtt <= 0.0 else lerpf(rtt, sample, 0.6 if sample < rtt else 0.15)


## Estimated delay of a message from its sender to us. Through a dedicated
## server, another player's message takes two hops (them -> server -> us).
func _one_way(from_server := false) -> float:
	var hops := 1.0 if (from_server or not _relayed) else 2.0
	return clampf(rtt * 0.5 * hops, 0.0, 0.3)


func _physics_process(delta: float) -> void:
	if not _connected():
		return
	if phase == Phase.LOBBY:
		multiplayer.poll()
		return
	if local_player != null:
		net_player_state.rpc(local_player.global_position, local_player.rotation.y, local_player.pitch(),
			local_player.net_flags())
		_ping_t -= delta
		if _ping_t <= 0.0:
			_ping_t = PING_INTERVAL
			# Ping whoever hosts: the server when relayed, else the LAN host.
			if multiplayer.is_server():
				net_ping.rpc(Time.get_ticks_usec())
			else:
				net_ping.rpc_id(1, Time.get_ticks_usec())

	_update_clock(delta)
	if multiplayer.is_server():
		_tutorial_tick()
		_sync_t -= delta
		if _sync_t <= 0.0:
			_sync_t = ENEMY_SYNC_INTERVAL
			for i in enemies.size():
				var e: Node3D = enemies[i]
				_enemy_buf[i * 3] = e.global_position.x
				_enemy_buf[i * 3 + 1] = e.global_position.z
				_enemy_buf[i * 3 + 2] = e.rotation.y
			_enemy_buf[enemies.size() * 3] = _host_time_target
			enemy_sync.rpc(_enemy_buf)

	if local_player != null and phase == Phase.PLAYING and local_player.alive:
		_check_gun_pickup()
		_update_preview()
	elif aim_line != null:
		aim_line.hide_path()
		_set_targets([])
	_update_carry()
	# Flush this tick's packets and read new ones now, instead of waiting for
	# the engine's once-per-frame poll. Cuts up to a frame each way.
	multiplayer.poll()


# --- Slow motion ------------------------------------------------------------------------

## Time slows while both players stand still and runs normally as soon as
## either moves. The host decides (it hears both players) and sends its
## decision with every enemy update; each player also speeds time up the
## moment they move themselves, without waiting for the host.
func _update_clock(delta: float) -> void:
	var target := 1.0
	# Only the host knows whether slow motion is on; everyone else follows the
	# decision it sends (always 1.0 when it's off).
	if phase == Phase.PLAYING:
		if multiplayer.is_server() and not _slowmo_on():
			target = 1.0
		elif multiplayer.is_server():
			var anyone_moving := false
			for p in players.values():
				if p.is_moving():
					anyone_moving = true
			var was := _host_time_target
			_host_time_target = 1.0 if anyone_moving or players.is_empty() else Clock.SLOW
			if was != _host_time_target:
				_log_event("time slowed" if _host_time_target < 1.0 else "time normal")
			target = _host_time_target
		else:
			target = 1.0 if local_player != null and local_player.is_moving() else _host_time_target
	var rate := SLOW_OUT_RATE if target > Clock.scale else SLOW_IN_RATE
	var was_slow := Clock.scale < 0.6
	Clock.scale = move_toward(Clock.scale, target, rate * delta)
	if was_slow != (Clock.scale < 0.6):
		_log_event("clock %s (%.2f)" % ["slow" if Clock.scale < 0.6 else "normal", Clock.scale])
	if not was_slow and Clock.scale < 0.6 and local_player != null:
		hud.banner("TIME SLOWS", Hud.SLOW_COLOR)  # big cut-in the moment it kicks in
	fx.set_slowmo(inverse_lerp(1.0, Clock.SLOW, Clock.scale))


## Slow motion is a lobby option; the tutorial's last step always has it.
func _slowmo_on() -> bool:
	return _slowmo_enabled or (_round_mode == "tutorial_b" and _tut_step >= 5)


func _process(_delta: float) -> void:
	if phase == Phase.LOBBY or local_player == null:
		return
	_update_tutorial_hud()
	_update_hud_state()
	hud.targets = _enemies_left
	hud.can_act = can_fire() or can_recall()
	hud.ping_ms = int(rtt * 1000.0) if rtt > 0.0 else -1
	if not local_player.alive and _spec_target != null and is_instance_valid(_spec_target) and not _spec_target.alive:
		_spectate_next()  # the teammate we watched went down too
	_update_markers()
	hud.slowmo = inverse_lerp(1.0, Clock.SLOW, Clock.scale)


# --- HUD ------------------------------------------------------------------------------------

## Everything the HUD shows that comes from the game state.
func _update_hud_state() -> void:
	var kinds := [0, 0, 0]
	for e in enemies:
		if e.alive:
			kinds[e.kind] += 1
	hud.kinds_left = kinds
	var team := []
	for p in teammates():
		team.append([p.player_name, p.role, p.alive, gun != null and gun.state == Gun.HELD and gun.holder == p])
	hud.team = team
	hud.move = clampf(local_player.move_amount, 0.0, 1.5) if local_player.alive else 0.0
	_update_gun_card()
	_update_prompt()
	_update_threats()


func _update_gun_card() -> void:
	if gun == null or bullet == null:
		hud.gun_line = ""
		return
	hud.gun_loaded = gun.loaded
	match gun.state:
		Gun.HELD:
			if gun.holder == local_player:
				hud.gun_line = "YOU HAVE THE GUN"
				hud.gun_line_col = Palette.role_color(local_player.role)
			else:
				hud.gun_line = "%s HAS THE GUN" % gun.holder.player_name
				hud.gun_line_col = Palette.role_color(gun.holder.role)
		Gun.FLYING:
			hud.gun_line = "GUN IN THE AIR"
			hud.gun_line_col = Palette.SIGNAL
		_:
			hud.gun_line = "GUN ON THE FLOOR"
			hud.gun_line_col = Palette.SIGNAL
	match bullet.state:
		Bullet.IN_GUN:
			hud.bullet_line = "LOADED: NORMAL FIRES IT"
			hud.bullet_line_col = Palette.FORWARD
		Bullet.FORWARD:
			hud.bullet_line = "BULLET FIRED"
			hud.bullet_line_col = Palette.FORWARD
		Bullet.LODGED:
			var d := local_player.global_position.distance_to(bullet.lodge_pos)
			hud.bullet_line = "BULLET IN THE WALL  ·  %d M" % roundi(d)
			hud.bullet_line_col = Palette.REVERSE
		Bullet.RECALL:
			hud.bullet_line = "BULLET COMING BACK"
			hud.bullet_line_col = Palette.REVERSE
		_:
			hud.bullet_line = ""


## The key to press right now, under the crosshair.
func _update_prompt() -> void:
	hud.prompt_key = ""
	hud.prompt_text = ""
	if phase != Phase.PLAYING or not local_player.alive or gun == null:
		return
	if can_fire():
		hud.prompt_key = "LMB"
		hud.prompt_text = "FIRE"
	elif can_recall():
		hud.prompt_key = "LMB"
		hud.prompt_text = "RECALL"
	elif i_hold_gun() and bullet.state != Bullet.FORWARD and bullet.state != Bullet.RECALL and not teammates().is_empty():
		hud.prompt_key = "RMB"
		hud.prompt_text = "THROW TO A TEAMMATE"


## Enemies winding up an attack on us: which way they are, and how close the
## attack is to landing.
func _update_threats() -> void:
	hud.threats.clear()
	if not local_player.alive:
		return
	var cam := local_player.camera
	for e in enemies:
		if not e.alive or e._flash <= 0.0:
			continue
		var on_me: bool = e._aim_target == local_player
		if e.kind != RoomGen.Kind.GUNMAN:
			on_me = e.global_position.distance_to(local_player.global_position) < 4.0
		if not on_me:
			continue
		var rel: Vector3 = cam.global_transform.basis.inverse() * (e.global_position - cam.global_position)
		var ang: float = atan2(rel.x, -rel.z)
		var total: float = Enemy.WINDUPS[e.kind] / e.pace
		hud.threats.append([ang, clampf(1.0 - e._flash / maxf(total, 0.01), 0.0, 1.0)])


# --- Tutorials ----------------------------------------------------------------------------

func is_tutorial() -> bool:
	return Maps.is_tutorial(_round_mode)


## Host, tutorial B: move on once the current step's goal is met.
func _tutorial_tick() -> void:
	if _round_mode != "tutorial_b" or phase != Phase.PLAYING or gun == null:
		return
	var done := false
	match _tut_step:
		0:
			done = gun.state == Gun.HELD and gun.holder.role == ROLE_FORWARD
		1:
			done = _group_beaten(1)
		2:
			done = gun.state == Gun.HELD and gun.holder.role == ROLE_REVERSE
		3:
			done = _group_beaten(2)
		4:
			done = _recalls_done > _tut_mark
	if done:
		tutorial_step.rpc(_tut_step + 1)


func _group_beaten(group: int) -> bool:
	for i in enemies.size():
		if room.enemy_groups[i] == group and enemies[i].alive:
			return false
	return true


## Host -> everyone: the tutorial moves to `step`, waking that step's enemies.
@rpc("authority", "call_local", "reliable")
func tutorial_step(step: int) -> void:
	if _round_mode != "tutorial_b" or phase != Phase.PLAYING or step >= TUT_STEPS.size():
		return
	_tut_step = step
	room_no = step + 1
	_tut_mark = _recalls_done
	for i in enemies.size():
		var group: int = room.enemy_groups[i]
		if group > 0 and TUT_WAKE[group] == step:
			enemies[i].set_active(true)
	_step_banner()
	_log_event("tutorial step %d" % step)


func _step_banner() -> void:
	hud.banner("STEP %d  ·  %s" % [_tut_step + 1, TUT_STEPS[_tut_step][0]], Palette.SIGNAL, TUT_BANNER_HOLD)


func _update_tutorial_hud() -> void:
	if not is_tutorial():
		hud.tut_title = ""
		hud.top_label = ""
		return
	var normal := local_player.role == ROLE_FORWARD
	if _round_mode == "tutorial_b":
		var st: Array = TUT_STEPS[_tut_step]
		hud.top_label = "STEP  %d / %d" % [_tut_step + 1, TUT_STEPS.size()]
		hud.tut_title = st[0]
		hud.tut_text = st[1] if normal else st[2]
	else:
		hud.top_label = "LOOPS  %d" % _recalls_done
		hud.tut_title = "FREE PRACTICE"
		hud.tut_text = ("YOU FIRE. THEN PASS THE EMPTY GUN TO INVERTED" if normal
			else "YOU RECALL. THEN PASS THE LOADED GUN BACK TO NORMAL") + "   ·   ESC TO LEAVE"
	hud.tut_hint = _tutorial_hint()


## What to do right now, from the gun's and bullet's state.
func _tutorial_hint() -> String:
	var me := local_player
	if not me.alive or gun == null or phase != Phase.PLAYING:
		return ""
	if gun.state == Gun.GROUND:
		return "THE GUN IS ON THE FLOOR: WALK OVER IT TO PICK IT UP"
	if gun.state == Gun.FLYING:
		return "" if gun.thrower == me else "THE GUN IS COMING: STAND IN ITS WAY TO CATCH IT"
	if gun.holder != me:
		return "%s HAS THE GUN" % gun.holder.player_name
	if can_fire():
		return "LEFT CLICK TO FIRE"
	if can_recall():
		return "LEFT CLICK TO RECALL: THE BULLET FOLLOWS THE BLUE LINE"
	if bullet.state == bullet.FORWARD or bullet.state == bullet.RECALL:
		return ""
	return "RIGHT CLICK TO THROW THE GUN TO YOUR PARTNER"


# --- Aim preview --------------------------------------------------------------------------

func _update_preview() -> void:
	var n := 0
	var color := Palette.FORWARD
	var hits: Array = []
	if can_fire():
		var eye := local_player.eye_pos()
		var aim := local_player.aim_dir()
		var end: Variant = _ray_world(eye, eye + aim * Bullet.RANGE)
		var stop: Vector3 = end if end != null else eye + aim * Bullet.RANGE
		_preview_pts[0] = local_player.muzzle_pos() + aim * 1.2
		_preview_pts[1] = stop
		n = 2
		_scan_segment(eye, stop, hits)
	elif can_recall():
		color = Palette.REVERSE
		var target := local_player.muzzle_pos()
		var eye := local_player.eye_pos()
		var p0: Vector3 = bullet.lodge_pos
		var p1 := Traj.recall_control(p0, bullet.lodge_dir, target)
		_preview_pts[0] = p0
		n = 1
		var steps := AimLine.MAX_SEGMENTS
		for i in range(1, steps + 1):
			var q := Traj.bezier(p0, p1, target, float(i) / steps)
			var prev := _preview_pts[n - 1]
			var blocked: Variant = _ray_world(prev, q)
			if blocked != null:
				_scan_segment(prev, blocked, hits)
				_preview_pts[n] = blocked
				n += 1
				color = Palette.DANGER
				break
			_scan_segment(prev, q, hits)
			if q.distance_to(eye) < 1.3:
				break  # don't draw the last bit right into the camera
			_preview_pts[n] = q
			n += 1
	for hit in hits.duplicate():
		if hit is Player:
			hits.erase(hit)
			color = Palette.DANGER  # friendly fire: this would kill a teammate
	if n >= 2:
		aim_line.show_path(_preview_pts, n, color)
	else:
		aim_line.hide_path()
	_set_targets(hits)


func _set_targets(list: Array) -> void:
	for e in _targeted:
		if is_instance_valid(e) and not list.has(e):
			e.set_targeted(false)
	for e in list:
		if not _targeted.has(e):
			e.set_targeted(true)
	_targeted = list


## Collects every enemy (and teammate) on the segment a -> b into `out`.
func _scan_segment(a: Vector3, b: Vector3, out: Array) -> void:
	var space := get_world_3d().direct_space_state
	_seg_exclude.clear()
	_seg_exclude.append(local_player.get_rid())
	_ray.from = a
	_ray.to = b
	_ray.collision_mask = MASK_ENEMY | MASK_PLAYER
	for i in 8:
		_ray.exclude = _seg_exclude
		var hit := space.intersect_ray(_ray)
		if hit.is_empty():
			break
		_seg_exclude.append(hit["rid"])
		if not out.has(hit["collider"]):
			out.append(hit["collider"])
	_ray.exclude = []


## First wall point on a -> b, or null.
func _ray_world(a: Vector3, b: Vector3) -> Variant:
	_ray.from = a
	_ray.to = b
	_ray.collision_mask = MASK_WORLD
	_ray.exclude = []
	var hit := get_world_3d().direct_space_state.intersect_ray(_ray)
	return null if hit.is_empty() else hit["position"]


# --- HUD ------------------------------------------------------------------------------------

func _update_markers() -> void:
	hud.markers.clear()
	for mate in teammates():
		if mate == _spec_target:
			continue  # we're looking through their eyes
		var label: String = mate.player_name
		var col := Palette.role_color(mate.role)
		if not mate.alive:
			label += "  (DOWN)"
			col = Palette.MUTED
		elif mate.carrying:
			label += "  ·  GUN"
		_add_marker(mate.global_position + Vector3(0, 2.4, 0), col, label)
	if gun != null and gun.holder != local_player and gun.state != Gun.HELD:
		_add_marker(gun.global_position + Vector3(0, 0.5, 0), Palette.SIGNAL, "GUN")
	if bullet != null and bullet.state == Bullet.LODGED:
		_add_marker(bullet.lodge_pos, Palette.REVERSE, "BULLET")


func _add_marker(world: Vector3, col: Color, label: String) -> void:
	var cam := get_viewport().get_camera_3d()  # ours, or a teammate's while spectating
	if cam == null or absf(cam.to_local(world).z) < 0.05:
		return  # no camera, or the point sits on the camera plane and can't be projected
	var view := hud.size
	var behind := cam.is_position_behind(world)
	var p := cam.unproject_position(world)
	var margin := 36.0
	var on_screen := not behind and Rect2(Vector2.ONE * margin, view - Vector2.ONE * margin * 2.0).has_point(p)
	if not on_screen:
		if behind:
			p = view - p
		p = p.clamp(Vector2.ONE * margin, view - Vector2.ONE * margin)
	hud.markers.append([p, col, label, on_screen])


# --- Misc -------------------------------------------------------------------------------------

func _role_name(p: Node3D) -> String:
	return "normal" if p.role == ROLE_FORWARD else "inverted"


func _log_event(msg: String) -> void:
	if _log:
		print("[%s %6.2f] %s" % [_net_role, Time.get_ticks_msec() / 1000.0, msg])


func _setup_input() -> void:
	_add_key("move_forward", [KEY_W, KEY_UP])
	_add_key("move_back", [KEY_S, KEY_DOWN])
	_add_key("move_left", [KEY_A, KEY_LEFT])
	_add_key("move_right", [KEY_D, KEY_RIGHT])
	_add_key("restart", [KEY_R])
	_add_key("jump", [KEY_SPACE])
	_add_key("crouch", [KEY_CTRL, KEY_C])
	_add_key("release_mouse", [KEY_ESCAPE])
	_add_key("primary", [KEY_F])
	_add_key("throw", [KEY_Q])
	_add_mouse("primary", MOUSE_BUTTON_LEFT)
	_add_mouse("throw", MOUSE_BUTTON_RIGHT)


func _add_key(action: StringName, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)


func _add_mouse(action: StringName, button: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)
