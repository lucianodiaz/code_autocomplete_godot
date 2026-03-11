@tool
class_name GhostOverlay
extends Control


var code_edit: CodeEdit
var ghost_text: String = ""
var caret_line: int = 0
var caret_col: int = 0
var ghost_color: Color = Color(0.85, 0.85, 0.85, 0.45)
var waiting_color: Color = Color(0.45, 0.78, 1.0, 0.7)
var max_preview_lines: int = 0
var waiting: bool = false
var _last_caret_rect: Rect2 = Rect2()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS


func set_ghost(text: String, line: int, col: int) -> void:
	waiting = false
	ghost_text = text
	caret_line = line
	caret_col = col
	queue_redraw()


func set_waiting(active: bool, line: int, col: int) -> void:
	waiting = active
	caret_line = line
	caret_col = col
	if not active:
		_last_caret_rect = Rect2()
	queue_redraw()


func clear() -> void:
	waiting = false
	_last_caret_rect = Rect2()
	ghost_text = ""
	queue_redraw()


func _process(_delta: float) -> void:
	if (ghost_text == "" and not waiting) or code_edit == null or not is_instance_valid(code_edit):
		return
	var r := code_edit.get_rect_at_line_column(caret_line, caret_col)
	var rp := Vector2(r.position)
	var rs := Vector2(r.size)
	if rp != _last_caret_rect.position or rs != _last_caret_rect.size:
		_last_caret_rect = Rect2(rp, rs)
		queue_redraw()
	elif waiting:
		queue_redraw()


func _draw() -> void:
	if (ghost_text == "" and not waiting) or code_edit == null or not is_instance_valid(code_edit):
		return

	var caret_rect: Rect2 = code_edit.get_rect_at_line_column(caret_line, caret_col)
	_last_caret_rect = caret_rect
	var font: Font = code_edit.get_theme_font("font")
	var font_size: int = code_edit.get_theme_font_size("font_size")
	if font_size <= 0:
		font_size = 14

	var line_height := font.get_height(font_size)
	if line_height <= 0:
		line_height = font_size + 4

	# Better baseline: align to text baseline of the caret line.
	var base_y := caret_rect.position.y + caret_rect.size.y - font.get_descent(font_size)
	var first_x := caret_rect.position.x
	var line0 := code_edit.get_rect_at_line_column(caret_line, 0)
	var start_x := line0.position.x
	var tab_size := 4
	if code_edit.has_method("get_tab_size"):
		tab_size = int(code_edit.get_tab_size())
	elif code_edit.has_method("get_indent_size"):
		tab_size = int(code_edit.get_indent_size())

	if waiting and ghost_text == "":
		draw_string(font, Vector2(first_x + 16.0, base_y), _waiting_text(), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, waiting_color)
		return

	var lines := ghost_text.split("\n")
	var shown := 0
	for i in range(lines.size()):
		if max_preview_lines > 0 and shown >= max_preview_lines:
			break
		var t := lines[i]
		if t == "":
			shown += 1
			continue
		var x := first_x if i == 0 else start_x
		var y := base_y + (line_height * i)
		if i == 0:
			# Keep first line draw simple/robust at caret.
			draw_string(font, Vector2(x, y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ghost_color)
		else:
			var leading := _leading_ws(t)
			var content := t.substr(leading.length())
			var expanded_leading := _expand_tabs_for_preview(leading, tab_size)
			var leading_w := font.get_string_size(expanded_leading, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			if content != "":
				draw_string(font, Vector2(x + leading_w, y), content, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ghost_color)
		shown += 1


func _leading_ws(text: String) -> String:
	var i := 0
	while i < text.length():
		var c := text[i]
		if c != " " and c != "\t":
			break
		i += 1
	return text.substr(0, i)


func _expand_tabs_for_preview(text: String, tab_size: int) -> String:
	if tab_size <= 0:
		tab_size = 4
	var out := ""
	for i in range(text.length()):
		var c := text[i]
		if c == "\t":
			for j in range(tab_size):
				out += " "
		else:
			out += c
	return out


func _waiting_text() -> String:
	var phase := int(Time.get_ticks_msec() / 250) % 3
	var dots := ""
	for i in range(phase + 1):
		dots += "."
	return "IA" + dots
