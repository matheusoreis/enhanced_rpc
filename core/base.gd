extends RefCounted
class_name EnhancedRpc


class PendingTask:
	signal completed(buf: StreamPeerBuffer)


class RegisteredMethod:
	var callable: Callable

	func _init(c: Callable) -> void:
		callable = c


class RpcContext:
	var sender_id: int

	func _init(id: int) -> void:
		sender_id = id


enum MessageType {
	EXEC,
	INVOKE,
	RESULT
}


var _method_registry: Dictionary[int, RegisteredMethod] = {}
var _task_pool: Array[PendingTask] = []
var _free_slots: Array[int] = []
var _max_tasks: int = 2048


func _init(max_tasks: int = 2048) -> void:
	self._max_tasks = max_tasks
	_task_pool.resize(max_tasks)
	_free_slots.resize(max_tasks)
	for i in range(max_tasks):
		_free_slots[i] = (max_tasks - 1) - i


func register_methods(scope: StringName, functions: Array[Callable]) -> void:
	for function in functions:
		var function_name: StringName = function.get_method()

		if function_name == &"<anonymous lambda>":
			push_warning("[ERPC] Lambdas are not allowed.")
			continue

		var function_id: int = str(scope, ".", function_name).hash()

		if _method_registry.has(function_id):
			push_warning("[ERPC] Id conflict for %s.%s." % [scope, function_name])
			continue

		_method_registry[function_id] = RegisteredMethod.new(function)


func unregister_methods(scope: StringName, functions: Array[Callable]) -> void:
	for function in functions:
		var function_id: int = str(scope, ".", function.get_method()).hash()
		_method_registry.erase(function_id)


func process_packet(sender_id: int, packet_buffer: PackedByteArray, channel_id: int, inject_ctx: bool = true) -> void:
	if packet_buffer.size() < 5:
		return

	var buf := StreamPeerBuffer.new()
	buf.data_array = packet_buffer

	var message_type: int = buf.get_u8()

	match message_type:
		MessageType.EXEC:
			_handle_exec(sender_id, buf, inject_ctx)

		MessageType.INVOKE:
			_handle_invoke(sender_id, buf, channel_id, inject_ctx)

		MessageType.RESULT:
			_handle_result(buf)


func _handle_exec(sender_id: int, buf: StreamPeerBuffer, inject_ctx: bool) -> void:
	var function_id: int = buf.get_u32()

	var method: RegisteredMethod = _method_registry.get(function_id)
	if method == null:
		push_warning("[ERPC] Peer %d attempted EXEC on unregistered method." % sender_id)
		return

	if inject_ctx:
		method.callable.call(RpcContext.new(sender_id), buf)
	else:
		method.callable.call(buf)


func _handle_invoke(sender_id: int, buf: StreamPeerBuffer, channel_id: int, inject_ctx: bool) -> void:
	var function_id: int = buf.get_u32()
	var task_id: int = buf.get_u16()

	var method: RegisteredMethod = _method_registry.get(function_id)
	if method == null:
		_on_protocol_error(sender_id, "Invoke on unregistered function hash: %d" % function_id)
		return

	var result_buf: StreamPeerBuffer
	if inject_ctx:
		result_buf = await method.callable.call(RpcContext.new(sender_id), buf)
	else:
		result_buf = await method.callable.call(buf)

	var out := StreamPeerBuffer.new()
	out.put_u8(MessageType.RESULT)
	out.put_u16(task_id)
	if result_buf != null and result_buf.get_size() > 0:
		out.put_data(result_buf.data_array)

	_send_raw(sender_id, out.data_array, channel_id)


func _handle_result(buf: StreamPeerBuffer) -> void:
	if buf.get_available_bytes() < 2:
		return

	var task_id: int = buf.get_u16()

	if task_id < 0 or task_id >= _max_tasks:
		return

	var pending_task: PendingTask = _task_pool[task_id]
	if pending_task:
		# buf posicionado no payload — quem fez invoke lê com get_xxx
		pending_task.completed.emit(buf)


func _send_raw(peer_id: int, data: PackedByteArray, channel_id: int) -> void:
	pass


func _on_protocol_error(sender_id: int, reason: String) -> void:
	push_warning("[ERPC] Protocol Error (Peer %d): %s" % [sender_id, reason])


func abort_all_tasks() -> void:
	for i in range(_task_pool.size()):
		if _task_pool[i] != null:
			_task_pool[i].completed.emit(null)
			_task_pool[i] = null

	_free_slots.clear()
	_free_slots.resize(_max_tasks)
	for i in range(_max_tasks):
		_free_slots[i] = (_max_tasks - 1) - i


func _reserve_task_slot() -> int:
	if _free_slots.is_empty():
		return -1
	return _free_slots.pop_back()


func _release_task_slot(task_id: int) -> void:
	_task_pool[task_id] = null
	_free_slots.push_back(task_id)
