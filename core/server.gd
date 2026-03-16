## Implementação do servidor para o sistema RPC (ERPC).
##
## Gerencia o host do servidor, as conexões de múltiplos clientes
## e permite enviar chamadas RPC para peers específicos, grupos ou broadcast.
##
## [b]Exemplo:[/b]
## [codeblock]
## var server = EnhancedServer.new()
## server.start(peer)
## server.register_methods("Servidor", [self.login])
## server.peer_connected.connect(self._on_cliente_conectado)
## [/codeblock]
extends EnhancedRpc
class_name EnhancedServer


## Emitido quando ocorre um erro de rede.
signal network_error()
## Emitido quando um novo peer se conecta.
signal peer_connected(peer_id: int)
## Emitido quando um peer se desconecta.
signal peer_disconnected(peer_id: int)


## Instância interna do MultiplayerPeer.
var multiplayer_peer: MultiplayerPeer = null
## Dicionário de peers conectados.
var _peers: Dictionary[int, bool] = {}


## Inicializa o servidor com o peer fornecido.
## [br]
## [b]peer[/b]: Instância de [MultiplayerPeer] já configurada.
func start(peer: MultiplayerPeer) -> void:
	multiplayer_peer = peer
	multiplayer_peer.peer_connected.connect(_on_peer_connect)
	multiplayer_peer.peer_disconnected.connect(_on_peer_disconnect)


## Encerra o servidor e desconecta todos os peers.
func stop() -> void:
	if not multiplayer_peer:
		return
	multiplayer_peer.close()
	multiplayer_peer = null
	_peers.clear()
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


## Executa um método remoto no(s) alvo(s) sem aguardar retorno.
## [br]
## [b]target[/b]: Destino do envio. Pode ser:
## - [int]: Um peer específico.
## - [Array]: Uma lista de peers.
## - [Callable]: Função de filtro que recebe um peer_id e retorna bool.
## - Qualquer outro valor: Broadcast para todos os peers conectados.
## [b]function_path[/b]: Caminho completo do método (ex.: "Escopo.metodo").
## [b]args[/b]: Argumentos a passar para o método.
## [b]channel_id[/b]: Canal de rede.
func exec(target: Variant, function_path: StringName, args: Array = [], channel_id: int = 0) -> void:
	var packet := var_to_bytes([MessageType.EXEC, function_path.hash(), args])
	_distribute_raw(target, packet, channel_id)


## Invoca um método remoto em um peer específico e aguarda o retorno.
## [br]
## [b]peer_id[/b]: ID do peer alvo.
## [b]function_path[/b]: Caminho completo do método (ex.: "Escopo.metodo").
## [b]args[/b]: Argumentos a passar para o método.
## [b]channel_id[/b]: Canal de rede.
func invoke(peer_id: int, function_path: StringName, args: Array = [], channel_id: int = 0) -> Variant:
	var task_id: int = _reserve_task_slot()
	if task_id == -1:
		push_error("[EnhancedServer] Limite do pool de tasks atingido para o Peer %d." % peer_id)
		return null

	var task_instance: PendingTask = PendingTask.new()
	_task_pool[task_id] = task_instance

	_send_raw(peer_id, var_to_bytes([MessageType.INVOKE, function_path.hash(), args, task_id]), channel_id)

	var result: Variant = await task_instance.completed
	_release_task_slot(task_id)

	return result


## [b]Interno:[/b] Implementação ENet para envio de dados brutos.
func _send_raw(peer_id: int, data_buffer: PackedByteArray, channel_id: int) -> void:
	if not multiplayer_peer:
		return
	multiplayer_peer.set_target_peer(peer_id)
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


## [b]Interno:[/b] Callback de conexão de um novo peer.
func _on_peer_connect(peer_id: int) -> void:
	_peers[peer_id] = true
	peer_connected.emit(peer_id)


## [b]Interno:[/b] Callback de desconexão de um peer.
func _on_peer_disconnect(peer_id: int) -> void:
	_peers.erase(peer_id)
	peer_disconnected.emit(peer_id)


## [b]Interno:[/b] Serializa o pacote uma única vez e distribui para todos os alvos.
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

		_:
			for peer_id in _peers:
				_send_raw(peer_id, packet, channel_id)