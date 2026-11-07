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
const PauseMenu := preload("res://scripts/pause_menu.gd")

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
const MASK_WORLD := 1
const MASK_ENEMY := 2
const MASK_PLAYER := 4
const KILL_WORDS := ["", "KILL!", "DOUBLE!", "TRIPLE!", "QUAD!"]
## Network protocol version. Bump it whenever an RPC's arguments change, so
## mismatched builds refuse each other with a clear message instead of
## failing on individual RPCs.
const PROTOCOL := 5
const WS_PORT := 443           ## dedicated server's encrypted WebSocket (HTTPS) port
const SERVER_CERT := "res://assets/server.crt"  ## the server certificate players trust
const SERVER_NAME := "one-gun-one-bullet"       ## the name inside that certificate
const UDP_TRY_SECONDS := 2.5   ## how long to try UDP before falling back to WebSocket
const WS_TRY_SECONDS := 8.0

var phase := Phase.LOBBY
var room_seed := 0
var room_no := 1
var attempt := 1          ## tries at the current room: +1 on every restart, 1 on a new room
var peer_a := 1
var peer_b := 0
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
var partner: Player
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
var _party := {}               ## host: match lobby members, peer id -> {name, role, ready}
var _party_order: Array[int] = []
var _party_resume := false     ## host: the next start continues the current room
var _round_end := ""           ## host: "", "died" or "cleared": how the current round ended
var _hosting_args: Array = []  ## LAN host: what the hosting screen shows, to show it again
var _bot_swap_pending := false ## test bot: swap roles at the next match lobby
var _dedicated := false        ## this process is a --server
var _relayed := false          ## this client plays through a dedicated server
var _conn_stage := ""          ## client: "", "udp" or "ws" while connecting online
var _conn_attempt := 0
var _online_ws_url := ""


func _ready() -> void:
	if _relaunch_if_software_rendering():
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

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_parse_args()


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
		elif arg == "--bot":
			_bot_mode = true
			_log = true
			var bot := Bot.new()
			bot.game = self
			add_child(bot)
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
	var err := peer.create_server(port, 1)
	if err != OK:
		lobby.show_menu("Couldn't host on port %d (error %d). Is another copy already hosting?" % [port, err], true)
		return
	multiplayer.multiplayer_peer = peer
	_net_role = "host"
	lan.stop_searching()
	var answering := lan.start_advertising(port, lobby.player_name())
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
	if _dedicated:
		_server_on_join(id)
	elif multiplayer.is_server() and phase == Phase.LOBBY:
		_log_event("partner %d joined" % id)
		lan.stop_advertising()  # one partner per game
		_party_add(id, "PLAYER")
		_party_broadcast("")


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
	if _dedicated:
		_server_on_leave(id)
	elif multiplayer.is_server():
		_host_partner_left(id)


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


func _server_on_join(id: int) -> void:
	var how: String = multiplayer.multiplayer_peer.transport_of(id)
	if phase != Phase.LOBBY or _party_order.size() >= 2:
		_log_event("player %d (%s) turned away: a game is already running" % [id, how])
		server_busy.rpc_id(id)
		get_tree().create_timer(0.5).timeout.connect(func():
			if multiplayer.multiplayer_peer != null:
				multiplayer.multiplayer_peer.disconnect_peer(id))
		return
	_log_event("player %d connected via %s (%d/2)" % [id, how, _party_order.size() + 1])
	if _party_order.is_empty():
		_party_resume = false
	_party_add(id, "PLAYER")
	_party_broadcast("")


func _server_on_leave(id: int) -> void:
	if not _party.has(id):
		return
	_log_event("player %d left" % id)
	_party_remove(id)
	if phase != Phase.LOBBY:
		_clear_round()
		round_id += 1
		phase = Phase.LOBBY
	_party_resume = false  # a new partner starts a new game
	_party_broadcast("Your partner left.")


## LAN host: the partner left. Keep hosting and wait for someone else.
func _host_partner_left(id: int) -> void:
	_log_event("partner %d left" % id)
	_party_remove(id)
	_clear_round()
	round_id += 1
	phase = Phase.LOBBY
	_party_resume = false
	hud.visible = false
	hand.visible = false
	pause.visible = false
	lobby.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var answering := lan.start_advertising(_hosting_args[0], lobby.player_name())
	lobby.show_hosting(_hosting_args[0], _hosting_args[1], _hosting_args[2], answering, "Your partner left.")


# --- Match lobby (pick roles, ready up) ---------------------------------------------

func _party_reset() -> void:
	_party.clear()
	_party_order.clear()
	_party_resume = false


## Newcomers get whichever role is free.
func _party_add(id: int, player_name: String) -> void:
	var taken := []
	for m in _party.values():
		taken.append(m["role"])
	_party[id] = {"name": player_name, "role": ROLE_REVERSE if taken.has(ROLE_FORWARD) else ROLE_FORWARD, "ready": false}
	_party_order.append(id)


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
	if _party_resume:
		info = "ROOM %d  ·  ATTEMPT %d  ·  SAME MAP" % [room_no, _resume_attempt()]
	party_state.rpc(members, info, note)


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


## Pick a role; if the partner has it, the two of you swap. Ready resets.
@rpc("any_peer", "call_remote", "reliable")
func party_pick(role: int) -> void:
	var id := _sender()
	if not multiplayer.is_server() or not _party.has(id) or phase != Phase.LOBBY or role < 0 or role > 1:
		return
	for other in _party:
		if other != id and _party[other]["role"] == role:
			_party[other]["role"] = 1 - role
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
	var all_ready := _party.size() == 2
	for m in _party.values():
		all_ready = all_ready and m["ready"]
	if all_ready:
		_party_start()
	else:
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
	_party_resume = true
	for m in _party.values():
		m["ready"] = false
	_party_broadcast("%s wants to change roles." % who)


## The attempt number a resumed game continues with: a death that just
## happened still counts, going to the lobby itself doesn't.
func _resume_attempt() -> int:
	return attempt + 1 if _round_end == "died" else attempt


func _party_start() -> void:
	var a := 0
	var b := 0
	for id in _party:
		if _party[id]["role"] == ROLE_FORWARD:
			a = id
		else:
			b = id
	for m in _party.values():
		m["ready"] = false
	if _party_resume and _round_end == "cleared":
		start_round.rpc(_new_seed(), room_no + 1, 1, a, b)
	elif _party_resume:
		start_round.rpc(room_seed, room_no, _resume_attempt(), a, b)
	else:
		start_round.rpc(_new_seed(), 1, 1, a, b)
	_party_resume = false


## Host -> everyone: the match lobby as it stands. Leaves any running round.
@rpc("authority", "call_local", "reliable")
func party_state(members: Array, info: String, note: String) -> void:
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
	lobby.show_party(list, multiplayer.get_unique_id(), info, note)
	_log_event("match lobby: %s" % [members])
	# The test bot readies up as soon as there's a partner.
	if _bot_mode and members.size() == 2:
		for m in list:
			if m["id"] == multiplayer.get_unique_id() and not m["ready"]:
				if _bot_swap_pending:
					_bot_swap_pending = false
					var other_role: int = 1 - m["role"]
					get_tree().create_timer(0.2).timeout.connect(func(): _to_host("party_pick", [other_role]))
				else:
					get_tree().create_timer(0.2).timeout.connect(func(): _to_host("party_ready", [true]))


@rpc("authority", "call_remote", "reliable")
func server_busy() -> void:
	_back_to_lobby("The server already has a game running. Try again in a bit.", true)


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
func start_round(seed_in: int, number: int, try_no: int, a_peer: int, b_peer: int) -> void:
	_clear_round()
	round_id += 1
	room_seed = seed_in
	room_no = number
	attempt = try_no
	_round_end = ""
	peer_a = a_peer
	peer_b = b_peer
	room = RoomGen.generate(seed_in)
	astar = RoomBuilder.build_astar(room)
	round_root = Node3D.new()
	round_root.name = "Round"
	add_child(round_root)
	round_root.add_child(RoomBuilder.build(room))

	var me := multiplayer.get_unique_id()
	for spec in [[a_peer, ROLE_FORWARD, room.spawn_a], [b_peer, ROLE_REVERSE, room.spawn_b]]:
		var p := Player.new()
		p.setup(spec[0], spec[1], spec[0] == me)
		round_root.add_child(p)
		p.place(RoomGen.cell_center(spec[2]) + Vector3(0, 0.05, 0), PI)  # face into the room
		players[spec[0]] = p
	local_player = players.get(me)
	if local_player != null:
		partner = players[b_peer if me == a_peer else a_peer]

	for i in room.enemy_cells.size():
		var e := Enemy.new()
		e.id = i
		e.kind = room.enemy_kinds[i]
		e.game = self
		e.astar = astar
		e.position = RoomGen.cell_center(room.enemy_cells[i])
		round_root.add_child(e)
		enemies.append(e)
	_enemies_left = enemies.size()
	_enemy_buf.resize(enemies.size() * 3)

	gun = Gun.new()
	round_root.add_child(gun)
	gun.hold(players[a_peer])
	gun.set_loaded(true)
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
		tracers.ignore.append(partner.get_rid())
		tracers.hit_local.connect(_on_local_shot)
	debris = Debris.new()
	round_root.add_child(debris)
	aim_line = AimLine.new()
	round_root.add_child(aim_line)

	bullet_seq = 0
	_claim_pending = false
	phase = Phase.PLAYING
	_update_carry()

	lan.stop_advertising()  # one partner per game
	lan.stop_searching()
	_log_event("round %d try %d seed %d: %d enemies, forward=%d reverse=%d" % [number, try_no, seed_in, enemies.size(), a_peer, b_peer])
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
	hud.banner("ROOM %d" % number if try_no == 1 else "ROOM %d  ·  TRY %d" % [number, try_no], Palette.SIGNAL)
	if not _bot_mode:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _clear_round() -> void:
	if round_root != null:
		remove_child(round_root)
		round_root.queue_free()
	round_root = null
	players.clear()
	enemies.clear()
	_targeted.clear()
	local_player = null
	partner = null
	gun = null
	bullet = null
	tracers = null
	debris = null
	aim_line = null


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
	hud.banner("CLEAR!", Palette.ENEMY)
	_log_event("room cleared")
	if multiplayer.is_server():
		_later(NEXT_ROOM_DELAY, func(): start_round.rpc(_new_seed(), room_no + 1, 1, peer_a, peer_b))


@rpc("any_peer", "call_local", "reliable")
func player_down(peer: int, cause: String) -> void:
	if phase == Phase.LOBBY:
		return
	var p: Player = players.get(peer)
	if p != null:
		p.kill()
	if phase != Phase.PLAYING:
		return
	phase = Phase.OVER
	_round_end = "died"
	var me := peer == multiplayer.get_unique_id()
	hud.banner("YOU DIED" if me else "PARTNER DOWN", Palette.DANGER)
	_log_event("player %d down (%s)" % [peer, cause])
	if multiplayer.is_server():
		_later(RESTART_DELAY, func(): start_round.rpc(room_seed, room_no, attempt + 1, peer_a, peer_b))


@rpc("any_peer", "call_remote", "reliable")
func request_restart() -> void:
	if multiplayer.is_server() and phase != Phase.LOBBY:
		start_round.rpc(room_seed, room_no, attempt + 1, peer_a, peer_b)


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
	elif event.is_action_pressed("primary"):
		try_primary()
	elif event.is_action_pressed("throw"):
		try_throw()
	elif event.is_action_pressed("restart"):
		if multiplayer.is_server():
			request_restart()
		else:
			request_restart.rpc_id(1)


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


## Aim assist: if the partner is roughly in the crosshair and visible, lead
## them and throw on an arc that reaches their chest.
func _throw_velocity(from: Vector3) -> Vector3:
	var aim := local_player.aim_dir()
	if partner != null and partner.alive:
		var target := partner.chest_pos()
		var to := target - from
		if aim.dot(to.normalized()) > cos(deg_to_rad(THROW_ASSIST_DEG)) and _ray_world(from, target) == null:
			var flight := clampf(to.length() / Traj.THROW_SPEED, 0.3, 1.1)
			var lead := partner.velocity_estimate() * flight
			lead.y = 0.0
			return Traj.throw_velocity(from, target + lead)
	return Traj.free_throw_velocity(aim)


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
	if mine:
		fx.rewind_flash(0.6)
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
	if gun.holder == local_player:
		hand.play_recall_catch()
	_kill_banner(kills, true)
	_log_event("bullet back in gun kills=%d" % kills)


func _on_bullet_enemy_hit(enemy: Node3D, dir: Vector3) -> void:
	if not bullet.authority or not enemy.alive:
		return
	_action_kills += 1
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


## Packed enemy positions: x, z, yaw for each enemy.
@rpc("authority", "call_remote", "unreliable_ordered", 2)
func enemy_sync(data: PackedFloat32Array) -> void:
	var n := mini(enemies.size(), data.size() / 3)
	for i in n:
		enemies[i].apply_net_state(data[i * 3], data[i * 3 + 1], data[i * 3 + 2])


# --- Per-tick work ----------------------------------------------------------------------

## `flags`: Player.FLAG_CROUCH.
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
			# Ping whoever hosts: the server when relayed, else the partner.
			if multiplayer.is_server():
				net_ping.rpc(Time.get_ticks_usec())
			else:
				net_ping.rpc_id(1, Time.get_ticks_usec())

	if multiplayer.is_server():
		_sync_t -= delta
		if _sync_t <= 0.0:
			_sync_t = ENEMY_SYNC_INTERVAL
			for i in enemies.size():
				var e: Node3D = enemies[i]
				_enemy_buf[i * 3] = e.global_position.x
				_enemy_buf[i * 3 + 1] = e.global_position.z
				_enemy_buf[i * 3 + 2] = e.rotation.y
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


func _process(_delta: float) -> void:
	if phase == Phase.LOBBY or local_player == null:
		return
	hud.targets = _enemies_left
	hud.can_act = can_fire() or can_recall()
	hud.ping_ms = int(rtt * 1000.0) if rtt > 0.0 else -1
	_update_status()
	_update_markers()


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
	if hits.has(partner):
		hits.erase(partner)
		color = Palette.DANGER  # friendly fire: this would kill your partner
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


## Collects every enemy (and the partner) on the segment a -> b into `out`.
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

func _update_status() -> void:
	var t := ""
	var cap := ""
	var col := Palette.MUTED
	var a := local_player.role == ROLE_FORWARD
	if not local_player.alive:
		t = "DOWN"
		cap = "RESTARTING THE ROOM"
		col = Palette.DANGER
	elif bullet.state == Bullet.FORWARD:
		t = "FIRING"
		cap = "BULLET FLYING OUT"
		col = Palette.FORWARD
	elif bullet.state == Bullet.RECALL:
		t = "RETURNING"
		cap = "BULLET FLYING BACK"
		col = Palette.REVERSE
	elif gun.state == Gun.FLYING:
		t = "CATCH!"
		cap = "GUN IN THE AIR"
		col = Palette.SIGNAL
	elif gun.state == Gun.GROUND:
		t = "GRAB IT"
		cap = "GUN ON THE FLOOR"
		col = Palette.SIGNAL
	elif gun.holder == local_player:
		if can_fire():
			t = "FIRE"
			cap = "LOADED  ·  LMB"
			col = Palette.FORWARD
		elif can_recall():
			t = "RECALL"
			cap = "BULLET IS OUT  ·  LMB"
			col = Palette.REVERSE
		else:
			t = "PASS IT"
			cap = ("EMPTY" if a else "YOU CAN'T FIRE") + "  ·  RMB THROW"
	else:
		t = "PARTNER"
		cap = "HAS THE GUN  ·  GET READY"
	hud.status_text = t
	hud.status_caption = cap
	hud.status_color = col


func _update_markers() -> void:
	hud.markers.clear()
	if partner != null:
		var label := "A" if partner.role == ROLE_FORWARD else "B"
		if partner.carrying:
			label += "  ·  GUN"
		_add_marker(partner.global_position + Vector3(0, 2.4, 0), Palette.role_color(partner.role), label)
	if gun != null and gun.holder != local_player and gun.state != Gun.HELD:
		_add_marker(gun.global_position + Vector3(0, 0.5, 0), Palette.SIGNAL, "GUN")
	if bullet != null and bullet.state == Bullet.LODGED:
		_add_marker(bullet.lodge_pos, Palette.REVERSE, "BULLET")


func _add_marker(world: Vector3, col: Color, label: String) -> void:
	var cam: Camera3D = local_player.camera
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
	return "A" if p.role == ROLE_FORWARD else "B"


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
