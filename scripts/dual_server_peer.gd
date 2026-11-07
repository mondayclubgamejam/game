extends MultiplayerPeerExtension
## The dedicated server's network peer: one ENet (UDP) server and one WebSocket
## server, presented to Godot's multiplayer as a single peer. Players connect
## over whichever their network allows, and Godot's server relay passes
## messages between them either way.
##
## WebSocket has no channels or unreliable mode; packets for WebSocket players
## are simply sent reliably on one channel, which the game tolerates.

var enet: ENetMultiplayerPeer
var ws: WebSocketMultiplayerPeer

var _subs: Array[MultiplayerPeer] = []
var _owner := {}      ## peer id -> the sub-peer it is connected through
var _incoming: Array = []  ## [data, from, channel, mode]
var _target := 0
var _channel := 0
var _mode := TRANSFER_MODE_RELIABLE
var _refusing := false
var _open := false


## Starts both servers. `ws_bind` is "*" for every interface. With `tls`, the
## WebSocket is encrypted (wss://), which looks like ordinary HTTPS to networks.
func listen(udp_port: int, ws_port: int, ws_bind: String, tls: TLSOptions = null) -> Error:
	enet = ENetMultiplayerPeer.new()
	var err := enet.create_server(udp_port, 8)
	if err != OK:
		return err
	ws = WebSocketMultiplayerPeer.new()
	err = ws.create_server(ws_port, ws_bind, tls)
	if err != OK:
		enet.close()
		return err
	_subs = [enet, ws]
	for sub in _subs:
		sub.peer_connected.connect(_on_sub_connected.bind(sub))
		sub.peer_disconnected.connect(_on_sub_disconnected)
	_open = true
	return OK


func transport_of(id: int) -> String:
	var sub: Variant = _owner.get(id)
	if sub == enet:
		return "UDP"
	if sub == ws:
		return "WebSocket"
	return "?"


func _on_sub_connected(id: int, sub: MultiplayerPeer) -> void:
	if _owner.has(id):  # two transports picked the same random id: refuse the newcomer
		sub.disconnect_peer(id)
		return
	_owner[id] = sub
	peer_connected.emit(id)


func _on_sub_disconnected(id: int) -> void:
	if _owner.erase(id):
		peer_disconnected.emit(id)


func _poll() -> void:
	for sub in _subs:
		sub.poll()
		while sub.get_available_packet_count() > 0:
			var from := sub.get_packet_peer()
			var ch := sub.get_packet_channel()
			var mode := sub.get_packet_mode()
			_incoming.append([sub.get_packet(), from, ch, mode])


func _get_available_packet_count() -> int:
	return _incoming.size()


func _get_packet_script() -> PackedByteArray:
	if _incoming.is_empty():
		return PackedByteArray()
	return _incoming.pop_front()[0]


func _get_packet_peer() -> int:
	return _incoming[0][1] if not _incoming.is_empty() else 0


func _get_packet_channel() -> int:
	return _incoming[0][2] if not _incoming.is_empty() else 0


func _get_packet_mode() -> TransferMode:
	return _incoming[0][3] if not _incoming.is_empty() else TRANSFER_MODE_RELIABLE


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if _target > 0:
		var sub: MultiplayerPeer = _owner.get(_target)
		if sub == null:
			return ERR_UNAVAILABLE
		return _send(sub, _target, buffer)
	# 0 = everyone, -id = everyone except id: each transport handles its own peers.
	for sub in _subs:
		if _has_peers(sub):
			_send(sub, _target, buffer)
	return OK


func _send(sub: MultiplayerPeer, target: int, buffer: PackedByteArray) -> Error:
	sub.set_target_peer(target)
	if sub == enet:
		sub.transfer_channel = _channel
		sub.transfer_mode = _mode
	return sub.put_packet(buffer)


func _has_peers(sub: MultiplayerPeer) -> bool:
	for id in _owner:
		if _owner[id] == sub:
			return true
	return false


func _set_target_peer(peer: int) -> void:
	_target = peer


func _set_transfer_channel(channel: int) -> void:
	_channel = channel


func _get_transfer_channel() -> int:
	return _channel


func _set_transfer_mode(mode: TransferMode) -> void:
	_mode = mode


func _get_transfer_mode() -> TransferMode:
	return _mode


func _get_max_packet_size() -> int:
	return 1 << 24


func _get_unique_id() -> int:
	return 1


func _is_server() -> bool:
	return true


func _is_server_relay_supported() -> bool:
	return true


func _get_connection_status() -> ConnectionStatus:
	return CONNECTION_CONNECTED if _open else CONNECTION_DISCONNECTED


func _set_refuse_new_connections(enable: bool) -> void:
	_refusing = enable
	for sub in _subs:
		sub.refuse_new_connections = enable


func _is_refusing_new_connections() -> bool:
	return _refusing


func _disconnect_peer(peer: int, force: bool) -> void:
	var sub: MultiplayerPeer = _owner.get(peer)
	if sub != null:
		sub.disconnect_peer(peer, force)


func _close() -> void:
	for sub in _subs:
		sub.close()
	_owner.clear()
	_incoming.clear()
	_open = false
