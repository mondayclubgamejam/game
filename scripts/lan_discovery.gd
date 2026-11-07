extends Node
## Finds games on the local network, in a way that survives firewalls.
##
## Host side: answers on UDP 7778, and broadcasts a beacon once a second.
## Lobby side ("seeker"), from one ordinary outgoing socket:
##   - sends a small query to the LAN broadcast addresses every second, and
##   - sweeps a query directly to every address in its local /24 networks,
##     a couple of hundred packets a second.
## Hosts answer straight back to the sender. Because each answer is a reply to
## a packet the seeker sent, stateful firewalls on the seeker's machine
## (firewalld on Rocky/RHEL, ufw, Windows Firewall) let it in, so players
## joining a game need no firewall changes. If port 7778 is free, the lobby
## also listens for the beacons directly.
##
## The HOST still needs UDP 7777 (game) and 7778 (discovery) open.

signal hosts_changed(hosts: Array)  ## [{ip, port, name}]

const PORT := 7778
const MAGIC := "OGOB2"
const BEACON_EVERY := 1.0
const QUERY_EVERY := 1.0
const SWEEP_RATE := 200.0       ## direct queries per second
const MAX_SWEEP_NETWORKS := 6
const FORGET_AFTER := 4.0

var _responder: PacketPeerUDP   ## host: bound to PORT, answers queries
var _seeker: PacketPeerUDP      ## lobby: ephemeral port, asks and gets answers
var _passive: PacketPeerUDP     ## lobby: bound to PORT when free, hears beacons
var _beacon := PackedByteArray()
var _query := PackedByteArray()
var _broadcasts: Array[String] = []
var _sweep := PackedStringArray()
var _sweep_i := 0
var _sweep_budget := 0.0
var _beacon_t := 0.0
var _query_t := 0.0
var _hosts := {}                ## session id -> {ip, port, name, seen}


func _ready() -> void:
	set_process(false)


# --- Packets ------------------------------------------------------------------

## A host's answer/beacon. `id` is random per hosting session, so one host
## reached several ways (broadcast, sweep, loopback) is listed once.
static func encode_host(game_port: int, host_name: String, id: int) -> PackedByteArray:
	return JSON.stringify({"g": MAGIC, "t": "h", "port": game_port, "name": host_name.left(32), "id": id}).to_utf8_buffer()


static func encode_query() -> PackedByteArray:
	return JSON.stringify({"g": MAGIC, "t": "q"}).to_utf8_buffer()


## Returns {} for anything that isn't ours, {"t": "q"} for a query, or
## {"t": "h", port, name, id} for a host.
static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty() or bytes.size() > 512:
		return {}
	var json := JSON.new()  # parse() fails quietly, unlike JSON.parse_string()
	if json.parse(bytes.get_string_from_utf8()) != OK:
		return {}
	var data: Variant = json.data
	if typeof(data) != TYPE_DICTIONARY or data.get("g") != MAGIC:
		return {}
	match data.get("t"):
		"q":
			return {"t": "q"}
		"h":
			var port := int(data.get("port", 0))
			if port <= 0 or port > 65535:
				return {}
			return {"t": "h", "port": port, "name": str(data.get("name", "")).left(32),
				"id": int(data.get("id", 0))}
	return {}


# --- Addresses ----------------------------------------------------------------

static func is_private_ipv4(ip: String) -> bool:
	var p := ip.split(".")
	if p.size() != 4:
		return false
	var a := p[0].to_int()
	var b := p[1].to_int()
	return a == 10 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31)


static func local_ipv4() -> Array[String]:
	var out: Array[String] = []
	for ip in IP.get_local_addresses():
		if ip.split(".").size() == 4 and not ip.begins_with("127.") and not ip.begins_with("169.254."):
			out.append(ip)
	# Home/office networks first, container bridges (172.x) last.
	out.sort_custom(func(x: String, y: String) -> bool: return _rank(x) < _rank(y))
	return out


## The addresses worth telling a partner: home/office networks first,
## skipping container bridges and VPNs unless there's nothing else.
static func best_addresses(limit := 3) -> Array[String]:
	var all := local_ipv4()
	var out: Array[String] = []
	for ip in all:
		if _rank(ip) <= 1 and not ip.ends_with(".0") and out.size() < limit:
			out.append(ip)
	if out.is_empty():
		for ip in all.slice(0, limit):
			out.append(ip)
	return out


static func _rank(ip: String) -> int:
	if ip.begins_with("192.168."):
		return 0
	if ip.begins_with("10."):
		return 1
	if is_private_ipv4(ip):
		return 2
	return 3


static func broadcast_targets() -> Array[String]:
	var out: Array[String] = ["255.255.255.255", "127.0.0.1"]
	for ip in local_ipv4():
		var p := ip.split(".")
		var b := "%s.%s.%s.255" % [p[0], p[1], p[2]]
		if not out.has(b):
			out.append(b)
	return out


## Every other address in this machine's private /24 networks.
static func sweep_targets() -> PackedStringArray:
	var mine := local_ipv4()
	var nets: Array[String] = []
	for ip in mine:
		if not is_private_ipv4(ip):
			continue
		var p := ip.split(".")
		var net := "%s.%s.%s." % [p[0], p[1], p[2]]
		if not nets.has(net) and nets.size() < MAX_SWEEP_NETWORKS:
			nets.append(net)
	var out := PackedStringArray()
	for net in nets:
		for i in range(1, 255):
			var ip := net + str(i)
			if not mine.has(ip):
				out.append(ip)
	return out


# --- Hosting ------------------------------------------------------------------

## Returns false if port 7778 is taken: the game is still broadcast, but
## can't answer direct queries (another copy is probably hosting here).
func start_advertising(game_port: int, host_name: String) -> bool:
	stop_advertising()
	_beacon = encode_host(game_port, host_name, randi() & 0x7fffffff)
	_broadcasts = broadcast_targets()
	_responder = PacketPeerUDP.new()
	var ok := _responder.bind(PORT) == OK
	if not ok:
		_responder = PacketPeerUDP.new()
		_responder.bind(0)
	_responder.set_broadcast_enabled(true)
	_beacon_t = 0.0
	set_process(true)
	return ok


func stop_advertising() -> void:
	if _responder != null:
		_responder.close()
	_responder = null
	_update_processing()


# --- Searching ----------------------------------------------------------------

func start_searching() -> void:
	if _seeker != null:
		return
	_seeker = PacketPeerUDP.new()
	_seeker.bind(0)
	_seeker.set_broadcast_enabled(true)
	_passive = PacketPeerUDP.new()
	if _passive.bind(PORT) != OK:
		_passive = null  # someone else has it; the direct queries still work
	_query = encode_query()
	_broadcasts = broadcast_targets()
	_sweep = sweep_targets()
	_sweep_i = 0
	_sweep_budget = 0.0
	_query_t = 0.0
	_hosts.clear()
	set_process(true)


func stop_searching() -> void:
	for sock in [_seeker, _passive]:
		if sock != null:
			sock.close()
	_seeker = null
	_passive = null
	if not _hosts.is_empty():
		_hosts.clear()
		hosts_changed.emit([])
	_update_processing()


func is_searching() -> bool:
	return _seeker != null


func hosts() -> Array:
	var out := []
	for h in _hosts.values():
		out.append({"ip": h["ip"], "port": h["port"], "name": h["name"]})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x["name"] < y["name"])
	return out


func _update_processing() -> void:
	set_process(_responder != null or _seeker != null)


# --- Per frame ------------------------------------------------------------------

func _process(delta: float) -> void:
	if _responder != null:
		_host_tick(delta)
	if _seeker != null:
		_seek_tick(delta)


func _host_tick(delta: float) -> void:
	while _responder.get_available_packet_count() > 0:
		var bytes := _responder.get_packet()
		var ip := _responder.get_packet_ip()
		var port := _responder.get_packet_port()
		if ip != "" and decode(bytes).get("t") == "q":
			_responder.set_dest_address(ip, port)
			_responder.put_packet(_beacon)
	_beacon_t -= delta
	if _beacon_t <= 0.0:
		_beacon_t = BEACON_EVERY
		for target in _broadcasts:
			_responder.set_dest_address(target, PORT)
			_responder.put_packet(_beacon)


func _seek_tick(delta: float) -> void:
	_query_t -= delta
	if _query_t <= 0.0:
		_query_t = QUERY_EVERY
		for target in _broadcasts:
			_seeker.set_dest_address(target, PORT)
			_seeker.put_packet(_query)
	if not _sweep.is_empty():
		_sweep_budget = minf(_sweep_budget + SWEEP_RATE * delta, 64.0)
		while _sweep_budget >= 1.0:
			_sweep_budget -= 1.0
			_seeker.set_dest_address(_sweep[_sweep_i], PORT)
			_seeker.put_packet(_query)
			_sweep_i = (_sweep_i + 1) % _sweep.size()

	var changed := _drain(_seeker)
	if _passive != null:
		changed = _drain(_passive) or changed
	var now := Time.get_ticks_msec() / 1000.0
	for key in _hosts.keys():
		if now - _hosts[key]["seen"] > FORGET_AFTER:
			_hosts.erase(key)
			changed = true
	if changed:
		hosts_changed.emit(hosts())


## Reads every waiting packet; returns true if the host list changed.
func _drain(sock: PacketPeerUDP) -> bool:
	var changed := false
	var now := Time.get_ticks_msec() / 1000.0
	while sock.get_available_packet_count() > 0:
		var bytes := sock.get_packet()
		var ip := sock.get_packet_ip()
		var info := decode(bytes)
		if ip == "" or info.get("t") != "h":
			continue
		var key: String = str(info["id"]) if info["id"] != 0 else "%s:%d" % [ip, info["port"]]
		var old: Dictionary = _hosts.get(key, {})
		if not old.is_empty() and ip.begins_with("127.") and not old["ip"].begins_with("127."):
			ip = old["ip"]  # same host seen twice: keep its LAN address
		if old.is_empty() or old["ip"] != ip or old["name"] != info["name"]:
			changed = true
		_hosts[key] = {"ip": ip, "port": info["port"], "name": info["name"], "seen": now}
	return changed
