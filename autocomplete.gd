@tool
extends EditorPlugin

const PromptMaker = preload("res://addons/code_autocomplete/prompt_maker.gd")
const ProviderRequestBuilder = preload("res://addons/code_autocomplete/provider_request_builder.gd")
const ProviderResponseParser = preload("res://addons/code_autocomplete/provider_response_parser.gd")
const HttpRequestClient = preload("res://addons/code_autocomplete/http_request_client.gd")

var script_editor
var current_code_edit: CodeEdit
var debounce_timer:Timer
var debounce_spin_value:float = 0.2
var last_word : String= ""
var ai_sugestion : String = ""
var _http_client

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
var _stream_started_at_caret_line: int = 0
var _stream_started_at_caret_col: int = 0

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
	
	script_editor = get_editor_interface().get_script_editor()
	script_editor.connect("editor_script_changed",Callable(self,"_on_script_changed"))
	
	debounce_timer = Timer.new()
	debounce_timer.wait_time = float(_get_setting(SETTINGS_PREFIX + "request/debounce_sec", debounce_spin_value))
	debounce_timer.one_shot = true
	debounce_timer.connect("timeout", Callable(self, "_on_debounce_timeout"))
	add_child(debounce_timer)
	
	_http_client = HttpRequestClient.new()
	add_child(_http_client)
	_http_client.request_completed.connect(_on_transport_request_completed)
	_http_client.stream_progress.connect(_on_transport_stream_progress)
	_http_client.stream_completed.connect(_on_transport_stream_completed)
	_http_client.request_failed.connect(_on_transport_request_failed)
	
	print("[code autocomplete] plugin loaded")

func _exit_tree() -> void:
	# Clean-up of the plugin goes here.
	if is_instance_valid(config_dock):
		remove_control_from_docks(config_dock)
		config_dock.queue_free()
		config_dock = null
	if is_instance_valid(_ghost_overlay):
		_ghost_overlay.queue_free()
		_ghost_overlay = null
	if is_instance_valid(_http_client):
		_http_client.queue_free()
		_http_client = null
	pass


func _process(_delta: float) -> void:
	pass

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
	if PromptMaker.is_comment_assistant_line(_get_current_line_prefix()):
		_request_ai_completion(last_word, 0)
		return
	# If no strong token, still allow local structural hints (e.g. suggest ":" after `for ... )`).
	if last_word == "" or last_word.length() <= 1:
		_try_show_structural_hint_now()
		return
	
	_request_ai_completion(last_word, 0)


func _request_ai_completion(word:String, retry_count: int = 0):
	if current_code_edit == null or _http_client == null:
		return
	var line: int = current_code_edit.get_caret_line()
	var column: int = current_code_edit.get_caret_column()
	var current_line_text := current_code_edit.get_line(line)
	_active_line_prefix = current_line_text.left(column)
	var mode := PromptMaker.detect_prompt_mode(_active_line_prefix, word)
	_active_prompt_mode = mode
	_active_comment_action = "insert"
	_active_comment_target = {}
	_active_comment_insert_target = {}
	if mode == "assistant_comment":
		_active_comment_insert_target = {
			"line": line,
			"col": column,
		}
		_active_comment_action = PromptMaker.detect_comment_assistant_action(PromptMaker.extract_comment_assistant_instruction(_active_line_prefix))
		if _active_comment_action == "edit_existing":
			_active_comment_target = _resolve_comment_assistant_target(line)
			if _active_comment_target.is_empty():
				_active_comment_action = "insert"
	if mode != "assistant_comment" and word.length() < 2:
		return
	
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
	ai_sugestion = ""
	var req: Dictionary = _build_llm_request(prefix_context, suffix_context, word, retry_count > 0)
	if req.is_empty():
		return
	
	_pending_request_id += 1
	_stream_started_at_caret_line = line
	_stream_started_at_caret_col = column
	
	var error = _http_client.request(_pending_request_id, req, _get_effective_stream_timeout_ms())
	if error == OK:
		_show_waiting_feedback(line, column)
	else:
		_hide_waiting_feedback()
	

func _on_transport_request_completed(request_id: int, result, response_code: int, headers, body) -> void:
	if request_id != _pending_request_id:
		return
	_on_ai_response(result, response_code, headers, body)


func _on_transport_stream_progress(request_id: int, stream_text: String) -> void:
	if request_id != _pending_request_id:
		return
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
	
	var suggestion := _sanitize_model_output(stream_text)
	suggestion = _trim_suggestion_to_fit_context(suggestion, _active_suffix_context)
	suggestion = _normalize_completion_spacing(suggestion)
	if suggestion.length() > 4000:
		suggestion = suggestion.substr(0, 4000)
	if suggestion.strip_edges() != "":
		_hide_waiting_feedback()
	_ghost_insert_text = suggestion
	_ghost_overlay.set_ghost(suggestion, _stream_started_at_caret_line, _stream_started_at_caret_col)


func _on_transport_stream_completed(request_id: int, response_code: int, stream_text: String) -> void:
	if request_id != _pending_request_id:
		return
	_hide_waiting_feedback()
	ai_sugestion = ""
	var suggestion := _sanitize_model_output(stream_text)
	suggestion = _trim_suggestion_to_fit_context(suggestion, _active_suffix_context)
	if _is_suggestion_aligned(_active_request_word, suggestion):
		ai_sugestion = suggestion
	else:
		print("[code autocomplete] stream suggestion discarded: does not match current word '", _active_request_word, "'")
		ai_sugestion = ""
		_retry_after_discard_if_possible()
	if ai_sugestion != "":
		_show_ai_completion(last_word, ai_sugestion)
	else:
		_try_apply_local_fallback_if_possible()


func _on_transport_request_failed(request_id: int, message: String, response_code: int, body: String) -> void:
	if request_id != _pending_request_id:
		return
	_hide_waiting_feedback()
	if response_code != 0:
		push_warning("[code autocomplete] API Error: ", response_code, " body: ", body)
	else:
		push_warning("[code autocomplete] ", message)
	_try_apply_local_fallback_if_possible()


func _on_ai_response(result, response_code,headers,body) -> void:
	_hide_waiting_feedback()
	ai_sugestion = ""
	if response_code != 200:
		var raw: String = body.get_string_from_utf8()
		push_warning("[code autocomplete] API Error: ", response_code, " body: ", raw)
		return
	#print("[code autocomplete] response_code: ", response_code)
	
	var json = JSON.new()
	var parse_result = json.parse(body.get_string_from_utf8())
	if parse_result != OK:
		#handle error
		push_warning("[code autocomplete] JSON parse error: ", parse_result, " body: ", body.get_string_from_utf8().substr(0, 500))
	
	if parse_result == OK:
		var data = json.data
		var suggestion: String = ""
		suggestion = _extract_suggestion_from_response(data)
		if suggestion.strip_edges() != "":
			suggestion = _sanitize_model_output(suggestion)
			suggestion = _trim_suggestion_to_fit_context(suggestion, _active_suffix_context)
			ai_sugestion = suggestion

	
	if ai_sugestion != "":
		_show_ai_completion(last_word,ai_sugestion)
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
	title.text = "Code Autocomplete and AI assistant (LLM)"
	root.add_child(title)
	
	var provider_row := HBoxContainer.new()
	var provider_label := Label.new()
	provider_label.text = "Provider"
	provider_label.custom_minimum_size.x = 90
	provider_row.add_child(provider_label)
	
	var provider_opt := OptionButton.new()
	provider_opt.add_item("Ollama (local, free)", int(LLMProvider.OLLAMA_GENERATE))
	provider_opt.add_item("OpenAI-compatible (Chat)", int(LLMProvider.OPENAI_COMPATIBLE_CHAT))
	provider_opt.add_item("Gemini (Google AI)", int(LLMProvider.GEMINI_GENERATE_CONTENT))
	provider_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	provider_row.add_child(provider_opt)
	root.add_child(provider_row)
	
	var temp_row := HBoxContainer.new()
	var temp_label := Label.new()
	temp_label.text = "Temperature"
	temp_label.tooltip_text = "0.0 = most creative, 1.0 = most conservative"
	temp_label.custom_minimum_size.x = 90
	temp_row.add_child(temp_label)
	var temp_spin := SpinBox.new()
	temp_spin.min_value = 0.0
	temp_spin.max_value = 2.0
	temp_spin.step = 0.05
	temp_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	temp_spin.tooltip_text = "0.0 = most creative, 1.0 = most conservative"
	temp_row.add_child(temp_spin)
	root.add_child(temp_row)
	
	var tokens_row := HBoxContainer.new()
	var tokens_label := Label.new()
	tokens_label.text = "Max tokens"
	tokens_label.tooltip_text = "0 = no artificial limit from the plugin"
	tokens_label.custom_minimum_size.x = 90
	tokens_row.add_child(tokens_label)

	var tokens_spin := SpinBox.new()
	tokens_spin.min_value = 0
	tokens_spin.max_value = 8192
	tokens_spin.step = 16
	tokens_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tokens_spin.tooltip_text = "0 = no artificial limit from the plugin"
	tokens_row.add_child(tokens_spin)
	root.add_child(tokens_row)
	
	var prefix_row := HBoxContainer.new()
	var prefix_label := Label.new()
	prefix_label.text = "Prefix lines"
	prefix_label.tooltip_text = "How many lines to include before the current line in the context"
	prefix_label.custom_minimum_size.x = 90
	prefix_row.add_child(prefix_label)
	var prefix_spin := SpinBox.new()
	prefix_spin.min_value = 5
	prefix_spin.max_value = 200
	prefix_spin.step = 1
	prefix_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prefix_spin.tooltip_text = "How many lines to include before the current line in the context"
	prefix_row.add_child(prefix_spin)
	root.add_child(prefix_row)
	
	var suffix_row := HBoxContainer.new()
	var suffix_label := Label.new()
	suffix_label.text = "Suffix lines"
	suffix_label.tooltip_text = "How many lines to include after the current line in the context"
	suffix_label.custom_minimum_size.x = 90
	suffix_row.add_child(suffix_label)
	var suffix_spin := SpinBox.new()
	suffix_spin.min_value = 0
	suffix_spin.max_value = 100
	suffix_spin.step = 1
	suffix_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	suffix_spin.tooltip_text = "How many lines to include after the current line in the context"
	suffix_row.add_child(suffix_spin)
	root.add_child(suffix_row)

	var godot_ctx_row := HBoxContainer.new()
	var godot_ctx_label := Label.new()
	godot_ctx_label.text = "Godot strict"
	godot_ctx_label.tooltip_text = "Injects only real Godot APIs detected from ClassDB"
	godot_ctx_label.custom_minimum_size.x = 90
	godot_ctx_row.add_child(godot_ctx_label)
	var godot_ctx_check := CheckBox.new()
	godot_ctx_check.text = "Enabled"
	godot_ctx_check.tooltip_text = "Injects only real Godot APIs detected from ClassDB"
	godot_ctx_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	godot_ctx_row.add_child(godot_ctx_check)
	root.add_child(godot_ctx_row)
	
	var stream_row := HBoxContainer.new()
	var stream_label := Label.new()
	stream_label.text = "Streaming"
	stream_label.custom_minimum_size.x = 90
	stream_row.add_child(stream_label)
	var stream_check := CheckBox.new()
	stream_check.text = "Enabled"
	stream_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stream_row.add_child(stream_check)
	root.add_child(stream_row)
	
	var debounce_row := HBoxContainer.new()
	var debounce_label := Label.new()
	debounce_label.text = "Debounce (s)"
	debounce_label.tooltip_text = "How long to wait before sending the request again"
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
	stream_timeout_label.tooltip_text = "How long to wait before the stream times out"
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
	ghost_lines_label.text = "Ghost Lines"
	ghost_lines_label.tooltip_text = "0 = show all the suggested block"
	ghost_lines_label.custom_minimum_size.x = 90
	ghost_lines_row.add_child(ghost_lines_label)

	var ghost_lines_spin := SpinBox.new()
	ghost_lines_spin.min_value = 0
	ghost_lines_spin.max_value = 200
	ghost_lines_spin.step = 1
	ghost_lines_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ghost_lines_spin.tooltip_text = "0 = show all the suggested block"
	ghost_lines_row.add_child(ghost_lines_spin)
	root.add_child(ghost_lines_row)

	var godot_classes_row := HBoxContainer.new()
	var godot_classes_label := Label.new()
	godot_classes_label.text = "Godot classes"
	godot_classes_label.tooltip_text = "How many Godot classes to include in the context"
	godot_classes_label.custom_minimum_size.x = 90
	godot_classes_row.add_child(godot_classes_label)
	var godot_classes_spin := SpinBox.new()
	godot_classes_spin.min_value = 1
	godot_classes_spin.max_value = 8
	godot_classes_spin.step = 1
	godot_classes_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	godot_classes_spin.tooltip_text = "How many Godot classes to include in the context"
	godot_classes_row.add_child(godot_classes_spin)
	root.add_child(godot_classes_row)

	var godot_members_row := HBoxContainer.new()
	var godot_members_label := Label.new()
	godot_members_label.text = "Godot members"
	godot_members_label.tooltip_text = "How many methods/properties/signals to list per class"
	godot_members_label.custom_minimum_size.x = 90
	godot_members_row.add_child(godot_members_label)
	var godot_members_spin := SpinBox.new()
	godot_members_spin.min_value = 4
	godot_members_spin.max_value = 30
	godot_members_spin.step = 1
	godot_members_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	godot_members_spin.tooltip_text = "How many methods/properties/signals to list per class"
	godot_members_row.add_child(godot_members_spin)
	root.add_child(godot_members_row)
	
	var sep1 := HSeparator.new()
	root.add_child(sep1)
	
	var ollama_title := Label.new()
	ollama_title.text = "Ollama"
	root.add_child(ollama_title)
	
	var ollama_url := _make_labeled_line_edit("URL", 90)
	root.add_child(ollama_url.row)
	
	var ollama_model := _make_labeled_line_edit("Model", 90)
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
	openai_key.edit.placeholder_text = "optional (depends on the provider)"
	root.add_child(openai_key.row)
	
	var sep3 := HSeparator.new()
	root.add_child(sep3)
	
	var gemini_title := Label.new()
	gemini_title.text = "Gemini (native API)"
	root.add_child(gemini_title)
	
	var gemini_url_base := _make_labeled_line_edit("URL base", 90)
	gemini_url_base.edit.placeholder_text = "https://generativelanguage.googleapis.com/v1beta/models"
	root.add_child(gemini_url_base.row)
	
	var gemini_model := _make_labeled_line_edit("Model", 90)
	gemini_model.edit.placeholder_text = "gemini-1.5-flash"
	root.add_child(gemini_model.row)
	
	var gemini_key := _make_labeled_line_edit("API key", 90)
	gemini_key.edit.secret = true
	gemini_key.edit.placeholder_text = "Google AI Studio API key"
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
	var mode := PromptMaker.detect_prompt_mode(_active_line_prefix, current_word)
	var max_tokens: int = _get_effective_max_tokens(mode)
	var godot_reference := _build_godot_reference_context(prefix_context, suffix_context, current_word)
	var instruction := PromptMaker.build_prompt_instruction(mode, strict_mode, godot_reference != "", _active_comment_action)
	var prompt_text := PromptMaker.build_prompt_text({
		"mode": mode,
		"instruction": instruction,
		"current_word": current_word,
		"prefix_context": prefix_context,
		"suffix_context": suffix_context,
		"godot_reference": godot_reference,
		"line_prefix": _active_line_prefix,
		"comment_action": _active_comment_action,
		"comment_target_text": str(_active_comment_target.get("text", "")),
	})
	print("[code autocomplete] prompt mode: ", mode)
	return ProviderRequestBuilder.build_request({
		"provider_id": provider_id,
		"temperature": temperature,
		"streaming_enabled": streaming_enabled,
		"extra_headers_raw": str(_get_setting(SETTINGS_PREFIX + "extra_headers", "")),
		"prompt_text": prompt_text,
		"instruction": instruction,
		"prefix_context": prefix_context,
		"suffix_context": suffix_context,
		"max_tokens": max_tokens,
		"ollama_url": str(_get_setting(SETTINGS_PREFIX + "ollama/url", "http://localhost:11434/api/generate")),
		"ollama_model": str(_get_setting(SETTINGS_PREFIX + "ollama/model", "qwen2.5-coder:1.5b")),
		"openai_url": str(_get_setting(SETTINGS_PREFIX + "openai/url", "https://api.openai.com/v1/chat/completions")),
		"openai_model": str(_get_setting(SETTINGS_PREFIX + "openai/model", "gpt-4o-mini")),
		"openai_api_key": str(_get_setting(SETTINGS_PREFIX + "openai/api_key", "")),
		"gemini_url_base": str(_get_setting(SETTINGS_PREFIX + "gemini/url_base", "https://generativelanguage.googleapis.com/v1beta/models")),
		"gemini_model": str(_get_setting(SETTINGS_PREFIX + "gemini/model", "gemini-1.5-flash")),
		"gemini_api_key": str(_get_setting(SETTINGS_PREFIX + "gemini/api_key", "")),
	})


func _detect_prompt_mode(line_prefix: String, current_word: String) -> String:
	return PromptMaker.detect_prompt_mode(line_prefix, current_word)


func _build_prompt_instruction(mode: String, strict_mode: bool, has_godot_reference: bool) -> String:
	return PromptMaker.build_prompt_instruction(mode, strict_mode, has_godot_reference, _active_comment_action)


func _build_prompt_text(mode: String, instruction: String, current_word: String, prefix_context: String, suffix_context: String, godot_reference: String) -> String:
	return PromptMaker.build_prompt_text({
		"mode": mode,
		"instruction": instruction,
		"current_word": current_word,
		"prefix_context": prefix_context,
		"suffix_context": suffix_context,
		"godot_reference": godot_reference,
		"line_prefix": _active_line_prefix,
		"comment_action": _active_comment_action,
		"comment_target_text": str(_active_comment_target.get("text", "")),
	})


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
	return PromptMaker.is_comment_assistant_line(line_prefix)


func _extract_comment_assistant_instruction(line_prefix: String) -> String:
	return PromptMaker.extract_comment_assistant_instruction(line_prefix)


func _detect_comment_assistant_action(instruction: String) -> String:
	return PromptMaker.detect_comment_assistant_action(instruction)


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
	return ProviderRequestBuilder.parse_extra_headers(raw)


func _extract_suggestion_from_response(data) -> String:
	return ProviderResponseParser.extract_suggestion_from_response(data)


func _sanitize_model_output(text: String) -> String:
	return ProviderResponseParser.sanitize_model_output(text)


func _decode_common_escaped_sequences(s: String) -> String:
	return ProviderResponseParser.decode_common_escaped_sequences(s)


func _strip_prompt_echo(s: String) -> String:
	return ProviderResponseParser.strip_prompt_echo(s)


func _get_effective_max_tokens(mode: String) -> int:
	var configured := int(_get_setting(SETTINGS_PREFIX + "max_tokens", 0))
	if configured < 0:
		configured = 0
	if mode == "assistant_comment":
		# For comment-driven generation, avoid truncating useful code blocks.
		return 0
	return configured


func _trim_suggestion_to_fit_context(suggestion: String, suffix_context: String) -> String:
	return ProviderResponseParser.trim_suggestion_to_fit_context(suggestion, suffix_context, _active_prompt_mode)


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
	if _http_client == null:
		return
	_http_client.cancel_inflight_request()


func _get_effective_stream_timeout_ms() -> int:
	var configured := int(_get_setting(SETTINGS_PREFIX + "request/stream_timeout_ms", 25000))
	if configured < 1000:
		configured = 1000
	if _active_prompt_mode == "assistant_comment":
		return max(configured, 90000)
	return configured


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
