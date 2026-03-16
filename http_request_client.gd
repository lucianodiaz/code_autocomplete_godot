@tool
extends Node


signal request_completed(request_id: int, result, response_code: int, headers, body)
signal stream_progress(request_id: int, text: String)
signal stream_completed(request_id: int, response_code: int, text: String)
signal request_failed(request_id: int, message: String, response_code: int, body: String)


enum LLMProvider {
	OLLAMA_GENERATE = 0,
	OPENAI_COMPATIBLE_CHAT = 1,
	GEMINI_GENERATE_CONTENT = 2,
}


var http: HTTPRequest
var _pending_request_id: int = 0

var _ollama_stream_client: HTTPClient = HTTPClient.new()
var _ollama_stream_active: bool = false
var _ollama_stream_host: String = ""
var _ollama_stream_port: int = 11434
var _ollama_stream_path: String = "/api/generate"
var _ollama_stream_headers: PackedStringArray = []
var _ollama_stream_body: String = ""
var _ollama_stream_url: String = ""
var _ollama_stream_requested: bool = false
var _ollama_stream_response_code: int = 0
var _ollama_stream_started_ms: int = 0
var _ollama_stream_timeout_ms: int = 25000
var _ollama_stream_fallback_requested: bool = false
var _stream_buffer: String = ""
var _stream_text: String = ""


func _ready() -> void:
	set_process(true)
	http = HTTPRequest.new()
	add_child(http)
	http.use_threads = true
	http.request_completed.connect(_on_http_request_completed)


func request(request_id: int, request_data: Dictionary, stream_timeout_ms: int) -> int:
	cancel_inflight_request()
	_pending_request_id = request_id
	_ollama_stream_timeout_ms = max(stream_timeout_ms, 1000)
	
	var wants_stream := bool(request_data.get("stream", false))
	var provider_id := int(request_data.get("provider_id", int(LLMProvider.OLLAMA_GENERATE)))
	var url := str(request_data.get("url", ""))
	var headers: PackedStringArray = request_data.get("headers", PackedStringArray())
	var body := str(request_data.get("body", ""))
	
	if wants_stream and provider_id == int(LLMProvider.OLLAMA_GENERATE) and url.begins_with("http://"):
		return _start_ollama_httpclient_stream(request_id, url, headers, body)
	
	if http == null:
		emit_signal("request_failed", request_id, "HTTPRequest is not ready.", 0, "")
		return ERR_UNAVAILABLE
	
	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		emit_signal("request_failed", request_id, "Error to get request: %s" % err, 0, "")
	return err


func cancel_inflight_request() -> void:
	if http != null and http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		http.cancel_request()
	if _ollama_stream_active:
		_stop_ollama_stream()


func _process(_delta: float) -> void:
	if _ollama_stream_active:
		_poll_ollama_stream()


func _on_http_request_completed(result, response_code, headers, body) -> void:
	emit_signal("request_completed", _pending_request_id, result, response_code, headers, body)


func _start_ollama_httpclient_stream(request_id: int, url: String, headers: PackedStringArray, body: String) -> int:
	_stop_ollama_stream()
	
	var parsed := _parse_http_url(url)
	if parsed.is_empty():
		emit_signal("request_failed", request_id, "Invalid Ollama URL: %s" % url, 0, "")
		return ERR_INVALID_PARAMETER
	
	_ollama_stream_url = url
	_ollama_stream_host = str(parsed.get("host", ""))
	_ollama_stream_port = int(parsed.get("port", 80))
	_ollama_stream_path = str(parsed.get("path", "/"))
	_ollama_stream_headers = headers.duplicate()
	if not _has_header(_ollama_stream_headers, "Host"):
		_ollama_stream_headers.append("Host: %s:%d" % [_ollama_stream_host, _ollama_stream_port])
	_ollama_stream_body = body
	_ollama_stream_requested = false
	_ollama_stream_response_code = 0
	_ollama_stream_started_ms = Time.get_ticks_msec()
	_ollama_stream_fallback_requested = false
	_stream_buffer = ""
	_stream_text = ""
	
	var err := _ollama_stream_client.connect_to_host(_ollama_stream_host, _ollama_stream_port)
	if err != OK:
		emit_signal("request_failed", request_id, "Ollama connect error: %s" % err, 0, "")
		return err
	
	_ollama_stream_active = true
	return OK


func _poll_ollama_stream() -> void:
	_ollama_stream_client.poll()
	
	var status := _ollama_stream_client.get_status()
	var elapsed_ms := Time.get_ticks_msec() - _ollama_stream_started_ms
	
	if not _ollama_stream_fallback_requested and elapsed_ms > _ollama_stream_timeout_ms and status != HTTPClient.STATUS_BODY:
		_ollama_stream_fallback_requested = true
		print("[code autocomplete] Ollama stream timeout (", elapsed_ms, "ms). Falling back to non-streaming.")
		_stop_ollama_stream()
		_fallback_ollama_non_stream()
		return
	
	if status == HTTPClient.STATUS_DISCONNECTED:
		_stop_ollama_stream()
		return
	
	if status == HTTPClient.STATUS_CANT_RESOLVE or status == HTTPClient.STATUS_CANT_CONNECT or status == HTTPClient.STATUS_CONNECTION_ERROR:
		print("[code autocomplete] Ollama stream connection error status: ", status, " after ", elapsed_ms, "ms")
		_stop_ollama_stream()
		_fallback_ollama_non_stream()
		return
	
	if status == HTTPClient.STATUS_CONNECTED and not _ollama_stream_requested:
		_ollama_stream_requested = true
		var err := _ollama_stream_client.request(HTTPClient.METHOD_POST, _ollama_stream_path, _ollama_stream_headers, _ollama_stream_body)
		if err != OK:
			print("[code autocomplete] Ollama request error: ", err)
			_stop_ollama_stream()
			_fallback_ollama_non_stream()
		return
	
	if status == HTTPClient.STATUS_BODY:
		if _ollama_stream_response_code == 0:
			_ollama_stream_response_code = _ollama_stream_client.get_response_code()
		
		var chunk := _ollama_stream_client.read_response_body_chunk()
		if chunk.size() == 0:
			return
		
		_stream_buffer += chunk.get_string_from_utf8()
		var done := _process_ollama_stream_buffer_lines()
		emit_signal("stream_progress", _pending_request_id, _stream_text)
		
		if done:
			emit_signal("stream_completed", _pending_request_id, _ollama_stream_response_code, _stream_text)
			_stop_ollama_stream()


func _process_ollama_stream_buffer_lines() -> bool:
	var lines := _stream_buffer.split("\n")
	if lines.size() <= 1:
		return false
	
	_stream_buffer = lines[lines.size() - 1]
	var done := false
	
	for i in range(0, lines.size() - 1):
		var line := lines[i].strip_edges()
		if line == "":
			continue
		var json := JSON.new()
		if json.parse(line) != OK:
			continue
		var data = json.data
		if typeof(data) != TYPE_DICTIONARY:
			continue
		if data.has("response"):
			_stream_text += str(data.get("response", ""))
		if bool(data.get("done", false)):
			done = true
	
	return done


func _stop_ollama_stream() -> void:
	_ollama_stream_active = false
	_ollama_stream_requested = false
	if _ollama_stream_client.get_status() != HTTPClient.STATUS_DISCONNECTED:
		_ollama_stream_client.close()


func _parse_http_url(url: String) -> Dictionary:
	var normalized := url.strip_edges()
	if not normalized.begins_with("http://"):
		return {}
	normalized = normalized.trim_prefix("http://")
	
	var host_port := normalized
	var path := "/"
	if normalized.contains("/"):
		host_port = normalized.get_slice("/", 0)
		path = normalized.substr(host_port.length())
		if path == "":
			path = "/"
	
	var host := host_port
	var port := 80
	if host_port.contains(":"):
		host = host_port.get_slice(":", 0)
		port = int(host_port.get_slice(":", 1))
	
	return {"host": host, "port": port, "path": path}


func _fallback_ollama_non_stream() -> void:
	if _ollama_stream_url == "":
		return
	if http == null:
		return
	if http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		http.cancel_request()
	
	var body := _force_ollama_body_non_stream(_ollama_stream_body)
	var err := http.request(_ollama_stream_url, _ollama_stream_headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		emit_signal("request_failed", _pending_request_id, "Ollama non-stream fallback request error: %s" % err, 0, "")


func _force_ollama_body_non_stream(body: String) -> String:
	var json := JSON.new()
	if json.parse(body) != OK:
		return body
	if typeof(json.data) != TYPE_DICTIONARY:
		return body
	var data: Dictionary = json.data
	data["stream"] = false
	return JSON.stringify(data)


func _has_header(headers: PackedStringArray, key: String) -> bool:
	var lower_key := key.to_lower()
	for header in headers:
		var line := String(header)
		var separator_index := line.find(":")
		if separator_index <= 0:
			continue
		var current_key := line.left(separator_index).strip_edges().to_lower()
		if current_key == lower_key:
			return true
	return false
