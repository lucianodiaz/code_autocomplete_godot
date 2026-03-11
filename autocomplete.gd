@tool
extends EditorPlugin


var script_editor
var current_code_edit: CodeEdit
var debounce_timer:Timer
var debounce_spin_value:float = 0.2
var last_word : String= ""
var ai_sugestion : String = ""
var http : HTTPRequest = HTTPRequest.new()

const SETTINGS_PREFIX : String = "code_autocomplete/"

enum LLMProvider {
	OLLAMA_GENERATE = 0,
	OPENAI_COMPATIBLE_CHAT = 1,
	GEMINI_GENERATE_CONTENT = 2,
}

var editor_settings: EditorSettings
var config_dock: Control

var _pending_request_id: int = 0
var _last_prompt_context_hash: int = 0
var _ghost_overlay: GhostOverlay
var _ghost_insert_text: String = ""
var _active_request_word: String = ""
var _active_request_retry_count: int = 0
var _active_line_prefix: String = ""
var _active_prompt_mode: String = "statement"
var _active_comment_action: String = "insert"
var _active_comment_target: Dictionary = {}
var _active_comment_insert_target: Dictionary = {}
var _suppress_caret_changed_clear: bool = false

var _active_prefix_context: String = ""
var _active_suffix_context: String = ""

# Streaming state (incremental updates).
var _stream_buffer: String = ""
var _stream_text: String = ""
var _stream_started_at_caret_line: int = 0
var _stream_started_at_caret_col: int = 0

# HTTPClient streaming (Godot 4.5: HTTPRequest does not stream chunks).
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
var _ollama_stream_fallback_requested: bool = false

# Throttle ghost updates to avoid stutter.
var _stream_last_ghost_update_ms: int = 0

func _enable_plugin() -> void:
	# Add autoloads here.
	pass


func _disable_plugin() -> void:
	# Remove autoloads here.
	pass


func _enter_tree() -> void:
	# Initialization of the plugin goes here.
	editor_settings = get_editor_interface().get_editor_settings()
	_ensure_settings_defaults()
	_build_config_dock()
	set_process(true)
	
	script_editor = get_editor_interface().get_script_editor()
	script_editor.connect("editor_script_changed",Callable(self,"_on_script_changed"))
	
	debounce_timer = Timer.new()
	debounce_timer.wait_time = float(_get_setting(SETTINGS_PREFIX + "request/debounce_sec", debounce_spin_value))
	debounce_timer.one_shot = true
	debounce_timer.connect("timeout", Callable(self, "_on_debounce_timeout"))
	add_child(debounce_timer)
	
	add_child(http)
	http.use_threads = true
	http.request_completed.connect(_on_ai_response)
	
	print("[code autocomplete] plugin loaded")


func _process(_delta: float) -> void:
	if _ollama_stream_active:
		_poll_ollama_stream()

func _on_script_changed(script) -> void:
	await get_tree().process_frame
	_hook_code_editor()

func _hook_code_editor() -> void:
	var editor = script_editor.get_current_editor()
	if editor == null:
		return
	
	current_code_edit = editor.get_base_editor()
	
	if current_code_edit == null:
		return
	
	if not current_code_edit.is_connected("text_changed", Callable(self, "_on_text_changed")):
		current_code_edit.connect("text_changed", Callable(self, "_on_text_changed"))
	
	if not current_code_edit.is_connected("caret_changed", Callable(self, "_on_caret_changed")):
		current_code_edit.connect("caret_changed", Callable(self, "_on_caret_changed"))
	
	if not current_code_edit.is_connected("gui_input", Callable(self, "_on_code_edit_gui_input")):
		current_code_edit.connect("gui_input", Callable(self, "_on_code_edit_gui_input"))
	
	_attach_ghost_overlay()
	
	print("[code autocomplete] Completion hook Connected")

func _on_text_changed() -> void:
	_clear_ghost()
	_cancel_inflight_request()
	last_word = _get_current_word()
	_try_show_structural_hint_now()
	debounce_timer.stop()
	debounce_timer.start()


func _on_caret_changed() -> void:
	if _suppress_caret_changed_clear:
		_suppress_caret_changed_clear = false
		return
	_clear_ghost()
	_cancel_inflight_request()


func _on_code_edit_gui_input(event: InputEvent) -> void:
	if _ghost_insert_text == "" or current_code_edit == null:
		return
	
	if event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed or k.echo:
			return
		if k.ctrl_pressed or k.alt_pressed or k.shift_pressed or k.meta_pressed:
			return
		
		# Accept with TAB or Right arrow.
		if k.keycode == KEY_TAB or k.keycode == KEY_RIGHT:
			if _active_prompt_mode == "assistant_comment" and _active_comment_action == "edit_existing" and not _active_comment_target.is_empty():
				_apply_comment_assistant_edit(_ghost_insert_text, _active_comment_target)
			elif _active_prompt_mode == "assistant_comment" and _active_comment_action == "insert" and not _active_comment_insert_target.is_empty():
				_insert_text_at_position(_ghost_insert_text, int(_active_comment_insert_target.get("line", current_code_edit.get_caret_line())), int(_active_comment_insert_target.get("col", current_code_edit.get_caret_column())))
			else:
				current_code_edit.insert_text_at_caret(_ghost_insert_text)
			_clear_ghost()
			current_code_edit.accept_event()
			return
		
		# Dismiss with Esc.
		if k.keycode == KEY_ESCAPE:
			_clear_ghost()
			current_code_edit.accept_event()
			return


func _attach_ghost_overlay() -> void:
	if current_code_edit == null:
		return
	
	if is_instance_valid(_ghost_overlay) and _ghost_overlay.code_edit == current_code_edit:
		return
	
	if is_instance_valid(_ghost_overlay):
		_ghost_overlay.queue_free()
		_ghost_overlay = null
	
	_ghost_overlay = GhostOverlay.new()
	_ghost_overlay.code_edit = current_code_edit
	_ghost_overlay.max_preview_lines = int(_get_setting(SETTINGS_PREFIX + "ghost/max_preview_lines", 0))
	current_code_edit.add_child(_ghost_overlay)
	_ghost_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ghost_overlay.visible = true
	_ghost_overlay.z_as_relative = false
	_ghost_overlay.z_index = 4096


func _ensure_ghost_overlay_ready() -> void:
	if current_code_edit == null:
		return
	if not is_instance_valid(_ghost_overlay):
		_attach_ghost_overlay()
		return
	if _ghost_overlay.code_edit != current_code_edit:
		_attach_ghost_overlay()
		return


func _clear_ghost() -> void:
	_ghost_insert_text = ""
	_active_comment_action = "insert"
	_active_comment_target = {}
	_active_comment_insert_target = {}
	if is_instance_valid(_ghost_overlay):
		_ghost_overlay.clear()


func _show_waiting_feedback(line: int, col: int) -> void:
	_ensure_ghost_overlay_ready()
	if is_instance_valid(_ghost_overlay):
		_ghost_overlay.set_waiting(true, line, col)


func _hide_waiting_feedback() -> void:
	if is_instance_valid(_ghost_overlay):
		_ghost_overlay.set_waiting(false, 0, 0)


func _on_debounce_timeout():
	if _is_comment_assistant_line(_get_current_line_prefix()):
		_request_ai_completion(last_word, 0)
		return
	# If no strong token, still allow local structural hints (e.g. suggest ":" after `for ... )`).
	if last_word == "" or last_word.length() <= 1:
		_try_show_structural_hint_now()
		return
	
	_request_ai_completion(last_word, 0)


func _request_ai_completion(word:String, retry_count: int = 0):
	var line: int = current_code_edit.get_caret_line()
	var column: int = current_code_edit.get_caret_column()
	var current_line_text := current_code_edit.get_line(line)
	_active_line_prefix = current_line_text.left(column)
	var mode := _detect_prompt_mode(_active_line_prefix, word)
	_active_prompt_mode = mode
	_active_comment_action = "insert"
	_active_comment_target = {}
	_active_comment_insert_target = {}
	if mode == "assistant_comment":
		_active_comment_insert_target = {
			"line": line,
			"col": column,
		}
		_active_comment_action = _detect_comment_assistant_action(_extract_comment_assistant_instruction(_active_line_prefix))
		if _active_comment_action == "edit_existing":
			_active_comment_target = _resolve_comment_assistant_target(line)
			if _active_comment_target.is_empty():
				_active_comment_action = "insert"
	if mode != "assistant_comment" and word.length() < 2:
		return
	print("[code autocomplete] AI suggestion to: ",word," mode: ", mode)
	
	#we need only send 20 or 30 lines not all script
	var prefix_context := ""
	var suffix_context := ""
	
	var prefix_lines: int = int(_get_setting(SETTINGS_PREFIX + "context/prefix_lines", 25))
	var start_line := max(0, line - prefix_lines)
	for i in range(start_line,line):
		prefix_context += current_code_edit.get_line(i) + "\n"
	prefix_context += current_code_edit.get_line(line).left(column)
	
	# Suffix context (anchors completion so the model doesn't invent or rewrite).
	if column < current_line_text.length():
		suffix_context += current_line_text.right(current_line_text.length() - column)
	
	var suffix_lines: int = int(_get_setting(SETTINGS_PREFIX + "context/suffix_lines", 30))
	var end_line := min(current_code_edit.get_line_count() - 1, line + suffix_lines)
	for j in range(line + 1, end_line + 1):
		suffix_context += "\n" + current_code_edit.get_line(j)
	
	var context_hash := hash(prefix_context + "\n<<<SUFFIX>>>\n" + suffix_context)
	if context_hash == _last_prompt_context_hash:
		# Avoid re-requesting exactly the same context.
		return
	_last_prompt_context_hash = context_hash
	
	_active_prefix_context = prefix_context
	_active_suffix_context = suffix_context
	_active_request_retry_count = retry_count
	
	_active_request_word = word
	var req: Dictionary = _build_llm_request(prefix_context, suffix_context, word, retry_count > 0)
	if req.is_empty():
		return
	
	var url: String = req.url
	var headers: PackedStringArray = req.headers
	var body: String = req.body
	var wants_stream: bool = bool(req.get("stream", false))
	var provider_id: int = int(req.get("provider_id", int(LLMProvider.OLLAMA_GENERATE)))
	
	# Prefer true streaming via HTTPClient for Ollama only (Godot 4.5 limitation).
	if wants_stream and provider_id == int(LLMProvider.OLLAMA_GENERATE) and url.begins_with("http://"):
		_pending_request_id += 1
		_stream_started_at_caret_line = line
		_stream_started_at_caret_col = column
		_active_prefix_context = prefix_context
		_active_suffix_context = suffix_context
		_start_ollama_httpclient_stream(_pending_request_id, url, headers, body)
		return
	
	# Otherwise, force non-streaming so response is valid JSON for HTTPRequest.
	wants_stream = false
	# If this is Ollama and the body had stream=true, force it off.
	if provider_id == int(LLMProvider.OLLAMA_GENERATE):
		body = _force_ollama_body_non_stream(body)
	http.set_meta("streaming", false)
	
	if http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		http.cancel_request()
	
	_pending_request_id += 1
	var request_id := _pending_request_id
	http.set_meta("request_id", request_id)
	http.set_meta("provider_id", provider_id)
	http.set_meta("streaming", false)
	
	_stream_buffer = ""
	_stream_text = ""
	_stream_started_at_caret_line = line
	_stream_started_at_caret_col = column
	
	var error = http.request(url, headers, HTTPClient.METHOD_POST, body)
	
	if error != OK:
		print("[code autocomplete] Error to get request: ", error)
		_hide_waiting_feedback()
	else:
		_show_waiting_feedback(line, column)
		
		
	

func _on_ai_response(result, response_code,headers,body) -> void:
	if http.has_meta("request_id") and int(http.get_meta("request_id")) != _pending_request_id:
		# Stale response, ignore.
		return
	_hide_waiting_feedback()
	if response_code != 200:
		var raw: String = body.get_string_from_utf8()
		print("[code autocomplete] API Error: ", response_code, " body: ", raw)
		return
	print("[code autocomplete] response_code: ", response_code)
	
	var json = JSON.new()
	var parse_result = json.parse(body.get_string_from_utf8())
	if parse_result != OK:
		print("[code autocomplete] JSON parse error: ", parse_result, " body: ", body.get_string_from_utf8().substr(0, 500))
	
	if parse_result == OK:
		var data = json.data
		var suggestion: String = ""
		if bool(http.get_meta("streaming", false)) and _stream_text.strip_edges() != "":
			suggestion = _stream_text
		else:
			suggestion = _extract_suggestion_from_response(data)
		print("[code autocomplete] raw suggestion (first 120): ", suggestion.substr(0, 120))
		if suggestion.strip_edges() != "":
			suggestion = _sanitize_model_output(suggestion)
			suggestion = _trim_suggestion_to_fit_context(suggestion, _active_suffix_context)
			ai_sugestion = suggestion
	
	print("[code autocomplete] AI suggestion: ", ai_sugestion)
	
	if ai_sugestion != "":
		_show_ai_completion(last_word,ai_sugestion)
		#current_code_edit.update_code_completion_options(true)
	else:
		_try_apply_local_fallback_if_possible()

func _show_ai_completion(prefix:String, suggestion: String) -> void:
	var final_text = suggestion
	if _active_prompt_mode == "assistant_comment":
		if _active_comment_action == "edit_existing" and not _active_comment_target.is_empty():
			final_text = _normalize_comment_edit_output(final_text, _active_comment_target)
		else:
			final_text = _normalize_comment_assistant_output(final_text)
	else:
		if suggestion.begins_with(prefix):
			final_text = suggestion.trim_prefix(prefix)
		else:
			# Case-insensitive prefix trim to avoid drawing over already typed token.
			var s_low := suggestion.to_lower()
			var p_low := prefix.to_lower()
			if p_low != "" and s_low.begins_with(p_low) and suggestion.length() >= prefix.length():
				final_text = suggestion.substr(prefix.length())
		
		final_text = _normalize_completion_spacing(final_text)
	
	if final_text.strip_edges() == "":
		return
	
	# Ghost text (inline preview). Insert full text on accept.
	_ghost_insert_text = final_text
	_ensure_ghost_overlay_ready()
	if is_instance_valid(_ghost_overlay) and current_code_edit != null:
		if _active_prompt_mode == "assistant_comment" and _active_comment_action == "edit_existing" and not _active_comment_target.is_empty():
			_ghost_overlay.set_ghost(final_text, int(_active_comment_target.get("start_line", current_code_edit.get_caret_line())), int(_active_comment_target.get("start_col", 0)))
		else:
			_ghost_overlay.set_ghost(final_text, current_code_edit.get_caret_line(), current_code_edit.get_caret_column())
	if _active_prompt_mode == "assistant_comment":
		_move_caret_to_comment_preview()
	
	
	current_code_edit.add_code_completion_option(
		CodeEdit.KIND_PLAIN_TEXT,
		_ghost_preview_text(final_text),
		final_text,
		Color(1.0, 0.408, 0.785, 1.0))


func _normalize_completion_spacing(text: String) -> String:
	if current_code_edit == null or text == "":
		return text
	
	var line := current_code_edit.get_caret_line()
	var col := current_code_edit.get_caret_column()
	var line_text := current_code_edit.get_line(line)
	if col > line_text.length():
		col = line_text.length()
	
	var prev_char := ""
	if col > 0:
		prev_char = line_text[col - 1]
	
	var out := text
	if out == "":
		return out
	
	var first_char := out[0]
	
	# If we are right after an identifier and suggestion also starts with identifier,
	# force one leading space to avoid cases like `fornode`.
	if prev_char != "" and prev_char.is_valid_identifier():
		if first_char.is_valid_identifier() and not out.begins_with(" ") and not out.begins_with("\t"):
			out = " " + out
	
	# Avoid doubling whitespace when one already exists at caret boundary.
	if (prev_char == " " or prev_char == "\t") and (out.begins_with(" ") or out.begins_with("\t")):
		while out.begins_with(" ") or out.begins_with("\t"):
			out = out.substr(1)
	
	out = _normalize_completion_indentation(out, line_text)
	
	return out


func _normalize_comment_assistant_output(text: String) -> String:
	if current_code_edit == null:
		return text
	var out := _sanitize_model_output(text)
	if out == "":
		return ""
	var line := current_code_edit.get_caret_line()
	var line_text := current_code_edit.get_line(line)
	out = _normalize_completion_indentation(out, line_text)
	if not out.begins_with("\n"):
		out = "\n" + out
	return out


func _normalize_comment_edit_output(text: String, target: Dictionary) -> String:
	var out := _sanitize_model_output(text)
	if out == "":
		return ""
	var base_line_text := str(target.get("line_text", ""))
	return _normalize_full_block_indentation(out, base_line_text)


func _normalize_full_block_indentation(text: String, base_line_text: String) -> String:
	var lines := text.split("\n")
	if lines.is_empty():
		return text

	var base_indent := _leading_whitespace(base_line_text)
	var min_indent_units := -1
	for line in lines:
		var stripped := _left_trim_whitespace(line)
		if stripped == "":
			continue
		var leading := line.substr(0, line.length() - stripped.length())
		var units := _indent_units(leading)
		if min_indent_units == -1 or units < min_indent_units:
			min_indent_units = units

	if min_indent_units < 0:
		return text

	for i in range(lines.size()):
		var stripped := _left_trim_whitespace(lines[i])
		if stripped == "":
			lines[i] = ""
			continue
		var leading := lines[i].substr(0, lines[i].length() - stripped.length())
		var rel_units := max(0, _indent_units(leading) - min_indent_units)
		lines[i] = base_indent + _tabs_from_units(rel_units) + stripped

	return "\n".join(lines)


func _apply_comment_assistant_edit(replacement_text: String, target: Dictionary) -> void:
	if current_code_edit == null:
		return
	var start_line := int(target.get("start_line", -1))
	var end_line := int(target.get("end_line", -1))
	if start_line < 0 or end_line < start_line:
		current_code_edit.insert_text_at_caret(replacement_text)
		return

	var end_col := current_code_edit.get_line(end_line).length()
	current_code_edit.begin_complex_operation()
	current_code_edit.select(start_line, 0, end_line, end_col)
	current_code_edit.delete_selection()
	current_code_edit.insert_text_at_caret(replacement_text)
	current_code_edit.end_complex_operation()


func _insert_text_at_position(text: String, line: int, col: int) -> void:
	if current_code_edit == null:
		return
	_suppress_caret_changed_clear = true
	current_code_edit.set_caret_line(line)
	current_code_edit.set_caret_column(col)
	current_code_edit.insert_text_at_caret(text)


func _move_caret_to_comment_preview() -> void:
	if current_code_edit == null:
		return

	var preview_line := current_code_edit.get_caret_line()
	var preview_col := 0
	if _active_comment_action == "edit_existing" and not _active_comment_target.is_empty():
		preview_line = int(_active_comment_target.get("start_line", preview_line))
		preview_col = int(_active_comment_target.get("start_col", 0))
	elif not _active_comment_insert_target.is_empty():
		preview_line = int(_active_comment_insert_target.get("line", preview_line))
		preview_col = 0

	_suppress_caret_changed_clear = true
	current_code_edit.set_caret_line(preview_line)
	current_code_edit.set_caret_column(preview_col)
	if current_code_edit.has_method("center_viewport_to_caret"):
		current_code_edit.call("center_viewport_to_caret")


func _normalize_completion_indentation(text: String, current_line_text: String) -> String:
	if text.find("\n") < 0:
		return text
	
	var lines := text.split("\n")
	if lines.size() <= 1:
		return text
	
	var first := lines[0].strip_edges()
	var opens_block := first.ends_with(":")
	var base_indent := _leading_whitespace(current_line_text)
	var min_indent_units := 0
	var has_non_empty_tail := false
	
	# Compute minimum indentation (spaces/tabs) of tail lines to preserve relative nesting.
	for i in range(1, lines.size()):
		var raw_line := lines[i]
		var stripped_check := _left_trim_whitespace(raw_line)
		if stripped_check == "":
			continue
		var leading_raw := raw_line.substr(0, raw_line.length() - stripped_check.length())
		var units := _indent_units(leading_raw)
		if not has_non_empty_tail:
			min_indent_units = units
			has_non_empty_tail = true
		else:
			min_indent_units = min(min_indent_units, units)
	
	for i in range(1, lines.size()):
		var l := lines[i]
		var stripped := _left_trim_whitespace(l)
		if stripped == "":
			lines[i] = ""
			continue
		
		if opens_block:
			# Body lines should be indented one level deeper than current line,
			# while preserving the relative indentation that came from the model.
			var leading_raw := l.substr(0, l.length() - stripped.length())
			var rel_units := max(0, _indent_units(leading_raw) - min_indent_units)
			lines[i] = base_indent + "\t" + _tabs_from_units(rel_units) + stripped
		else:
			# Keep line as continuation but normalize leading spaces into tabs.
			var leading := l.substr(0, l.length() - stripped.length())
			lines[i] = _spaces_to_tabs_in_leading(leading) + stripped
	
	return "\n".join(lines)


func _left_trim_whitespace(s: String) -> String:
	var i := 0
	while i < s.length():
		var c := s[i]
		if c != " " and c != "\t":
			break
		i += 1
	return s.substr(i)


func _leading_whitespace(s: String) -> String:
	var i := 0
	while i < s.length():
		var c := s[i]
		if c != " " and c != "\t":
			break
		i += 1
	return s.substr(0, i)


func _spaces_to_tabs_in_leading(leading: String) -> String:
	var out := ""
	var rest := leading
	while rest.begins_with("    "):
		out += "\t"
		rest = rest.substr(4)
	out += rest
	return out


func _indent_units(leading: String) -> int:
	var units := 0
	for i in range(leading.length()):
		var c := leading[i]
		if c == "\t":
			units += 4
		elif c == " ":
			units += 1
	return units


func _tabs_from_units(units: int) -> String:
	var tabs := ""
	var count := int(floor(float(units) / 4.0))
	for i in range(count):
		tabs += "\t"
	return tabs
	
func _get_current_word() -> String:
	if current_code_edit == null:
		return ""
	
	var cursor_line = current_code_edit.get_caret_line()
	var cursor_col = current_code_edit.get_caret_column()
	var line_text = current_code_edit.get_line(cursor_line)
	
	
	if cursor_col > line_text.length():
		cursor_col = line_text.length()
	
	var start = cursor_col
	
	while start > 0 and line_text[start - 1].is_valid_identifier():
		start -= 1
	
	var end = cursor_col
	
	while end < line_text.length() and line_text[end].is_valid_identifier():
		end += 1
		
	
	return line_text.substr(start,end-start)


func _get_current_line_prefix() -> String:
	if current_code_edit == null:
		return ""
	var cursor_line := current_code_edit.get_caret_line()
	var cursor_col := current_code_edit.get_caret_column()
	var line_text := current_code_edit.get_line(cursor_line)
	if cursor_col > line_text.length():
		cursor_col = line_text.length()
	return line_text.left(cursor_col)
	

func _exit_tree() -> void:
	# Clean-up of the plugin goes here.
	if is_instance_valid(config_dock):
		remove_control_from_docks(config_dock)
		config_dock.queue_free()
		config_dock = null
	if is_instance_valid(_ghost_overlay):
		_ghost_overlay.queue_free()
		_ghost_overlay = null
	pass


func _ensure_settings_defaults() -> void:
	if editor_settings == null:
		return
	
	_set_default(SETTINGS_PREFIX + "provider", int(LLMProvider.OLLAMA_GENERATE))
	# "Modelo gratuito" por defecto: Ollama local (sin API key), si el usuario lo tiene instalado.
	_set_default(SETTINGS_PREFIX + "ollama/url", "http://localhost:11434/api/generate")
	_set_default(SETTINGS_PREFIX + "ollama/model", "qwen2.5-coder:1.5b")
	
	_set_default(SETTINGS_PREFIX + "openai/url", "https://api.groq.com/openai/v1/chat/completions")
	_set_default(SETTINGS_PREFIX + "openai/model", "groq/compound-mini")
	_set_default(SETTINGS_PREFIX + "openai/api_key", "")
	
	_set_default(SETTINGS_PREFIX + "gemini/url_base", "https://generativelanguage.googleapis.com/v1beta/models")
	_set_default(SETTINGS_PREFIX + "gemini/model", "gemini-1.5-flash")
	_set_default(SETTINGS_PREFIX + "gemini/api_key", "")
	
	_set_default(SETTINGS_PREFIX + "temperature", 0.2)
	_set_default(SETTINGS_PREFIX + "max_tokens", 0)
	_set_default(SETTINGS_PREFIX + "extra_headers", "")
	_set_default(SETTINGS_PREFIX + "context/prefix_lines", 25)
	_set_default(SETTINGS_PREFIX + "context/suffix_lines", 20)
	_set_default(SETTINGS_PREFIX + "godot_context/enabled", true)
	_set_default(SETTINGS_PREFIX + "godot_context/max_classes", 4)
	_set_default(SETTINGS_PREFIX + "godot_context/max_members_per_class", 12)
	_set_default(SETTINGS_PREFIX + "streaming/enabled", true)
	_set_default(SETTINGS_PREFIX + "request/debounce_sec", debounce_spin_value)
	_set_default(SETTINGS_PREFIX + "request/stream_timeout_ms", 25000)
	_set_default(SETTINGS_PREFIX + "ghost/max_preview_lines", 0)
	#
	# EditorSettings persists automatically in the editor.


func _set_default(key: String, value) -> void:
	if not editor_settings.has_setting(key):
		editor_settings.set_setting(key, value)


func _get_setting(key: String, default_value):
	if editor_settings == null:
		return default_value
	if editor_settings.has_setting(key):
		return editor_settings.get_setting(key)
	return default_value


func _save_setting(key: String, value) -> void:
	if editor_settings == null:
		return
	editor_settings.set_setting(key, value)
	# EditorSettings persists automatically in the editor.


func _build_config_dock() -> void:
	if is_instance_valid(config_dock):
		return
	
	var root := VBoxContainer.new()
	root.name = "AI Autocomplete"
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	var title := Label.new()
	title.text = "Code Autocomplete (LLM)"
	root.add_child(title)
	
	var provider_row := HBoxContainer.new()
	var provider_label := Label.new()
	provider_label.text = "Proveedor"
	provider_label.custom_minimum_size.x = 90
	provider_row.add_child(provider_label)
	
	var provider_opt := OptionButton.new()
	provider_opt.add_item("Ollama (local, gratis)", int(LLMProvider.OLLAMA_GENERATE))
	provider_opt.add_item("OpenAI-compatible (Chat)", int(LLMProvider.OPENAI_COMPATIBLE_CHAT))
	provider_opt.add_item("Gemini (Google AI)", int(LLMProvider.GEMINI_GENERATE_CONTENT))
	provider_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	provider_row.add_child(provider_opt)
	root.add_child(provider_row)
	
	var temp_row := HBoxContainer.new()
	var temp_label := Label.new()
	temp_label.text = "Temperatura"
	temp_label.custom_minimum_size.x = 90
	temp_row.add_child(temp_label)
	var temp_spin := SpinBox.new()
	temp_spin.min_value = 0.0
	temp_spin.max_value = 2.0
	temp_spin.step = 0.05
	temp_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	temp_row.add_child(temp_spin)
	root.add_child(temp_row)
	
	var tokens_row := HBoxContainer.new()
	var tokens_label := Label.new()
	tokens_label.text = "Max tokens"
	tokens_label.tooltip_text = "0 = sin limite artificial del plugin"
	tokens_label.custom_minimum_size.x = 90
	tokens_row.add_child(tokens_label)
	var tokens_spin := SpinBox.new()
	tokens_spin.min_value = 0
	tokens_spin.max_value = 8192
	tokens_spin.step = 16
	tokens_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tokens_spin.tooltip_text = "0 = sin limite artificial del plugin"
	tokens_row.add_child(tokens_spin)
	root.add_child(tokens_row)
	
	var prefix_row := HBoxContainer.new()
	var prefix_label := Label.new()
	prefix_label.text = "Prefix líneas"
	prefix_label.custom_minimum_size.x = 90
	prefix_row.add_child(prefix_label)
	var prefix_spin := SpinBox.new()
	prefix_spin.min_value = 5
	prefix_spin.max_value = 200
	prefix_spin.step = 1
	prefix_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prefix_row.add_child(prefix_spin)
	root.add_child(prefix_row)
	
	var suffix_row := HBoxContainer.new()
	var suffix_label := Label.new()
	suffix_label.text = "Suffix líneas"
	suffix_label.custom_minimum_size.x = 90
	suffix_row.add_child(suffix_label)
	var suffix_spin := SpinBox.new()
	suffix_spin.min_value = 0
	suffix_spin.max_value = 100
	suffix_spin.step = 1
	suffix_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	suffix_row.add_child(suffix_spin)
	root.add_child(suffix_row)

	var godot_ctx_row := HBoxContainer.new()
	var godot_ctx_label := Label.new()
	godot_ctx_label.text = "Godot strict"
	godot_ctx_label.tooltip_text = "Inyecta solo APIs reales de Godot detectadas desde ClassDB"
	godot_ctx_label.custom_minimum_size.x = 90
	godot_ctx_row.add_child(godot_ctx_label)
	var godot_ctx_check := CheckBox.new()
	godot_ctx_check.text = "Activado"
	godot_ctx_check.tooltip_text = "Inyecta solo APIs reales de Godot detectadas desde ClassDB"
	godot_ctx_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	godot_ctx_row.add_child(godot_ctx_check)
	root.add_child(godot_ctx_row)
	
	var stream_row := HBoxContainer.new()
	var stream_label := Label.new()
	stream_label.text = "Streaming"
	stream_label.custom_minimum_size.x = 90
	stream_row.add_child(stream_label)
	var stream_check := CheckBox.new()
	stream_check.text = "Activado"
	stream_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stream_row.add_child(stream_check)
	root.add_child(stream_row)
	
	var debounce_row := HBoxContainer.new()
	var debounce_label := Label.new()
	debounce_label.text = "Debounce (s)"
	debounce_label.custom_minimum_size.x = 90
	debounce_row.add_child(debounce_label)
	var debounce_spin := SpinBox.new()
	debounce_spin.min_value = 0.05
	debounce_spin.max_value = 2.0
	debounce_spin.step = 0.05
	debounce_spin.value = debounce_spin_value
	debounce_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	debounce_row.add_child(debounce_spin)
	root.add_child(debounce_row)
	
	var stream_timeout_row := HBoxContainer.new()
	var stream_timeout_label := Label.new()
	stream_timeout_label.text = "Stream timeout"
	stream_timeout_label.custom_minimum_size.x = 90
	stream_timeout_row.add_child(stream_timeout_label)
	var stream_timeout_spin := SpinBox.new()
	stream_timeout_spin.min_value = 2.0
	stream_timeout_spin.max_value = 120.0
	stream_timeout_spin.step = 0.5
	stream_timeout_spin.suffix = " s"
	stream_timeout_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stream_timeout_row.add_child(stream_timeout_spin)
	root.add_child(stream_timeout_row)
	
	var ghost_lines_row := HBoxContainer.new()
	var ghost_lines_label := Label.new()
	ghost_lines_label.text = "Ghost líneas"
	ghost_lines_label.tooltip_text = "0 = mostrar todo el bloque sugerido"
	ghost_lines_label.custom_minimum_size.x = 90
	ghost_lines_row.add_child(ghost_lines_label)
	var ghost_lines_spin := SpinBox.new()
	ghost_lines_spin.min_value = 0
	ghost_lines_spin.max_value = 200
	ghost_lines_spin.step = 1
	ghost_lines_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ghost_lines_spin.tooltip_text = "0 = mostrar todo el bloque sugerido"
	ghost_lines_row.add_child(ghost_lines_spin)
	root.add_child(ghost_lines_row)

	var godot_classes_row := HBoxContainer.new()
	var godot_classes_label := Label.new()
	godot_classes_label.text = "Clases doc"
	godot_classes_label.tooltip_text = "Cuantas clases de Godot incluir en el contexto"
	godot_classes_label.custom_minimum_size.x = 90
	godot_classes_row.add_child(godot_classes_label)
	var godot_classes_spin := SpinBox.new()
	godot_classes_spin.min_value = 1
	godot_classes_spin.max_value = 8
	godot_classes_spin.step = 1
	godot_classes_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	godot_classes_spin.tooltip_text = "Cuantas clases de Godot incluir en el contexto"
	godot_classes_row.add_child(godot_classes_spin)
	root.add_child(godot_classes_row)

	var godot_members_row := HBoxContainer.new()
	var godot_members_label := Label.new()
	godot_members_label.text = "Miembros doc"
	godot_members_label.tooltip_text = "Cuantos metodos/propiedades/señales listar por clase"
	godot_members_label.custom_minimum_size.x = 90
	godot_members_row.add_child(godot_members_label)
	var godot_members_spin := SpinBox.new()
	godot_members_spin.min_value = 4
	godot_members_spin.max_value = 30
	godot_members_spin.step = 1
	godot_members_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	godot_members_spin.tooltip_text = "Cuantos metodos/propiedades/señales listar por clase"
	godot_members_row.add_child(godot_members_spin)
	root.add_child(godot_members_row)
	
	var sep1 := HSeparator.new()
	root.add_child(sep1)
	
	var ollama_title := Label.new()
	ollama_title.text = "Ollama"
	root.add_child(ollama_title)
	
	var ollama_url := _make_labeled_line_edit("URL", 90)
	root.add_child(ollama_url.row)
	
	var ollama_model := _make_labeled_line_edit("Modelo", 90)
	root.add_child(ollama_model.row)
	
	var sep2 := HSeparator.new()
	root.add_child(sep2)
	
	var openai_title := Label.new()
	openai_title.text = "OpenAI-compatible"
	root.add_child(openai_title)
	
	var openai_url := _make_labeled_line_edit("URL", 90)
	root.add_child(openai_url.row)
	
	var openai_model := _make_labeled_line_edit("Modelo", 90)
	root.add_child(openai_model.row)
	
	var openai_key := _make_labeled_line_edit("API key", 90)
	openai_key.edit.secret = true
	openai_key.edit.placeholder_text = "opcional (depende del proveedor)"
	root.add_child(openai_key.row)
	
	var extra_headers_label := Label.new()
	extra_headers_label.text = "Headers extra (1 por línea, ej: X-Foo: bar)"
	root.add_child(extra_headers_label)
	var extra_headers := TextEdit.new()
	extra_headers.custom_minimum_size.y = 70
	extra_headers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	extra_headers.size_flags_vertical = Control.SIZE_FILL
	root.add_child(extra_headers)
	
	var sep3 := HSeparator.new()
	root.add_child(sep3)
	
	var gemini_title := Label.new()
	gemini_title.text = "Gemini (API nativa)"
	root.add_child(gemini_title)
	
	var gemini_url_base := _make_labeled_line_edit("URL base", 90)
	gemini_url_base.edit.placeholder_text = "https://generativelanguage.googleapis.com/v1beta/models"
	root.add_child(gemini_url_base.row)
	
	var gemini_model := _make_labeled_line_edit("Modelo", 90)
	gemini_model.edit.placeholder_text = "gemini-1.5-flash"
	root.add_child(gemini_model.row)
	
	var gemini_key := _make_labeled_line_edit("API key", 90)
	gemini_key.edit.secret = true
	gemini_key.edit.placeholder_text = "Google AI Studio key"
	root.add_child(gemini_key.row)
	
	# Load settings
	var provider_id: int = int(_get_setting(SETTINGS_PREFIX + "provider", int(LLMProvider.OLLAMA_GENERATE)))
	provider_opt.select(provider_opt.get_item_index(provider_id))
	temp_spin.value = float(_get_setting(SETTINGS_PREFIX + "temperature", 0.2))
	tokens_spin.value = int(_get_setting(SETTINGS_PREFIX + "max_tokens", 0))
	prefix_spin.value = int(_get_setting(SETTINGS_PREFIX + "context/prefix_lines", 25))
	suffix_spin.value = int(_get_setting(SETTINGS_PREFIX + "context/suffix_lines", 20))
	godot_ctx_check.button_pressed = bool(_get_setting(SETTINGS_PREFIX + "godot_context/enabled", true))
	stream_check.button_pressed = bool(_get_setting(SETTINGS_PREFIX + "streaming/enabled", true))
	debounce_spin.value = float(_get_setting(SETTINGS_PREFIX + "request/debounce_sec", debounce_spin_value))
	stream_timeout_spin.value = float(_get_setting(SETTINGS_PREFIX + "request/stream_timeout_ms", 25000)) / 1000.0
	ghost_lines_spin.value = int(_get_setting(SETTINGS_PREFIX + "ghost/max_preview_lines", 0))
	godot_classes_spin.value = int(_get_setting(SETTINGS_PREFIX + "godot_context/max_classes", 4))
	godot_members_spin.value = int(_get_setting(SETTINGS_PREFIX + "godot_context/max_members_per_class", 12))
	
	ollama_url.edit.text = str(_get_setting(SETTINGS_PREFIX + "ollama/url", "http://localhost:11434/api/generate"))
	ollama_model.edit.text = str(_get_setting(SETTINGS_PREFIX + "ollama/model", "qwen2.5-coder:1.5b"))
	
	openai_url.edit.text = str(_get_setting(SETTINGS_PREFIX + "openai/url", "https://api.groq.com/openai/v1/chat/completions"))
	openai_model.edit.text = str(_get_setting(SETTINGS_PREFIX + "openai/model", "groq/compound-mini"))
	openai_key.edit.text = str(_get_setting(SETTINGS_PREFIX + "openai/api_key", ""))
	
	gemini_url_base.edit.text = str(_get_setting(SETTINGS_PREFIX + "gemini/url_base", "https://generativelanguage.googleapis.com/v1beta/models"))
	gemini_model.edit.text = str(_get_setting(SETTINGS_PREFIX + "gemini/model", "gemini-1.5-flash"))
	gemini_key.edit.text = str(_get_setting(SETTINGS_PREFIX + "gemini/api_key", ""))
	
	extra_headers.text = str(_get_setting(SETTINGS_PREFIX + "extra_headers", ""))
	
	# Save on change
	provider_opt.item_selected.connect(func(idx: int) -> void:
		_save_setting(SETTINGS_PREFIX + "provider", int(provider_opt.get_item_id(idx)))
	)
	
	temp_spin.value_changed.connect(func(v: float) -> void:
		_save_setting(SETTINGS_PREFIX + "temperature", v)
	)
	
	tokens_spin.value_changed.connect(func(v: float) -> void:
		_save_setting(SETTINGS_PREFIX + "max_tokens", int(v))
	)
	
	prefix_spin.value_changed.connect(func(v: float) -> void:
		_save_setting(SETTINGS_PREFIX + "context/prefix_lines", int(v))
	)
	
	suffix_spin.value_changed.connect(func(v: float) -> void:
		_save_setting(SETTINGS_PREFIX + "context/suffix_lines", int(v))
	)

	godot_ctx_check.toggled.connect(func(pressed: bool) -> void:
		_save_setting(SETTINGS_PREFIX + "godot_context/enabled", pressed)
	)
	
	stream_check.toggled.connect(func(pressed: bool) -> void:
		_save_setting(SETTINGS_PREFIX + "streaming/enabled", pressed)
	)
	
	debounce_spin.value_changed.connect(func(v: float) -> void:
		_save_setting(SETTINGS_PREFIX + "request/debounce_sec", v)
		if is_instance_valid(debounce_timer):
			debounce_timer.wait_time = v
	)
	
	stream_timeout_spin.value_changed.connect(func(v: float) -> void:
		_save_setting(SETTINGS_PREFIX + "request/stream_timeout_ms", int(v * 1000.0))
	)
	
	ghost_lines_spin.value_changed.connect(func(v: float) -> void:
		_save_setting(SETTINGS_PREFIX + "ghost/max_preview_lines", int(v))
		if is_instance_valid(_ghost_overlay):
			_ghost_overlay.max_preview_lines = int(v)
			_ghost_overlay.queue_redraw()
	)

	godot_classes_spin.value_changed.connect(func(v: float) -> void:
		_save_setting(SETTINGS_PREFIX + "godot_context/max_classes", int(v))
	)

	godot_members_spin.value_changed.connect(func(v: float) -> void:
		_save_setting(SETTINGS_PREFIX + "godot_context/max_members_per_class", int(v))
	)
	
	ollama_url.edit.text_changed.connect(func(t: String) -> void:
		_save_setting(SETTINGS_PREFIX + "ollama/url", t)
	)
	ollama_model.edit.text_changed.connect(func(t: String) -> void:
		_save_setting(SETTINGS_PREFIX + "ollama/model", t)
	)
	
	openai_url.edit.text_changed.connect(func(t: String) -> void:
		_save_setting(SETTINGS_PREFIX + "openai/url", t)
	)
	openai_model.edit.text_changed.connect(func(t: String) -> void:
		_save_setting(SETTINGS_PREFIX + "openai/model", t)
	)
	openai_key.edit.text_changed.connect(func(t: String) -> void:
		_save_setting(SETTINGS_PREFIX + "openai/api_key", t)
	)
	
	gemini_url_base.edit.text_changed.connect(func(t: String) -> void:
		_save_setting(SETTINGS_PREFIX + "gemini/url_base", t)
	)
	gemini_model.edit.text_changed.connect(func(t: String) -> void:
		_save_setting(SETTINGS_PREFIX + "gemini/model", t)
	)
	gemini_key.edit.text_changed.connect(func(t: String) -> void:
		_save_setting(SETTINGS_PREFIX + "gemini/api_key", t)
	)
	
	extra_headers.text_changed.connect(func() -> void:
		_save_setting(SETTINGS_PREFIX + "extra_headers", extra_headers.text)
	)
	
	config_dock = root
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, config_dock)


func _make_labeled_line_edit(label_text: String, label_width: float) -> Dictionary:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = label_width
	row.add_child(label)
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(edit)
	return {"row": row, "edit": edit}


func _build_llm_request(prefix_context: String, suffix_context: String, current_word: String, strict_mode: bool = false) -> Dictionary:
	var provider_id: int = int(_get_setting(SETTINGS_PREFIX + "provider", int(LLMProvider.OLLAMA_GENERATE)))
	var temperature: float = float(_get_setting(SETTINGS_PREFIX + "temperature", 0.2))
	var streaming_enabled: bool = bool(_get_setting(SETTINGS_PREFIX + "streaming/enabled", true))
	
	var headers: PackedStringArray = ["Content-Type: application/json"]
	headers.append_array(_parse_extra_headers(str(_get_setting(SETTINGS_PREFIX + "extra_headers", ""))))
	
	var mode := _detect_prompt_mode(_active_line_prefix, current_word)
	var max_tokens: int = _get_effective_max_tokens(mode)
	var godot_reference := _build_godot_reference_context(prefix_context, suffix_context, current_word)
	var instruction := _build_prompt_instruction(mode, strict_mode, godot_reference != "")
	var prompt_text := _build_prompt_text(mode, instruction, current_word, prefix_context, suffix_context, godot_reference)
	print("[code autocomplete] prompt mode: ", mode)
	
	if provider_id == int(LLMProvider.OLLAMA_GENERATE):
		var url := str(_get_setting(SETTINGS_PREFIX + "ollama/url", "http://localhost:11434/api/generate"))
		var model := str(_get_setting(SETTINGS_PREFIX + "ollama/model", "qwen2.5-coder:1.5b"))
		var options := {
			"temperature": temperature,
		}
		if max_tokens > 0:
			options["num_predict"] = max_tokens
		var body := JSON.stringify({
			"model": model,
			"prompt": prompt_text,
			"stream": streaming_enabled,
			"options": options,
		})
		return {"url": url, "headers": headers, "body": body, "stream": streaming_enabled, "provider_id": provider_id}
	
	if provider_id == int(LLMProvider.OPENAI_COMPATIBLE_CHAT):
		var url := str(_get_setting(SETTINGS_PREFIX + "openai/url", "https://api.openai.com/v1/chat/completions"))
		var model := str(_get_setting(SETTINGS_PREFIX + "openai/model", "gpt-4o-mini"))
		var api_key := str(_get_setting(SETTINGS_PREFIX + "openai/api_key", "")).strip_edges()
		if api_key != "":
			headers.append("Authorization: Bearer %s" % api_key)
		
		var payload := {
			"model": model,
			"messages": [
				{"role": "system", "content": instruction},
				{"role": "user", "content": "<PREFIX>\n" + prefix_context + "\n</PREFIX>\n<SUFFIX>\n" + suffix_context + "\n</SUFFIX>"},
			],
			"temperature": temperature,
			# NOTE: Godot 4.5 HTTPRequest can't stream chunks; we keep this non-streaming.
			"stream": false,
		}
		if max_tokens > 0:
			payload["max_tokens"] = max_tokens
		var body := JSON.stringify(payload)
		return {"url": url, "headers": headers, "body": body, "stream": false, "provider_id": provider_id}
	
	if provider_id == int(LLMProvider.GEMINI_GENERATE_CONTENT):
		var url_base := str(_get_setting(SETTINGS_PREFIX + "gemini/url_base", "https://generativelanguage.googleapis.com/v1beta/models")).strip_edges()
		var model := str(_get_setting(SETTINGS_PREFIX + "gemini/model", "gemini-1.5-flash")).strip_edges()
		var api_key := str(_get_setting(SETTINGS_PREFIX + "gemini/api_key", "")).strip_edges()
		if api_key == "":
			print("[code autocomplete] Gemini API key is empty. Set it in the dock.")
			return {}
		
		# Native Gemini endpoint: {url_base}/{model}:generateContent
		var url := "%s/%s:generateContent" % [url_base.trim_suffix("/"), model]
		headers.append("x-goog-api-key: %s" % api_key)
		
		# Keep the instruction in the prompt for broad compatibility.
		var generation_config := {
			"temperature": temperature,
		}
		if max_tokens > 0:
			generation_config["maxOutputTokens"] = max_tokens
		var body := JSON.stringify({
			"contents": [
				{
					"role": "user",
					"parts": [{"text": prompt_text}]
				}
			],
			"generationConfig": generation_config
		})
		return {"url": url, "headers": headers, "body": body, "stream": false, "provider_id": provider_id}
	
	print("[code autocomplete] Unknown provider: ", provider_id)
	return {}


func _detect_prompt_mode(line_prefix: String, current_word: String) -> String:
	var lp := line_prefix.strip_edges().to_lower()
	var cw := current_word.strip_edges().to_lower()
	var header_keywords := ["for", "if", "while", "match", "func"]
	if _is_comment_assistant_line(line_prefix):
		return "assistant_comment"
	
	for kw in header_keywords:
		if lp.begins_with(kw + " "):
			return "header"
		if lp == kw:
			return "header"
		if cw == kw:
			return "header"
	
	return "statement"


func _build_prompt_instruction(mode: String, strict_mode: bool, has_godot_reference: bool) -> String:
	var base := "Eres un asistente de autocompletado para GDScript.\n" + \
		"Devuelve SOLO el texto a insertar en el cursor.\n" + \
		"Sin comentarios, sin markdown, sin fences.\n" + \
		"No repitas el código ya escrito.\n"

	if has_godot_reference:
		base += "MODO GODOT STRICT: usa solo clases, metodos, propiedades y señales reales de Godot presentes en la referencia.\n" + \
			"No inventes APIs. Si no estas seguro, usa una alternativa mas simple basada en la referencia.\n"
	
	if mode == "assistant_comment":
		base += "MODO ASISTENTE POR COMENTARIO: el usuario escribió una instrucción en un comentario.\n" + \
			"Genera código GDScript útil para cumplir esa instrucción.\n" + \
			"No repitas el comentario ni expliques nada.\n" + \
			"Puedes generar una o varias líneas, incluyendo funciones completas si hace falta.\n" + \
			"Si la instrucción requiere un bloque completo, devuélvelo completo y no lo cortes a mitad.\n"
		if _active_comment_action == "edit_existing":
			base += "MODO EDICION: debes devolver SOLO la version final completa del bloque objetivo para reemplazarlo.\n" + \
				"No devuelvas diffs, ni explicaciones, ni texto parcial.\n"
	elif mode == "header":
		base += "MODO CABECERA: completa una cabecera de control/función.\n" + \
			"Debe ser sintácticamente válida para GDScript.\n" + \
			"Prioriza completar 'for/if/while/match/func' con continuación útil.\n"
	else:
		base += "MODO SENTENCIA: completa SOLO la línea actual.\n" + \
			"NO generes nuevas funciones, clases o bloques lejanos.\n" 
	
	if strict_mode:
		base += "PROHIBIDO devolver solo la palabra actual; debes continuarla de forma útil.\n"
	
	return base


func _build_prompt_text(mode: String, instruction: String, current_word: String, prefix_context: String, suffix_context: String, godot_reference: String) -> String:
	var example_block := ""
	var godot_block := ""
	if godot_reference != "":
		godot_block = "Referencia Godot verificada:\n" + godot_reference + "\n\n"
	if mode == "assistant_comment":
		var user_instruction := _extract_comment_assistant_instruction(_active_line_prefix)
		example_block = "Ejemplo:\n" + \
			"- instrucción: \"Haz una función que reciba un nodo y devuelva su primer hijo\"\n" + \
			"- salida válida: \"func get_first_child(node: Node) -> Node:\\n\\tif node == null or node.get_child_count() == 0:\\n\\t\\treturn null\\n\\treturn node.get_child(0)\"\n"
		var target_block := ""
		if _active_comment_action == "edit_existing" and not _active_comment_target.is_empty():
			target_block = "Bloque objetivo a reemplazar:\n" + str(_active_comment_target.get("text", "")) + "\n\n"
		return instruction + "\n" + example_block + "\n" + godot_block + \
			"Instrucción del comentario:\n" + user_instruction + "\n\n" + \
			target_block + \
			"Contexto antes del cursor:\n" + prefix_context + "\n\n" + \
			"Contexto después del cursor:\n" + suffix_context + "\n\n" + \
			("Responde SOLO con el bloque final que reemplaza el objetivo.\n" if _active_comment_action == "edit_existing" else "Responde SOLO con código GDScript para insertar debajo del comentario.\n")
	if mode == "header":
		example_block = "Ejemplos:\n" + \
			"- palabra actual: for | salida válida: \" i in range(count):\"\n" + \
			"- palabra actual: if  | salida válida: \" condition:\"\n" + \
			"- palabra actual: while | salida válida: \" running:\"\n" + \
			"- palabra actual: func | salida válida: \" _ready() -> void:\"\n"
	
	return instruction + "\n" + example_block + "\n" + godot_block + \
		"Palabra actual: " + current_word + "\n" + \
		"PREFIX:\n" + prefix_context + "\n" + \
		"SUFFIX:\n" + suffix_context + "\n" + \
		"Responde SOLO con el texto a insertar entre PREFIX y SUFFIX.\n" + \
		"Sigue la logica de la cabecera o sentencia que se esté completando." + \
		"Si es un header, utiliza los ejemplos considerando el contexto de prefijo y sufijo."


func _build_godot_reference_context(prefix_context: String, suffix_context: String, current_word: String) -> String:
	if not bool(_get_setting(SETTINGS_PREFIX + "godot_context/enabled", true)):
		return ""

	var max_classes := int(_get_setting(SETTINGS_PREFIX + "godot_context/max_classes", 4))
	var max_members := int(_get_setting(SETTINGS_PREFIX + "godot_context/max_members_per_class", 12))
	if max_classes <= 0 or max_members <= 0:
		return ""

	var class_names: Array = _collect_relevant_godot_classes(prefix_context, suffix_context, current_word, max_classes)
	if class_names.is_empty():
		return ""

	var blocks: Array = []
	for godot_class in class_names:
		var block := _format_godot_class_reference(str(godot_class), max_members)
		if block != "":
			blocks.append(block)

	return "\n\n".join(blocks)


func _collect_relevant_godot_classes(prefix_context: String, suffix_context: String, current_word: String, max_classes: int) -> Array:
	var ordered: Array = []
	var seen := {}

	var base_class := _get_current_script_base_class()
	_push_unique_class_name(ordered, seen, base_class)

	var current_symbol := current_word.strip_edges()
	if ClassDB.class_exists(current_symbol):
		_push_unique_class_name(ordered, seen, current_symbol)

	var identifiers := _extract_identifiers(prefix_context + "\n" + suffix_context)
	for token in identifiers:
		if not _looks_like_godot_class_name(token):
			continue
		if ClassDB.class_exists(token):
			_push_unique_class_name(ordered, seen, token)
		if ordered.size() >= max_classes:
			break

	return ordered.slice(0, min(ordered.size(), max_classes))


func _push_unique_class_name(ordered: Array, seen: Dictionary, godot_class: String) -> void:
	if godot_class == "" or not ClassDB.class_exists(godot_class):
		return
	if seen.has(godot_class):
		return
	seen[godot_class] = true
	ordered.append(godot_class)


func _format_godot_class_reference(godot_class: String, max_members: int) -> String:
	if not ClassDB.class_exists(godot_class):
		return ""

	var lines: Array = []
	lines.append("Clase: " + godot_class)

	var parent := ClassDB.get_parent_class(godot_class)
	if parent != "":
		lines.append("- hereda de: " + parent)

	var methods := _collect_named_members(ClassDB.class_get_method_list(godot_class), max_members, true)
	if not methods.is_empty():
		lines.append("- métodos: " + ", ".join(methods))

	var properties := _collect_named_members(ClassDB.class_get_property_list(godot_class), max_members, false)
	if not properties.is_empty():
		lines.append("- propiedades: " + ", ".join(properties))

	var signals := _collect_named_members(ClassDB.class_get_signal_list(godot_class), max_members, false)
	if not signals.is_empty():
		lines.append("- señales: " + ", ".join(signals))

	return "\n".join(lines)


func _collect_named_members(raw_list: Array, max_items: int, skip_private: bool) -> Array:
	var out: Array = []
	var seen := {}

	for item in raw_list:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var name := str(item.get("name", "")).strip_edges()
		if name == "":
			continue
		if skip_private and name.begins_with("_"):
			continue
		if seen.has(name):
			continue
		seen[name] = true
		out.append(name)
		if out.size() >= max_items:
			break

	return out


func _get_current_script_base_class() -> String:
	if current_code_edit == null:
		return ""

	var max_scan_lines := min(current_code_edit.get_line_count(), 80)
	for i in range(max_scan_lines):
		var line := current_code_edit.get_line(i).strip_edges()
		if line.begins_with("extends "):
			return line.trim_prefix("extends ").strip_edges()

	return ""


func _extract_identifiers(text: String) -> Array:
	var out: Array = []
	var seen := {}
	var token := ""

	for i in range(text.length()):
		var c := text[i]
		if _is_identifier_char(c):
			token += c
			continue
		_push_identifier_token(out, seen, token)
		token = ""

	_push_identifier_token(out, seen, token)
	return out


func _push_identifier_token(out: Array, seen: Dictionary, token: String) -> void:
	if token == "" or seen.has(token):
		return
	seen[token] = true
	out.append(token)


func _is_identifier_char(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_"


func _looks_like_godot_class_name(token: String) -> bool:
	if token.length() < 3:
		return false
	var first := token[0]
	return first >= "A" and first <= "Z"


func _is_comment_assistant_line(line_prefix: String) -> bool:
	var instruction := _extract_comment_assistant_instruction(line_prefix).to_lower()
	if instruction == "":
		return false
	var triggers := [
		"haz ",
		"crea ",
		"genera ",
		"mejora ",
		"refactor",
		"renombra ",
		"rename ",
		"improve ",
		"cleanup ",
		"clean up ",
		"optimiza ",
		"optimize ",
		"implementa ",
		"escribe ",
		"make ",
		"create ",
		"generate ",
		"write ",
		"add ",
	]
	for trigger in triggers:
		if instruction.begins_with(trigger):
			return true
	return false


func _extract_comment_assistant_instruction(line_prefix: String) -> String:
	var stripped := line_prefix.strip_edges()
	if not stripped.begins_with("#"):
		return ""
	var instruction := stripped.trim_prefix("#").strip_edges()
	return instruction


func _detect_comment_assistant_action(instruction: String) -> String:
	var low := instruction.to_lower().strip_edges()
	var edit_markers := [
		"mejora",
		"refactor",
		"renombra",
		"rename",
		"cleanup",
		"clean up",
		"optimiza",
		"optimize",
	]
	for marker in edit_markers:
		if low.find(marker) >= 0:
			return "edit_existing"
	return "insert"


func _resolve_comment_assistant_target(comment_line: int) -> Dictionary:
	if current_code_edit == null:
		return {}

	var next_target := _find_next_structural_block_after_line(comment_line)
	if not next_target.is_empty():
		return next_target

	return _find_enclosing_structural_block(comment_line)


func _find_next_structural_block_after_line(start_line: int) -> Dictionary:
	var line_count := current_code_edit.get_line_count()
	for i in range(start_line + 1, line_count):
		var raw := current_code_edit.get_line(i)
		var stripped := raw.strip_edges()
		if stripped == "" or stripped.begins_with("#"):
			continue
		if stripped.begins_with("func ") or stripped.begins_with("class "):
			return _extract_indented_block_at_line(i)
		break
	return {}


func _find_enclosing_structural_block(line: int) -> Dictionary:
	for i in range(line - 1, -1, -1):
		var raw := current_code_edit.get_line(i)
		var stripped := raw.strip_edges()
		if stripped.begins_with("func ") or stripped.begins_with("class "):
			return _extract_indented_block_at_line(i)
	return {}


func _extract_indented_block_at_line(start_line: int) -> Dictionary:
	if current_code_edit == null or start_line < 0 or start_line >= current_code_edit.get_line_count():
		return {}

	var first_line := current_code_edit.get_line(start_line)
	var first_stripped := first_line.strip_edges()
	if first_stripped == "":
		return {}

	var base_indent := _indent_units(_leading_whitespace(first_line))
	var end_line := start_line
	var line_count := current_code_edit.get_line_count()

	for i in range(start_line + 1, line_count):
		var raw := current_code_edit.get_line(i)
		var stripped := raw.strip_edges()
		if stripped == "":
			end_line = i
			continue
		if stripped.begins_with("#"):
			end_line = i
			continue

		var indent := _indent_units(_leading_whitespace(raw))
		if indent <= base_indent:
			break
		end_line = i

	var text_lines: Array = []
	for i in range(start_line, end_line + 1):
		text_lines.append(current_code_edit.get_line(i))

	return {
		"start_line": start_line,
		"start_col": 0,
		"end_line": end_line,
		"kind": "class" if first_stripped.begins_with("class ") else "func",
		"line_text": first_line,
		"text": "\n".join(text_lines),
	}


func _parse_extra_headers(raw: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for line in raw.split("\n"):
		var h := line.strip_edges()
		if h == "":
			continue
		if not h.contains(":"):
			continue
		out.append(h)
	return out


func _extract_suggestion_from_response(data) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return ""
	
	# Ollama /api/generate
	if data.has("response"):
		return str(data.get("response", ""))
	
	# OpenAI-compatible chat/completions
	if data.has("choices"):
		var choices = data.get("choices")
		if typeof(choices) == TYPE_ARRAY and choices.size() > 0:
			var first = choices[0]
			if typeof(first) == TYPE_DICTIONARY:
				if first.has("message") and typeof(first["message"]) == TYPE_DICTIONARY and first["message"].has("content"):
					return str(first["message"]["content"])
				if first.has("text"):
					return str(first["text"])
	
	# Gemini generateContent
	if data.has("candidates"):
		var candidates = data.get("candidates")
		if typeof(candidates) == TYPE_ARRAY and candidates.size() > 0:
			var c0 = candidates[0]
			if typeof(c0) == TYPE_DICTIONARY and c0.has("content") and typeof(c0["content"]) == TYPE_DICTIONARY:
				var content = c0["content"]
				if content.has("parts") and typeof(content["parts"]) == TYPE_ARRAY and content["parts"].size() > 0:
					var p0 = content["parts"][0]
					if typeof(p0) == TYPE_DICTIONARY and p0.has("text"):
						return str(p0["text"])
	
	return ""


func _sanitize_model_output(text: String) -> String:
	var s := text.strip_edges()
	# Robust code fence cleanup:
	# Many models return ```python / ```json etc. Remove the opening fence line entirely.
	if s.begins_with("```"):
		var nl := s.find("\n")
		if nl >= 0:
			s = s.substr(nl + 1)
		else:
			s = ""
	# Remove any remaining closing/opening fences.
	s = s.replace("```", "")
	
	# Remove prompt echoes that some small models return literally.
	s = _strip_prompt_echo(s)
	
	# Some models return escaped newlines/tabs as plain text.
	# Convert them so completion behaves like real multiline code.
	s = _decode_common_escaped_sequences(s)
	
	# Avoid leading newlines that feel like "jumping"
	while s.begins_with("\n"):
		s = s.trim_prefix("\n")
	if s.strip_edges() == "":
		return ""
	return s


func _decode_common_escaped_sequences(s: String) -> String:
	# Only decode when it looks like escaped formatting and there are no
	# real newlines yet (to reduce false positives in regular strings).
	if s.find("\n") == -1 and (s.find("\\n") >= 0 or s.find("\\t") >= 0):
		s = s.replace("\\n", "\n")
		s = s.replace("\\t", "\t")
	return s


func _strip_prompt_echo(s: String) -> String:
	var markers := [
		"CURRENT_WORD:",
		"CURRENT_WORD",
		"Palabra actual:",
		"PREFIX (antes del cursor):",
		"SUFFIX (después del cursor):",
		"COMPLETA SOLO lo que falta entre PREFIX y SUFFIX",
	]
	
	var cut_idx := -1
	for m in markers:
		var idx := s.find(m)
		if idx >= 0 and (cut_idx == -1 or idx < cut_idx):
			cut_idx = idx
	
	if cut_idx >= 0:
		s = s.left(cut_idx)
	
	# Also remove XML-style markers if they leak.
	s = s.replace("<PREFIX>", "").replace("</PREFIX>", "")
	s = s.replace("<SUFFIX>", "").replace("</SUFFIX>", "")
	return s.strip_edges()


func _get_effective_max_tokens(mode: String) -> int:
	var configured := int(_get_setting(SETTINGS_PREFIX + "max_tokens", 0))
	if configured < 0:
		configured = 0
	if mode == "assistant_comment":
		# For comment-driven generation, avoid truncating useful code blocks.
		return 0
	return configured


func _trim_suggestion_to_fit_context(suggestion: String, suffix_context: String) -> String:
	var s := suggestion
	if s == "":
		return s
	
	# If the model echoed tags, remove them.
	s = s.replace("<PREFIX>", "").replace("</PREFIX>", "")
	s = s.replace("<SUFFIX>", "").replace("</SUFFIX>", "")
	
	# If it repeats part of the suffix, cut before it.
	var suffix := suffix_context.strip_edges()
	if suffix != "":
		var suffix_anchor := suffix
		# Keep anchor small to increase chance of matching.
		if suffix_anchor.length() > 80:
			suffix_anchor = suffix_anchor.substr(0, 80)
		var idx := s.find(suffix_anchor)
		if idx > 0:
			s = s.left(idx)
	
	if _active_prompt_mode != "assistant_comment":
		# Hard cap for regular inline completion only.
		var max_lines := 25
		var parts := s.split("\n")
		if parts.size() > max_lines:
			s = "\n".join(parts.slice(0, max_lines))
	
	return s.strip_edges()


func _ghost_preview_text(insert_text: String) -> String:
	var lines := insert_text.split("\n")
	if lines.size() == 0:
		return ""
	# Prefer first non-empty line (so you see something even if it starts with a newline).
	var noise := {
		"gdscript": true,
	}
	for idx in range(lines.size()):
		var l := lines[idx]
		if l == "":
			continue
		var low := l.strip_edges().to_lower()
		# Skip language markers that slip in after stripping ``` fences.
		if noise.has(low) and idx < lines.size() - 1:
			continue
		# Keep preview short and readable.
		if l.length() > 80:
			return l.substr(0, 80)
		return l
	return ""


func _cancel_inflight_request() -> void:
	_hide_waiting_feedback()
	if http == null:
		return
	if http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		http.cancel_request()
	if _ollama_stream_active:
		_stop_ollama_stream()


func _start_ollama_httpclient_stream(request_id: int, url: String, headers: PackedStringArray, body: String) -> void:
	_stop_ollama_stream()
	
	var parsed := _parse_http_url(url)
	if parsed.is_empty():
		print("[code autocomplete] Invalid Ollama URL: ", url)
		return
	
	_ollama_stream_url = url
	_ollama_stream_host = str(parsed.host)
	_ollama_stream_port = int(parsed.port)
	_ollama_stream_path = str(parsed.path)
	_ollama_stream_headers = headers.duplicate()
	# Some servers are picky; make sure Host exists.
	if not _has_header(_ollama_stream_headers, "Host"):
		_ollama_stream_headers.append("Host: %s:%d" % [_ollama_stream_host, _ollama_stream_port])
	_ollama_stream_body = body
	_ollama_stream_requested = false
	_ollama_stream_response_code = 0
	_ollama_stream_started_ms = Time.get_ticks_msec()
	_ollama_stream_fallback_requested = false
	
	_stream_buffer = ""
	_stream_text = ""
	
	_pending_request_id = request_id
	
	var err := _ollama_stream_client.connect_to_host(_ollama_stream_host, _ollama_stream_port)
	if err != OK:
		print("[code autocomplete] Ollama connect error: ", err)
		return
	
	_show_waiting_feedback(_stream_started_at_caret_line, _stream_started_at_caret_col)
	_ollama_stream_active = true


func _poll_ollama_stream() -> void:
	_ollama_stream_client.poll()
	
	var st := _ollama_stream_client.get_status()
	var elapsed_ms := Time.get_ticks_msec() - _ollama_stream_started_ms
	var stream_timeout_ms: int = _get_effective_stream_timeout_ms()
	
	# Safety: if we don't reach BODY soon, fallback to non-streaming.
	if not _ollama_stream_fallback_requested and elapsed_ms > stream_timeout_ms and st != HTTPClient.STATUS_BODY:
		_ollama_stream_fallback_requested = true
		print("[code autocomplete] Ollama stream timeout (", elapsed_ms, "ms). Falling back to non-streaming.")
		_stop_ollama_stream()
		_fallback_ollama_non_stream()
		return
	
	if st == HTTPClient.STATUS_DISCONNECTED:
		_stop_ollama_stream()
		return
	
	if st == HTTPClient.STATUS_CANT_RESOLVE or st == HTTPClient.STATUS_CANT_CONNECT or st == HTTPClient.STATUS_CONNECTION_ERROR:
		print("[code autocomplete] Ollama stream connection error status: ", st, " after ", elapsed_ms, "ms")
		_stop_ollama_stream()
		_fallback_ollama_non_stream()
		return
	
	if st == HTTPClient.STATUS_CONNECTED and not _ollama_stream_requested:
		_ollama_stream_requested = true
		var err := _ollama_stream_client.request(HTTPClient.METHOD_POST, _ollama_stream_path, _ollama_stream_headers, _ollama_stream_body)
		if err != OK:
			print("[code autocomplete] Ollama request error: ", err)
			_stop_ollama_stream()
			_fallback_ollama_non_stream()
		return
	
	if st == HTTPClient.STATUS_BODY:
		if _ollama_stream_response_code == 0:
			_ollama_stream_response_code = _ollama_stream_client.get_response_code()
		
		var chunk := _ollama_stream_client.read_response_body_chunk()
		if chunk.size() == 0:
			return
		
		_stream_buffer += chunk.get_string_from_utf8()
		var done := _process_ollama_stream_buffer_lines()
		_update_ghost_from_ollama_stream()
		
		if done:
			_finalize_ollama_stream()
			_stop_ollama_stream()
		return


func _process_ollama_stream_buffer_lines() -> bool:
	var lines := _stream_buffer.split("\n")
	if lines.size() <= 1:
		return false
	
	_stream_buffer = lines[lines.size() - 1]
	var done := false
	
	for i in range(0, lines.size() - 1):
		var l := lines[i].strip_edges()
		if l == "":
			continue
		var j := JSON.new()
		if j.parse(l) != OK:
			continue
		var data = j.data
		if typeof(data) != TYPE_DICTIONARY:
			continue
		if data.has("response"):
			_stream_text += str(data.get("response", ""))
		if bool(data.get("done", false)):
			done = true
	
	return done


func _update_ghost_from_ollama_stream() -> void:
	if current_code_edit == null:
		return
	_ensure_ghost_overlay_ready()
	if not is_instance_valid(_ghost_overlay):
		return
	if current_code_edit.get_caret_line() != _stream_started_at_caret_line or current_code_edit.get_caret_column() != _stream_started_at_caret_col:
		return
	
	var now_ms := Time.get_ticks_msec()
	if now_ms - _stream_last_ghost_update_ms < 60:
		return
	_stream_last_ghost_update_ms = now_ms
	
	var s := _sanitize_model_output(_stream_text)
	s = _trim_suggestion_to_fit_context(s, _active_suffix_context)
	s = _normalize_completion_spacing(s)
	# Hard cap to avoid massive allocations / editor stutter.
	if s.length() > 4000:
		s = s.substr(0, 4000)
	if s.strip_edges() != "":
		_hide_waiting_feedback()
	_ghost_insert_text = s
	_ghost_overlay.set_ghost(s, _stream_started_at_caret_line, _stream_started_at_caret_col)


func _finalize_ollama_stream() -> void:
	var elapsed := Time.get_ticks_msec() - _ollama_stream_started_ms
	_hide_waiting_feedback()
	var s := _sanitize_model_output(_stream_text)
	s = _trim_suggestion_to_fit_context(s, _active_suffix_context)
	if _is_suggestion_aligned(_active_request_word, s):
		ai_sugestion = s	
	else:
		print("[code autocomplete] stream suggestion discarded: does not match current word '", _active_request_word, "'")
		ai_sugestion = ""
		_retry_after_discard_if_possible()
	print("[code autocomplete] Ollama stream done in ", elapsed, "ms")
	if ai_sugestion != "":
		_show_ai_completion(last_word, ai_sugestion)
	else:
		_try_apply_local_fallback_if_possible()


func _get_effective_stream_timeout_ms() -> int:
	var configured := int(_get_setting(SETTINGS_PREFIX + "request/stream_timeout_ms", 25000))
	if configured < 1000:
		configured = 1000
	if _active_prompt_mode == "assistant_comment":
		return max(configured, 90000)
	return configured


func _stop_ollama_stream() -> void:
	_ollama_stream_active = false
	_ollama_stream_requested = false
	if _ollama_stream_client.get_status() != HTTPClient.STATUS_DISCONNECTED:
		_ollama_stream_client.close()


func _parse_http_url(url: String) -> Dictionary:
	var u := url.strip_edges()
	if not u.begins_with("http://"):
		return {}
	u = u.trim_prefix("http://")
	
	var host_port := u
	var path := "/"
	if u.contains("/"):
		host_port = u.get_slice("/", 0)
		path = u.substr(host_port.length())
		if path == "":
			path = "/"
	
	var host := host_port
	var port := 80
	if host_port.contains(":"):
		host = host_port.get_slice(":", 0)
		port = int(host_port.get_slice(":", 1))
	
	return {"host": host, "port": port, "path": path}


func _fallback_ollama_non_stream() -> void:
	# Re-run the same Ollama request using HTTPRequest with stream=false
	# so we always get a single JSON response.
	if _ollama_stream_url == "":
		return
	
	if http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		http.cancel_request()
	
	_pending_request_id += 1
	http.set_meta("request_id", _pending_request_id)
	http.set_meta("provider_id", int(LLMProvider.OLLAMA_GENERATE))
	http.set_meta("streaming", false)
	
	var body := _force_ollama_body_non_stream(_ollama_stream_body)
	var err := http.request(_ollama_stream_url, _ollama_stream_headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		print("[code autocomplete] Ollama non-stream fallback request error: ", err)


func _force_ollama_body_non_stream(body: String) -> String:
	var j := JSON.new()
	if j.parse(body) != OK:
		return body
	if typeof(j.data) != TYPE_DICTIONARY:
		return body
	var d: Dictionary = j.data
	d["stream"] = false
	return JSON.stringify(d)


func _has_header(headers: PackedStringArray, key: String) -> bool:
	var lk := key.to_lower()
	for h in headers:
		var s := String(h)
		var idx := s.find(":")
		if idx <= 0:
			continue
		var k := s.left(idx).strip_edges().to_lower()
		if k == lk:
			return true
	return false


func _is_suggestion_aligned(current_word: String, suggestion: String) -> bool:
	if _active_prompt_mode == "assistant_comment":
		var clean := _sanitize_model_output(suggestion)
		return clean.strip_edges() != ""
	var w := current_word.strip_edges().to_lower()
	var sug_low := suggestion.to_lower()
	if sug_low.find("current_word") >= 0 or sug_low.find("prefix (antes del cursor)") >= 0 or sug_low.find("suffix (después del cursor)") >= 0:
		return false
	if w.length() < 2:
		return _is_suggestion_contextually_valid(_active_line_prefix, current_word, suggestion)
	
	if _is_trivial_echo(w, suggestion):
		return false
	
	var s := suggestion
	# left trim only
	while s.begins_with(" ") or s.begins_with("\t") or s.begins_with("\n") or s.begins_with("\r"):
		s = s.substr(1)
	if s == "":
		return false
	
	var sl := s.to_lower()
	if sl.begins_with(w):
		return _is_suggestion_contextually_valid(_active_line_prefix, current_word, suggestion)
	
	# Allow direct continuation after typed keyword, e.g. " i in ..."
	var c := s[0]
	if c == " " or c == "\t" or c == "(" or c == "[" or c == "." or c == ":":
		return _is_suggestion_contextually_valid(_active_line_prefix, current_word, suggestion)
	
	return false


func _is_suggestion_contextually_valid(line_prefix: String, current_word: String, suggestion: String) -> bool:
	if _is_comment_assistant_line(line_prefix):
		return suggestion.strip_edges() != ""
	var lp := line_prefix.strip_edges().to_lower()
	var cw := current_word.strip_edges().to_lower()
	var ss := suggestion.strip_edges().to_lower()
	var trimmed_left := suggestion
	while trimmed_left.begins_with(" ") or trimmed_left.begins_with("\t"):
		trimmed_left = trimmed_left.substr(1)
	
	# Statement guard: if current line is not a header start, reject declaration-style jumps.
	if not lp.begins_with("for ") and not lp.begins_with("if ") and not lp.begins_with("while ") and not lp.begins_with("match ") and not lp.begins_with("func "):
		if ss.begins_with("func ") or ss.begins_with("class_name ") or ss.begins_with("extends "):
			return false
	
	# Special guard: incomplete `for` header should not receive assignment-like continuations.
	# Example rejected: `for i in index += 1`
	if lp.begins_with("for ") and not lp.contains(":"):
		if cw == "for":
			# While typing `for`, ensure completion moves toward a for-header.
			if not ss.contains(" in ") and not ss.begins_with(" "):
				return false
		
		if lp.contains(" in "):
			if ss.begins_with("+=") or ss.begins_with("-=") or ss.begins_with("*=") or ss.begins_with("/=") or ss.begins_with("%="):
				return false
			if ss.begins_with("="):
				return false
			# After iterable is already present, prefer closing with ':'
			# (allow `:` or `:\n...` or whitespace+`:`).
			if not trimmed_left.begins_with(":"):
				return false
	
	# Incomplete `if` header: avoid assignment-like continuations.
	if lp.begins_with("if ") and not lp.contains(":"):
		if ss.begins_with("+=") or ss.begins_with("-=") or ss.begins_with("*=") or ss.begins_with("/=") or ss.begins_with("%="):
			return false
		if ss.begins_with("="):
			return false
		# If condition is already reasonably present, prefer closing with ':'
		if lp.length() >= 5 and not trimmed_left.begins_with(":") and not trimmed_left.begins_with(" and ") and not trimmed_left.begins_with(" or "):
			# allow operator/compare continuation too
			if not trimmed_left.begins_with("==") and not trimmed_left.begins_with("!=") and not trimmed_left.begins_with(">") and not trimmed_left.begins_with("<"):
				return false
	
	# Incomplete `while` header: same constraints as if.
	if lp.begins_with("while ") and not lp.contains(":"):
		if ss.begins_with("+=") or ss.begins_with("-=") or ss.begins_with("*=") or ss.begins_with("/=") or ss.begins_with("%="):
			return false
		if ss.begins_with("="):
			return false
		if lp.length() >= 8 and not trimmed_left.begins_with(":") and not trimmed_left.begins_with(" and ") and not trimmed_left.begins_with(" or "):
			if not trimmed_left.begins_with("==") and not trimmed_left.begins_with("!=") and not trimmed_left.begins_with(">") and not trimmed_left.begins_with("<"):
				return false
	
	# Incomplete `match` header: once expression exists, prefer ':' (or continuation while typing expression).
	if lp.begins_with("match ") and not lp.contains(":"):
		if ss.begins_with("+=") or ss.begins_with("-=") or ss.begins_with("*=") or ss.begins_with("/=") or ss.begins_with("%=") or ss.begins_with("="):
			return false
		if lp.length() >= 8 and not trimmed_left.begins_with(":") and not trimmed_left.begins_with(" "):
			return false
	
	# Incomplete `func` header:
	# - before '(' => only identifier-ish continuation
	# - after ')' and before ':' => prefer ':'
	if lp.begins_with("func ") and not lp.contains(":"):
		if ss.begins_with("+=") or ss.begins_with("-=") or ss.begins_with("*=") or ss.begins_with("/=") or ss.begins_with("%=") or ss.begins_with("="):
			return false
		if not lp.contains("("):
			# Accept only function-name continuation signals.
			if not ss.begins_with("(") and not ss.begins_with("_") and not ss.begins_with(" "):
				return false
		elif lp.contains(")") and not trimmed_left.begins_with(":"):
			# Signature seems done; next meaningful token should be ':'
			return false
	
	return true


func _is_trivial_echo(current_word_lower: String, suggestion: String) -> bool:
	var s := suggestion.strip_edges().to_lower()
	if s == "":
		return true
	
	# exact echo: "for" -> "for"
	if s == current_word_lower:
		return true
	
	# echo with trailing punctuation only, still not useful: "for:", "for;"
	if s.begins_with(current_word_lower):
		var tail := s.substr(current_word_lower.length()).strip_edges()
		if tail == "" or tail == ":" or tail == ";" or tail == ",":
			return true
	
	return false


func _retry_after_discard_if_possible() -> void:
	# Single retry with stricter prompt to avoid trivial echoes like "for".
	if _active_request_retry_count > 0:
		_try_apply_local_fallback_if_possible()
		return
	if _active_request_word.strip_edges().length() < 2:
		return
	if current_code_edit == null:
		return
	
	# Only retry if user is still typing the same token.
	var now_word := _get_current_word()
	if now_word != _active_request_word:
		return
	
	print("[code autocomplete] retrying with strict prompt for word: ", _active_request_word)
	_request_ai_completion(_active_request_word, 1)


func _try_apply_local_fallback_if_possible() -> bool:
	if current_code_edit == null:
		return false
	var now_word := _get_current_word()
	if now_word != _active_request_word:
		return false
	
	var local_suggestion := _build_local_structural_fallback(_active_line_prefix, _active_request_word)
	if local_suggestion.strip_edges() == "":
		return false
	
	print("[code autocomplete] local fallback suggestion: ", local_suggestion)
	_show_ai_completion(_active_request_word, local_suggestion)
	return true


func _try_show_structural_hint_now() -> bool:
	if current_code_edit == null:
		return false
	
	var line: int = current_code_edit.get_caret_line()
	var col: int = current_code_edit.get_caret_column()
	var line_text := current_code_edit.get_line(line)
	var prefix := line_text.left(col)
	var suffix := ""
	if col < line_text.length():
		suffix = line_text.right(line_text.length() - col)
	
	var current_word := _get_current_word()
	var hint := _build_local_structural_fallback(prefix, current_word, suffix)
	if hint.strip_edges() == "":
		return false
	
	_show_ai_completion(current_word, hint)
	return true


func _build_local_structural_fallback(line_prefix: String, current_word: String, suffix_context: String = "") -> String:
	var lp := line_prefix.strip_edges().to_lower()
	var cw := current_word.strip_edges().to_lower()
	var suffix_left := suffix_context if suffix_context != "" else _active_suffix_context
	while suffix_left.begins_with(" ") or suffix_left.begins_with("\t"):
		suffix_left = suffix_left.substr(1)
	
	# for ... in ... <iterable>  => suggest closing colon
	if lp.begins_with("for ") and lp.contains(" in ") and not lp.contains(":"):
		if not lp.ends_with(" in") and not lp.ends_with(" in "):
			var paren_balance := _paren_balance(lp)
			if paren_balance > 0:
				# If editor already auto-added ')', don't inject ':' before it.
				if suffix_left.begins_with(")"):
					return ""
				return ")"
			return ":"
	
	# if / while / match with expression but missing ':'
	if lp.begins_with("if ") and not lp.contains(":"):
		if lp.length() > 3:
			return ":"
	# While typing bare keyword, provide a useful non-empty continuation.
	if cw == "if" and lp == "if":
		return " true:"
	if lp.begins_with("while ") and not lp.contains(":"):
		if lp.length() > 6:
			return ":"
	# While typing bare keyword, provide a useful non-empty continuation.
	if cw == "while" and lp == "while":
		return " true:"
	if lp.begins_with("match ") and not lp.contains(":"):
		if lp.length() > 6:
			return ":"
	if cw == "match" and lp == "match":
		return " value:"
	
	# Bare "for" keyword helper.
	if cw == "for" and lp == "for":
		return " i in range(1):"
	
	# func signature completed => close with colon
	if lp.begins_with("func ") and lp.contains(")") and not lp.contains(":"):
		return ":"
	
	# Small helper while typing "for" header: if user is on "in", suggest space.
	if lp.begins_with("for ") and cw == "in" and not lp.contains(" in "):
		return " "
	
	# Common API helper: get_node
	if cw == "get_node":
		if suffix_left.begins_with("("):
			return ""
		return "(\""
	
	return ""


func _paren_balance(text: String) -> int:
	var balance := 0
	for i in range(text.length()):
		var c := text[i]
		if c == "(":
			balance += 1
		elif c == ")":
			balance -= 1
	return balance
