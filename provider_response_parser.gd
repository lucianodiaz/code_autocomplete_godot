@tool
extends RefCounted


static func extract_suggestion_from_response(data) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return ""
	
	if data.has("response"):
		return str(data.get("response", ""))
	
	if data.has("choices"):
		var choices = data.get("choices")
		if typeof(choices) == TYPE_ARRAY and choices.size() > 0:
			var first = choices[0]
			if typeof(first) == TYPE_DICTIONARY:
				if first.has("message") and typeof(first["message"]) == TYPE_DICTIONARY and first["message"].has("content"):
					return str(first["message"]["content"])
				if first.has("text"):
					return str(first["text"])
	
	if data.has("candidates"):
		var candidates = data.get("candidates")
		if typeof(candidates) == TYPE_ARRAY and candidates.size() > 0:
			var candidate = candidates[0]
			if typeof(candidate) == TYPE_DICTIONARY and candidate.has("content") and typeof(candidate["content"]) == TYPE_DICTIONARY:
				var content = candidate["content"]
				if content.has("parts") and typeof(content["parts"]) == TYPE_ARRAY and content["parts"].size() > 0:
					var part = content["parts"][0]
					if typeof(part) == TYPE_DICTIONARY and part.has("text"):
						return str(part["text"])
	
	return ""


static func sanitize_model_output(text: String) -> String:
	var out := text.strip_edges()
	if out.begins_with("```"):
		var newline_index := out.find("\n")
		if newline_index >= 0:
			out = out.substr(newline_index + 1)
		else:
			out = ""
	out = out.replace("```", "")
	out = strip_prompt_echo(out)
	out = decode_common_escaped_sequences(out)
	while out.begins_with("\n"):
		out = out.trim_prefix("\n")
	if out.strip_edges() == "":
		return ""
	return out


static func trim_suggestion_to_fit_context(suggestion: String, suffix_context: String, prompt_mode: String) -> String:
	var out := suggestion
	if out == "":
		return out
	
	out = out.replace("<PREFIX>", "").replace("</PREFIX>", "")
	out = out.replace("<SUFFIX>", "").replace("</SUFFIX>", "")
	
	var suffix := suffix_context.strip_edges()
	if suffix != "":
		var suffix_anchor := suffix
		if suffix_anchor.length() > 80:
			suffix_anchor = suffix_anchor.substr(0, 80)
		var match_index := out.find(suffix_anchor)
		if match_index > 0:
			out = out.left(match_index)
	
	if prompt_mode != "assistant_comment":
		var max_lines := 25
		var parts := out.split("\n")
		if parts.size() > max_lines:
			out = "\n".join(parts.slice(0, max_lines))
	
	return out.strip_edges()


static func decode_common_escaped_sequences(text: String) -> String:
	var out := text
	if out.find("\n") == -1 and (out.find("\\n") >= 0 or out.find("\\t") >= 0):
		out = out.replace("\\n", "\n")
		out = out.replace("\\t", "\t")
	return out


static func strip_prompt_echo(text: String) -> String:
	var markers := [
		"CURRENT_WORD:",
		"CURRENT_WORD",
		"Palabra actual:",
		"PREFIX (antes del cursor):",
		"SUFFIX (después del cursor):",
		"COMPLETA SOLO lo que falta entre PREFIX y SUFFIX",
	]
	
	var out := text
	var cut_idx := -1
	for marker in markers:
		var idx := out.find(marker)
		if idx >= 0 and (cut_idx == -1 or idx < cut_idx):
			cut_idx = idx
	
	if cut_idx >= 0:
		out = out.left(cut_idx)
	
	out = out.replace("<PREFIX>", "").replace("</PREFIX>", "")
	out = out.replace("<SUFFIX>", "").replace("</SUFFIX>", "")
	return out.strip_edges()
