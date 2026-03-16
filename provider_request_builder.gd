@tool
extends RefCounted


enum LLMProvider {
	OLLAMA_GENERATE = 0,
	OPENAI_COMPATIBLE_CHAT = 1,
	GEMINI_GENERATE_CONTENT = 2,
}


static func build_request(config: Dictionary) -> Dictionary:
	var provider_id := int(config.get("provider_id", int(LLMProvider.OLLAMA_GENERATE)))
	var temperature := float(config.get("temperature", 0.2))
	var streaming_enabled := bool(config.get("streaming_enabled", true))
	var headers: PackedStringArray = ["Content-Type: application/json"]
	headers.append_array(parse_extra_headers(str(config.get("extra_headers_raw", ""))))
	
	var prompt_text := str(config.get("prompt_text", ""))
	var instruction := str(config.get("instruction", ""))
	var prefix_context := str(config.get("prefix_context", ""))
	var suffix_context := str(config.get("suffix_context", ""))
	var max_tokens := int(config.get("max_tokens", 0))
	
	if provider_id == int(LLMProvider.OLLAMA_GENERATE):
		var url := str(config.get("ollama_url", "http://localhost:11434/api/generate"))
		var model := str(config.get("ollama_model", "qwen2.5-coder:1.5b"))
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
		var url := str(config.get("openai_url", "https://api.openai.com/v1/chat/completions"))
		var model := str(config.get("openai_model", "gpt-4o-mini"))
		var api_key := str(config.get("openai_api_key", "")).strip_edges()
		if api_key != "":
			headers.append("Authorization: Bearer %s" % api_key)
		
		var payload := {
			"model": model,
			"messages": [
				{"role": "system", "content": instruction},
				{"role": "user", "content": "<PREFIX>\n" + prefix_context + "\n</PREFIX>\n<SUFFIX>\n" + suffix_context + "\n</SUFFIX>"},
			],
			"temperature": temperature,
			"stream": false,
		}
		if max_tokens > 0:
			payload["max_tokens"] = max_tokens
		return {"url": url, "headers": headers, "body": JSON.stringify(payload), "stream": false, "provider_id": provider_id}
	
	if provider_id == int(LLMProvider.GEMINI_GENERATE_CONTENT):
		var url_base := str(config.get("gemini_url_base", "https://generativelanguage.googleapis.com/v1beta/models")).strip_edges()
		var model := str(config.get("gemini_model", "gemini-1.5-flash")).strip_edges()
		var api_key := str(config.get("gemini_api_key", "")).strip_edges()
		if api_key == "":
			print("[code autocomplete] Gemini API key is empty. Set it in the dock.")
			return {}
		
		var url := "%s/%s:generateContent" % [url_base.trim_suffix("/"), model]
		headers.append("x-goog-api-key: %s" % api_key)
		
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


static func parse_extra_headers(raw: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for line in raw.split("\n"):
		var header_line := line.strip_edges()
		if header_line == "":
			continue
		if not header_line.contains(":"):
			continue
		out.append(header_line)
	return out
