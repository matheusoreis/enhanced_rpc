## Classe base do sistema RPC (ERPC).
##
## Fornece a lógica central de registro de métodos, gerenciamento de tarefas
## e processamento de pacotes. Não deve ser usada diretamente —
## utilize [EnhancedClient] ou [EnhancedServer].
extends RefCounted
class_name EnhancedRpc


## Tarefa interna usada para aguardar o resultado de um INVOKE.
class PendingTask:
	## Emitido quando a tarefa é concluída com um valor de retorno.
	signal completed(value: Variant)


## Estrutura interna que armazena as informações de um método registrado.
class RegisteredMethod:
	var callable: Callable

	func _init(c: Callable) -> void:
		callable = c


## Tipos de mensagem RPC.
enum MessageType {
	## Executa sem aguardar retorno.
	EXEC,
	## Executa e aguarda retorno.
	INVOKE,
	## Retorno de um INVOKE.
	RESULT,
}


## Dicionário de métodos registrados, mapeados por ID.
var _method_registry: Dictionary[int, RegisteredMethod] = {}
## Pool de tarefas ativas ou livres.
var _task_pool: Array[PendingTask] = []
## Pilha de índices livres no pool de tarefas.
var _free_slots: Array[int] = []
## Número máximo de tarefas simultâneas permitidas.
var _max_tasks: int = 2048
## ID do peer remetente do pacote em processamento no momento.
var _current_sender_id: int = -1


## [b]max_tasks[/b]: Número máximo de tarefas simultâneas (padrão: 2048).
func _init(max_tasks: int = 2048) -> void:
	self._max_tasks = max_tasks
	_task_pool.resize(max_tasks)
	_free_slots.resize(max_tasks)
	for i in range(max_tasks):
		_free_slots[i] = (max_tasks - 1) - i


## Retorna o ID do peer que enviou o pacote sendo processado no momento.
## Válido apenas durante a execução de uma função chamada remotamente.
func get_sender_id() -> int:
	return _current_sender_id


## Registra uma lista de funções como métodos remotos sob um escopo.
## [br]
## [b]scope[/b]: Namespace de registro (ex.: "Player", "Chat").
## [b]functions[/b]: Array de [Callable]s a registrar.
func register_methods(scope: StringName, functions: Array[Callable]) -> void:
	for function in functions:
		var function_name: StringName = function.get_method()

		if function_name == &"<anonymous lambda>":
			push_warning("[ERPC] Lambdas não são permitidas.")
			continue

		var function_id: int = str(scope, ".", function_name).hash()

		if _method_registry.has(function_id):
			push_warning("[ERPC] Conflito de ID para %s.%s." % [scope, function_name])
			continue

		_method_registry[function_id] = RegisteredMethod.new(function)


## Remove métodos registrados de um escopo.
## [br]
## [b]scope[/b]: Namespace usado no registro.
## [b]functions[/b]: Funções a remover.
func unregister_methods(scope: StringName, functions: Array[Callable]) -> void:
	for function in functions:
		var function_id: int = str(scope, ".", function.get_method()).hash()
		_method_registry.erase(function_id)


## [b]Interno:[/b] Processa os dados brutos de um pacote recebido pela rede.
## [br]
## [b]sender_id[/b]: ID do peer remetente.
## [b]packet_buffer[/b]: Buffer de bytes do pacote.
## [b]channel_id[/b]: Canal pelo qual o pacote foi recebido.
func process_packet(sender_id: int, packet_buffer: PackedByteArray, channel_id: int) -> void:
	var packet: Variant = bytes_to_var(packet_buffer)
	if typeof(packet) != TYPE_ARRAY:
		return

	var packet_array: Array = packet as Array
	if packet_array.is_empty() or typeof(packet_array[0]) != TYPE_INT:
		return

	_current_sender_id = sender_id

	var message_type: int = packet_array[0]
	match message_type:
		MessageType.EXEC:
			_handle_exec(sender_id, packet_array)

		MessageType.INVOKE:
			_handle_invoke(sender_id, packet_array, channel_id)

		MessageType.RESULT:
			_handle_result(packet_array)


## [b]Interno:[/b] Trata um pacote EXEC (sem retorno).
func _handle_exec(sender_id: int, packet: Array) -> void:
	if packet.size() < 3:
		return

	var function_id: int = packet[1]
	var args: Array = packet[2]

	var method: RegisteredMethod = _method_registry.get(function_id)
	if method == null:
		push_warning("[ERPC] Peer %d tentou EXEC em método não registrado." % sender_id)
		return

	method.callable.callv(args)


## [b]Interno:[/b] Trata um pacote INVOKE (com retorno).
func _handle_invoke(sender_id: int, packet: Array, channel_id: int) -> void:
	if packet.size() < 4:
		return

	var function_id: int = packet[1]
	var args: Array = packet[2]
	var task_id: int = packet[3]

	var method: RegisteredMethod = _method_registry.get(function_id)
	if method == null:
		_on_protocol_error(sender_id, "Invoke em hash de função não registrada: %d" % function_id)
		return

	var result: Variant = await method.callable.callv(args)
	_send_raw(sender_id, var_to_bytes([MessageType.RESULT, result, task_id]), channel_id)


## [b]Interno:[/b] Trata um pacote RESULT (resposta a um INVOKE).
func _handle_result(packet: Array) -> void:
	if packet.size() < 3:
		return

	var result: Variant = packet[1]
	var task_id: int = packet[2]

	if task_id < 0 or task_id >= _max_tasks:
		return

	var pending_task: PendingTask = _task_pool[task_id]
	if pending_task:
		pending_task.completed.emit(result)


## [b]Virtual:[/b] Envia dados brutos pela rede. Deve ser implementado pelas subclasses.
func _send_raw(peer_id: int, data: PackedByteArray, channel_id: int) -> void:
	pass


## [b]Interno:[/b] Registra um erro de protocolo.
func _on_protocol_error(sender_id: int, reason: String) -> void:
	push_warning("[ERPC] Erro de protocolo (Peer %d): %s" % [sender_id, reason])


## Cancela todas as tarefas pendentes e reinicia o pool.
func abort_all_tasks() -> void:
	for i in range(_task_pool.size()):
		if _task_pool[i] != null:
			_task_pool[i].completed.emit(null)
			_task_pool[i] = null

	_free_slots.clear()
	_free_slots.resize(_max_tasks)
	for i in range(_max_tasks):
		_free_slots[i] = (_max_tasks - 1) - i


## [b]Interno:[/b] Reserva um slot livre no pool de tarefas.
func _reserve_task_slot() -> int:
	if _free_slots.is_empty():
		return -1
	return _free_slots.pop_back()


## [b]Interno:[/b] Libera um slot de volta ao pool.
func _release_task_slot(task_id: int) -> void:
	_task_pool[task_id] = null
	_free_slots.push_back(task_id)
