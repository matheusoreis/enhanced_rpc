extends EnhancedRpc
class_name EnhancedClient

signal network_error()
signal connected()
signal disconnected()

var multiplayer_peer: MultiplayerPeer = null


func start(peer: MultiplayerPeer) -> void:
	multiplayer_peer = peer
	multiplayer_peer.peer_connected.connect(_on_connected)
	multiplayer_peer.peer_disconnected.connect(_on_disconnected)


func stop() -> void:
	if not multiplayer_peer:
		return
	multiplayer_peer.close()
	multiplayer_peer = null
	abort_all_tasks()


func poll(timeout_ms: int = 0) -> void:
	if not multiplayer_peer:
		return
	var start_time_ms: int = Time.get_ticks_msec()
	_poll_events()
	while (Time.get_ticks_msec() - start_time_ms) < timeout_ms:
		_poll_events()


## Envia uma chamada sem retorno.
## [writer] é um Callable que recebe um StreamPeerBuffer e escreve os argumentos.
## Exemplo:
##   client.exec("game.move", func(buf): buf.put_float(x); buf.put_float(y))
func exec(function_path: StringName, writer: Callable = Callable(), channel_id: int = 0) -> void:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(MessageType.EXEC)
	buf.put_u32(function_path.hash())
	if writer.is_valid():
		writer.call(buf)
	_send_raw(1, buf.data_array, channel_id)


## Envia uma chamada e aguarda retorno.
## [writer] escreve os argumentos no buffer de envio.
## Retorna um StreamPeerBuffer posicionado no início do payload de resposta.
## Exemplo:
##   var buf = await client.invoke("game.get_state", func(buf): buf.put_u32(player_id))
##   var hp = buf.get_u16()
func invoke(function_path: StringName, writer: Callable = Callable(), channel_id: int = 0) -> StreamPeerBuffer:
	var task_id: int = _reserve_task_slot()
	if task_id == -1:
		push_error("[EnhancedClient] Task pool limit reached.")
		return null

	var task_instance: PendingTask = PendingTask.new()
	_task_pool[task_id] = task_instance

	var buf := StreamPeerBuffer.new()
	buf.put_u8(MessageType.INVOKE)
	buf.put_u32(function_path.hash())
	buf.put_u16(task_id)
	if writer.is_valid():
		writer.call(buf)
	_send_raw(1, buf.data_array, channel_id)

	var result_buf: StreamPeerBuffer = await task_instance.completed
	_release_task_slot(task_id)

	return result_buf


func _send_raw(_peer_id: int, data_buffer: PackedByteArray, channel_id: int) -> void:
	if multiplayer_peer:
		multiplayer_peer.set_target_peer(1)
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
		process_packet(packet_peer, packet, packet_channel, false)


func _on_connected(peer_id: int) -> void:
	if peer_id != 1:
		return
	connected.emit()


func _on_disconnected(peer_id: int) -> void:
	if peer_id != 1:
		return
	abort_all_tasks()
	disconnected.emit()
