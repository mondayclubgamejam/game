extends Node
## Finds games on the local network. A host broadcasts a tiny UDP beacon once
## a second; players in the lobby listen for beacons and list the hosts.
## Broadcasts go to 255.255.255.255 and to each local /24 subnet, so machines
## with several network interfaces still reach the LAN, plus 127.0.0.1 so two
## copies on one machine always find each other (many firewalls drop a
## machine's own broadcasts).
## Firewalls must let UDP 7778 (discovery) and 7777 (the game) in.

signal hosts_changed(hosts: Array)  ## [{ip, port, name}]

const PORT := 7778
const MAGIC := "OGOB1"
const BEACON_EVERY := 1.0
const FORGET_AFTER := 3.5

var _sender: PacketPeerUDP
var _listener: PacketPeerUDP
var _beacon := PackedByteArray()
var _beacon_t := 0.0
var _targets: Array[String] = []
var _hosts := {}  ## "ip:port" -> {ip, port, name, seen}


func _ready() -> void:
	set_process(false)


## Packet format: JSON with a magic tag, so other software's broadcasts on
## this port are ignored.
## `id` is random per hosting session, so one host reached two ways (LAN
## broadcast and loopback) is listed once.
static func encode(game_port: int, host_name: String, id := 0) -> PackedByteArray:
	return JSON.stringify({"g": MAGIC, "port": game_port, "name": host_name.left(32), "id": id}).to_utf8_buffer()


static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() > 512:
		return {}
	var json := JSON.new()  # parse() fails quietly, unlike JSON.parse_string()
	if json.parse(bytes.get_string_from_utf8()) != OK:
		return {}
	var data: Variant = json.data
	if typeof(data) != TYPE_DICTIONARY or data.get("g") != MAGIC:
		return {}
	var port := int(data.get("port", 0))
	if port <= 0 or port > 65535:
		return {}
	return {"port": port, "name": str(data.get("name", "")).left(32), "id": int(data.get("id", 0))}


static func broadcast_targets() -> Array[String]:
	var out: Array[String] = ["255.255.255.255", "127.0.0.1"]
	for ip in IP.get_local_addresses():
		var parts := ip.split(".")
		if parts.size() == 4 and not ip.begins_with("127.") and not ip.begins_with("169.254."):
			var b := "%s.%s.%s.255" % [parts[0], parts[1], parts[2]]
			if not out.has(b):
				out.append(b)
	return out


func start_advertising(game_port: int, host_name: String) -> void:
	stop_advertising()
	_sender = PacketPeerUDP.new()
	_sender.set_broadcast_enabled(true)
	_beacon = encode(game_port, host_name, randi() & 0x7fffffff)
	_targets = broadcast_targets()
	_beacon_t = 0.0
	set_process(true)


func stop_advertising() -> void:
	if _sender != null:
		_sender.close()
	_sender = null
	_update_processing()


## Returns false if the discovery port is taken (e.g. another copy of the
## game on this machine is already listening).
func start_listening() -> bool:
	if _listener != null:
		return true
	_listener = PacketPeerUDP.new()
	if _listener.bind(PORT) != OK:
		_listener = null
		return false
	_hosts.clear()
	set_process(true)
	return true


func stop_listening() -> void:
	if _listener != null:
		_listener.close()
	_listener = null
	if not _hosts.is_empty():
		_hosts.clear()
		hosts_changed.emit([])
	_update_processing()


func hosts() -> Array:
	var out := []
	for h in _hosts.values():
		out.append({"ip": h["ip"], "port": h["port"], "name": h["name"]})
	return out


func _update_processing() -> void:
	set_process(_sender != null or _listener != null)


func _process(delta: float) -> void:
	if _sender != null:
		_beacon_t -= delta
		if _beacon_t <= 0.0:
			_beacon_t = BEACON_EVERY
			for target in _targets:
				_sender.set_dest_address(target, PORT)
				_sender.put_packet(_beacon)
	if _listener != null:
		_listen()


func _listen() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var changed := false
	while _listener.get_available_packet_count() > 0:
		var bytes := _listener.get_packet()
		var ip := _listener.get_packet_ip()
		var info := decode(bytes)
		if info.is_empty() or ip == "":
			continue
		var key: String = str(info["id"]) if info["id"] != 0 else "%s:%d" % [ip, info["port"]]
		if _hosts.has(key) and _hosts[key]["ip"] != ip and ip == "127.0.0.1":
			ip = _hosts[key]["ip"]  # same host seen twice: keep its LAN address
		if not _hosts.has(key) or _hosts[key]["name"] != info["name"] or _hosts[key]["ip"] != ip:
			changed = true
		_hosts[key] = {"ip": ip, "port": info["port"], "name": info["name"], "seen": now}
	for key in _hosts.keys():
		if now - _hosts[key]["seen"] > FORGET_AFTER:
			_hosts.erase(key)
			changed = true
	if changed:
		hosts_changed.emit(hosts())
