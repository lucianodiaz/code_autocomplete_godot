@tool
extends RefCounted


static func detect_prompt_mode(line_prefix: String, current_word: String) -> String:
	var lp := line_prefix.strip_edges().to_lower()
	var cw := current_word.strip_edges().to_lower()
	var header_keywords := ["for", "if", "while", "match", "func"]
	if is_comment_assistant_line(line_prefix):
		return "assistant_comment"
	
	for kw in header_keywords:
		if lp.begins_with(kw + " "):
			return "header"
		if lp == kw:
			return "header"
		if cw == kw:
			return "header"
	
	return "statement"


static func build_prompt_instruction(mode: String, strict_mode: bool, has_godot_reference: bool, comment_action: String = "insert") -> String:
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
		if comment_action == "edit_existing":
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


static func build_prompt_text(config: Dictionary) -> String:
	var mode := str(config.get("mode", "statement"))
	var instruction := str(config.get("instruction", ""))
	var current_word := str(config.get("current_word", ""))
	var prefix_context := str(config.get("prefix_context", ""))
	var suffix_context := str(config.get("suffix_context", ""))
	var godot_reference := str(config.get("godot_reference", ""))
	var line_prefix := str(config.get("line_prefix", ""))
	var comment_action := str(config.get("comment_action", "insert"))
	var comment_target_text := str(config.get("comment_target_text", ""))
	
	var example_block := ""
	var godot_block := ""
	if godot_reference != "":
		godot_block = "Referencia Godot verificada:\n" + godot_reference + "\n\n"
	if mode == "assistant_comment":
		var user_instruction := extract_comment_assistant_instruction(line_prefix)
		example_block = "Ejemplo:\n" + \
			"- instrucción: \"Haz una función que reciba un nodo y devuelva su primer hijo\"\n" + \
			"- salida válida: \"func get_first_child(node: Node) -> Node:\\n\\tif node == null or node.get_child_count() == 0:\\n\\t\\treturn null\\n\\treturn node.get_child(0)\"\n"
		var target_block := ""
		if comment_action == "edit_existing" and comment_target_text != "":
			target_block = "Bloque objetivo a reemplazar:\n" + comment_target_text + "\n\n"
		return instruction + "\n" + example_block + "\n" + godot_block + \
			"Instrucción del comentario:\n" + user_instruction + "\n\n" + \
			target_block + \
			"Contexto antes del cursor:\n" + prefix_context + "\n\n" + \
			"Contexto después del cursor:\n" + suffix_context + "\n\n" + \
			("Responde SOLO con el bloque final que reemplaza el objetivo.\n" if comment_action == "edit_existing" else "Responde SOLO con código GDScript para insertar debajo del comentario.\n")
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


static func is_comment_assistant_line(line_prefix: String) -> bool:
	var instruction := extract_comment_assistant_instruction(line_prefix).to_lower()
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


static func extract_comment_assistant_instruction(line_prefix: String) -> String:
	var stripped := line_prefix.strip_edges()
	if not stripped.begins_with("#"):
		return ""
	return stripped.trim_prefix("#").strip_edges()


static func detect_comment_assistant_action(instruction: String) -> String:
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
