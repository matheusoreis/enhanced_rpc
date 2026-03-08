extends EnhancedRpc
class_name EnhancedServer

signal network_error()
signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)

var multiplayer_peer: MultiplayerPeer = null
var _peers: Dictionary[int, bool] = {}


func start(peer: MultiplayerPeer) -> void:
	multiplayer_peer = peer
	multiplayer_peer.peer_connected.connect(_on_peer_connect)
	multiplayer_peer.peer_disconnected.connect(_on_peer_disconnect)


func stop() -> void:
	if not multiplayer_peer:
		return
	multiplayer_peer.close()
	multiplayer_peer = null
	_peers.clear()
	abort_all_tasks()


func poll(timeout_ms: int = 0) -> void:
	if not multiplayer_peer:
		return
	var start_time_ms: int = Time.get_ticks_msec()
	_poll_events()
	while (Time.get_ticks_msec() - start_time_ms) < timeout_ms:
		_poll_events()


## Envia uma chamada sem retorno para um target (int, Array ou Callable de filtro).
## O writer é chamado uma única vez — o mesmo buffer é enviado para todos os peers.
## Exemplo:
##   server.exec(peer_id, "game.spawn", func(buf): buf.put_u32(entity_id); buf.put_vector3(pos))
func exec(target: Variant, function_path: StringName, writer: Callable = Callable(), channel_id: int = 0) -> void:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(MessageType.EXEC)
	buf.put_u32(function_path.hash())
	if writer.is_valid():
		writer.call(buf)
	_distribute_raw(target, buf.data_array, channel_id)


## Envia uma chamada e aguarda retorno de um peer específico.
## Retorna um StreamPeerBuffer posicionado no início do payload de resposta.
func invoke(peer_id: int, function_path: StringName, writer: Callable = Callable(), channel_id: int = 0) -> StreamPeerBuffer:
	var task_id: int = _reserve_task_slot()
	if task_id == -1:
		push_error("[EnhancedServer] Task pool limit reached for Peer %d." % peer_id)
		return null

	var task_instance: PendingTask = PendingTask.new()
	_task_pool[task_id] = task_instance

	var buf := StreamPeerBuffer.new()
	buf.put_u8(MessageType.INVOKE)
	buf.put_u32(function_path.hash())
	buf.put_u16(task_id)
	if writer.is_valid():
		writer.call(buf)
	_send_raw(peer_id, buf.data_array, channel_id)

	var result_buf: StreamPeerBuffer = await task_instance.completed
	_release_task_slot(task_id)

	return result_buf


func _send_raw(peer_id: int, data_buffer: PackedByteArray, channel_id: int) -> void:
	if not multiplayer_peer:
		return
	multiplayer_peer.set_target_peer(peer_id)
	multiplayer_peer.set_transfer_channel(channel_id)
	multiplayer_peer.put_packet(data_buffer)


func _poll_events() -> void:
	if not multiplayer_peer:
		return
	multiplayer_peer.poll()
	while multiplayer_peer.get_available_packet_count() > 0:
		var packet_peer := multiplayer_peer.get_packet_peer()
		var packet_channel := multiplayer_peer.get_packet_channel()
		var packet := multiplayer_peer.get_packet()
		process_packet(packet_peer, packet, packet_channel, true)


func _on_peer_connect(peer_id: int) -> void:
	_peers[peer_id] = true
	peer_connected.emit(peer_id)


func _on_peer_disconnect(peer_id: int) -> void:
	_peers.erase(peer_id)
	peer_disconnected.emit(peer_id)


## Serializa uma única vez e distribui o mesmo buffer para todos os targets.
func _distribute_raw(target: Variant, packet: PackedByteArray, channel_id: int) -> void:
	match typeof(target):
		TYPE_INT:
			_send_raw(target as int, packet, channel_id)

		TYPE_ARRAY:
			for peer_id in target:
				_send_raw(peer_id as int, packet, channel_id)

		TYPE_CALLABLE:
			var filter: Callable = target as Callable
			for peer_id in _peers:
				if filter.call(peer_id):
					_send_raw(peer_id, packet, channel_id)
