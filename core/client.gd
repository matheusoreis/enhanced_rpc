## Implementação do cliente para o sistema RPC (ERPC).
##
## Gerencia a conexão do cliente e permite enviar e receber
## chamadas RPC de/para o servidor.
##
## [b]Exemplo:[/b]
## [codeblock]
## var client = EnhancedClient.new()
## client.start(peer)
## client.register_methods("Cliente", [self.receber_mensagem])
## client.exec("Servidor.log", ["Olá do cliente!"])
## [/codeblock]
extends EnhancedRpc
class_name EnhancedClient


## Emitido quando ocorre um erro de rede.
signal network_error()
## Emitido quando a conexão com o servidor é estabelecida.
signal connected()
## Emitido quando a conexão com o servidor é encerrada.
signal disconnected()


## Instância interna do MultiplayerPeer.
var multiplayer_peer: MultiplayerPeer = null


## Inicializa o cliente com o peer fornecido.
## [br]
## [b]peer[/b]: Instância de [MultiplayerPeer] já configurada.
func start(peer: MultiplayerPeer) -> void:
	multiplayer_peer = peer
	multiplayer_peer.peer_connected.connect(_on_connected)
	multiplayer_peer.peer_disconnected.connect(_on_disconnected)


## Encerra a conexão com o servidor.
func stop() -> void:
	if not multiplayer_peer:
		return
	multiplayer_peer.close()
	multiplayer_peer = null
	abort_all_tasks()


## Processa eventos de rede. Deve ser chamado a cada frame.
## [br]
## [b]timeout_ms[/b]: Tempo máximo em milissegundos para processar eventos (padrão: 0).
func poll(timeout_ms: int = 0) -> void:
	if not multiplayer_peer:
		return
	var start_time_ms: int = Time.get_ticks_msec()
	_poll_events()
	while (Time.get_ticks_msec() - start_time_ms) < timeout_ms:
		_poll_events()


## Executa um método remoto no servidor sem aguardar retorno.
## [br]
## [b]function_path[/b]: Caminho completo do método (ex.: "Escopo.metodo").
## [b]args[/b]: Argumentos a passar para o método.
## [b]channel_id[/b]: Canal de rede.
func exec(function_path: StringName, args: Array = [], channel_id: int = 0) -> void:
	_send_raw(1, var_to_bytes([MessageType.EXEC, function_path.hash(), args]), channel_id)


## Invoca um método remoto no servidor e aguarda o retorno.
## [br]
## [b]function_path[/b]: Caminho completo do método (ex.: "Escopo.metodo").
## [b]args[/b]: Argumentos a passar para o método.
## [b]channel_id[/b]: Canal de rede.
func invoke(function_path: StringName, args: Array = [], channel_id: int = 0) -> Variant:
	var task_id: int = _reserve_task_slot()
	if task_id == -1:
		push_error("[EnhancedClient] Limite do pool de tasks atingido.")
		return null

	var task_instance: PendingTask = PendingTask.new()
	_task_pool[task_id] = task_instance

	_send_raw(1, var_to_bytes([MessageType.INVOKE, function_path.hash(), args, task_id]), channel_id)

	var result: Variant = await task_instance.completed
	_release_task_slot(task_id)

	return result


## [b]Interno:[/b] Implementação ENet para envio de dados brutos.
func _send_raw(_peer_id: int, data_buffer: PackedByteArray, channel_id: int) -> void:
	if multiplayer_peer:
		multiplayer_peer.set_target_peer(1)
		multiplayer_peer.set_transfer_channel(channel_id)
		multiplayer_peer.put_packet(data_buffer)


## [b]Interno:[/b] Verifica e processa novos eventos de rede.
func _poll_events() -> void:
	if not multiplayer_peer:
		return
	multiplayer_peer.poll()
	while multiplayer_peer.get_available_packet_count() > 0:
		var packet_peer := multiplayer_peer.get_packet_peer()
		var packet_channel := multiplayer_peer.get_packet_channel()
		var packet := multiplayer_peer.get_packet()
		process_packet(packet_peer, packet, packet_channel)


## [b]Interno:[/b] Callback de conexão com o servidor.
func _on_connected(peer_id: int) -> void:
	if peer_id != 1:
		return
	connected.emit()


## [b]Interno:[/b] Callback de desconexão do servidor.
func _on_disconnected(peer_id: int) -> void:
	if peer_id != 1:
		return
	abort_all_tasks()
	disconnected.emit()