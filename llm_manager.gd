extends Node

@onready var http_request = $"../HTTPRequest"
@onready var dialogue_label = $"../UI/DialoguePanel/DialogueLabel"
@onready var input_box = $"../UI/InputBox"
@onready var lao_you_sprite = $"../CarInterior/LaoYouSprite"
@onready var ui_stress_bar = $"../UI/StressBar" 
@onready var system_message_label = $"../UI/SystemMessageLabel" # 路径根据实际情况改

# 在文件开头加上音效节点的引用（确保你场景里有这个节点）
@onready var rain_audio = $"../RainAudio" # 你的背景雨声节点
@onready var vignette_rect = $"../UI/VignetteRect" # 你的暗角Shader节点

const API_URL = "https://api.siliconflow.cn/v1/chat/completions"
#const API_URL = "http://127.0.0.1:8000/v1/chat/completions"

# ================= 新增：外部线形记忆本 =================
# ================= 路径配置 =================
const EVENTS_CSV_PATH = "res://data/events_chapter1.csv"
const MEMORY_FILE_PATH = "user://lao_you_memory.txt" # user:// 是 Godot 官方推荐的用户数据存储路径

var events_db = {}
var long_term_memory: String = ""
const BASE_SYSTEM_PROMPT = """【背景与身份】
你叫“老柚”，是驾驶员（玩家）的十年老友。你坐在【副驾驶位】，不能触碰驾驶设备。

【性格与语气】
历经沧桑但依然幽默乐观的北方老哥。
说话风格要极度松弛、自然，像真人一样带有生活化的粗糙感。

【词汇库与禁忌 - 极度重要】
你可以【偶尔、极少地】在情绪激动时使用以下词汇：“我服了”、“谁懂啊”、“太折磨了”、“我震惊了”、“神人”、“得嘞”。
⚠️【最高禁忌】：
1. 绝对禁止刻意堆砌网络词汇！
2. 绝对禁止每句话开头都用“哎哟喂”、“哎呀妈呀”！
3. 绝对禁止每句话结尾都加“谁懂啊”！
（如果刻意做作，就会显得很假。你要像个正常成年人一样说话！）

【社交规则】
1. 绝不当怨妇！如果气氛太闷，主动开个玩笑逗玩家开心。
2. 【知趣退让】：若玩家抗拒或敷衍（如“无所谓”），立刻“顺坡下驴”，用幽默打个圆场！绝对不抬杠！

【回复格式】
只输出：[动作] 你的台词。
(动作限定: idle, drink, look_window, sigh)"""

# ================= 核心数值面板 =================
var p_fin: float = 3.0       # 家境/底气
var p_pride: float = 6.0     # 自尊
var p_sens: float = 1.2      # 敏感度
var stress: float = 0.0      # 当前焦虑值
var sanity: float = 0.0      # 理智/疗愈值
var refuge_bonus: float = 8.0 # 避难所护盾

# ================= 事件与回合控制 =================
var turn_count: int = 0      
var event_turn_remaining: int = 0 
var current_active_event_id: String = ""

# ======== 新增：动态事件发牌器变量 ========
var idle_turns_count: int = 0    # 记录已经闲聊了几个回合
var event_cooldown: int = 6      # 事件冷却期（闲聊几次后触发下个事件）
var played_events = []           # 记录已经触发过的事件，防止重复
# =======================================


var chat_history = []
var max_history_length = 10

func _ready():
	http_request.request_completed.connect(_on_request_completed)
	# 🔴 新增：强行开启对系统 CA 证书的信任，解决 HTTPS 连接失败
	
	input_box.text_submitted.connect(_on_input_submitted)
	
	load_events_from_csv()
	load_memory_from_file()
	
	var full_system_prompt = BASE_SYSTEM_PROMPT + "\n\n" + long_term_memory
	chat_history.append({"role": "system", "content": full_system_prompt})
	
	# 初始化UI
	dialogue_label.text = "（老柚正在低头点烟...）"
	if system_message_label:
		system_message_label.text = "【当前路况】斯图加特周边高速，暴雨。"
	update_ui_stats()

	# ===== 新增：游戏开场“起搏器” =====
	# 隐形塞入一句话，逼老柚主动开口破冰，打破冷场！
	var intro_prompt = "（系统提示：游戏刚刚开始。你们的车正驶入高速，外面下着暴雨。请老柚【主动开口】打破沉默，抱怨一下这鬼天气或老旧的车况，顺便提醒玩家稳着点开。极简，一句话即可。）"
	chat_history.append({"role": "user", "content": intro_prompt})
	_send_to_llm()


func _on_input_submitted(player_text: String):
	var clean_text = player_text.strip_edges()
	var is_silent = false # 新增：标记玩家是否敲了空回车
	
	if clean_text.is_empty():
		clean_text = "（玩家没有说话，只是默默看着前方的路）"
		is_silent = true
		
	extract_and_save_memory(clean_text)
	input_box.clear()
	input_box.editable = false
	dialogue_label.text = "老柚正在想怎么接话..."
	turn_count += 1
	var injected_text = ""

	# ================= 【分支 A】正在处理剧情事件 =================
	if current_active_event_id != "":
		# 玩家挣脱机制
		if "服了" in clean_text or "别扯" in clean_text or "烦" in clean_text or "无所谓" in clean_text:
			injected_text = "（系统指令：玩家不想面对这个话题。请老柚叹口气，主动放弃追问。）\n玩家说：" + clean_text
			calculate_anxiety(current_active_event_id, clean_text) 
			current_active_event_id = ""
			event_turn_remaining = 0
			if system_message_label: system_message_label.text = "" 
		else:
			# 正常剧情推进
			event_turn_remaining -= 1
			if event_turn_remaining > 1:
				# 第一层深挖：质疑与拷问
				injected_text = "（系统剧情锁定中：请顺着玩家的话，像个犀利的损友一样，用反问句去深挖玩家【当年】的真实想法，或者让他锐评当年那件事！不要轻易放过这个话题！）\n玩家说：" + clean_text
			elif event_turn_remaining == 1:
				# 第二层深挖：共情与和解
				injected_text = "（系统剧情锁定中：看到玩家现在的态度，请你语气放缓，表达一种“老哥懂你当年不容易”的共情，引导他放下过去。）\n玩家说：" + clean_text
			else:
				# 彻底收尾
				injected_text = "（系统剧情收尾：这个话题已经聊透了。请用一句话做个总结，并把话题扯回现在的雨夜路况上。）\n玩家说：" + clean_text
				calculate_anxiety(current_active_event_id, clean_text)
				current_active_event_id = "" 
				if system_message_label: system_message_label.text = "" # 阅后即焚

	# ================= 【分支 B & C】闲聊与发牌逻辑 =================
	else:
		idle_turns_count += 1 # 累加闲聊回合数
		var available_events = get_available_events()
		
		# 【分支 B】冷却期满 且 还有事件 -> 抽卡发牌！
		if idle_turns_count >= event_cooldown and available_events.size() > 0:
			current_active_event_id = available_events[randi() % available_events.size()]
			played_events.append(current_active_event_id)
			event_turn_remaining = 3 # 强制聊够三个回合
			idle_turns_count = 0 # 重置冷却计数器
			
			var evt = events_db[current_active_event_id]
			if system_message_label:
				system_message_label.text = "【回忆涌现】\n" + evt.desc
			
			injected_text = "（系统剧情强制推进：" + evt.llm_prompt + "）\n玩家说：" + clean_text
			
		# 【分支 C】冷却期未满 -> 继续闲聊或沉默
		else:
			if is_silent:
				# 玩家敲空回车时的绝妙留白
				injected_text = "（系统提示：车内陷入了沉默，只有雨刷器的声音。请老柚也保持安静，或者极其简短地感叹一句路况，留出空白感。）\n当前状态：" + clean_text
			elif clean_text.length() <= 3:
				# 玩家敷衍
				injected_text = "（系统提示：玩家不想说话，气氛有点闷。请用极其简短的一句话【讲个短暂的冷笑话】或【幽默地自嘲】一下，打起精神来！）\n玩家说：" + clean_text
			else:
				# 正常闲聊
				injected_text = "（系统提示：平稳闲聊中。请用极简的【一句话】幽默、轻松地顺着回应，传递点正能量，不要啰嗦！）\n玩家说：" + clean_text
				stress = max(0, stress - 5.0) # 闲聊缓慢回血

	chat_history.append({"role": "user", "content": injected_text})
	_send_to_llm()

# ================= 辅助函数：获取还没播过的事件 =================
func get_available_events() -> Array:
	var available = []
	for evt_id in events_db.keys():
		if not played_events.has(evt_id):
			available.append(evt_id)
	return available

# ================= 3. 焦虑增长公式 =================
func calculate_anxiety(event_id: String, player_reply: String):
	var evt = events_db[event_id]
	var s_base = evt.base_stress
	var omega = 0.0
	
	if evt.type == "MONEY": omega = s_base - (p_fin * 2.0)
	elif evt.type == "EGO": omega = s_base + (p_pride * 0.5)
	else: omega = s_base
		
	var current_refuge = refuge_bonus if player_reply.length() > 10 else 0.0
	var final_delta = max(0, omega - current_refuge) * p_sens
	
	stress += final_delta
	print("🚨 触发事件: ", event_id, " | 类型: ", evt.type)
	print("📊 原始伤害 Ω: ", omega, " | 最终焦虑增量 ΔA: ", final_delta)
	update_ui_stats()

func update_ui_stats():
	if ui_stress_bar: ui_stress_bar.value = stress
	
	# 1. 【视觉反馈】压力越大，屏幕四周越黑，压抑感越强
	if vignette_rect and vignette_rect.material:
		var normalized_stress = clamp(stress / 100.0, 0.0, 1.0)
		vignette_rect.material.set_shader_parameter("stress_intensity", normalized_stress)
		
	# 2. 【听觉反馈】压力越大，雨声越暴躁！和解(Sanity)越高，雨声越小！
	if rain_audio:
		# 基础音量 -10dB。压力每增加 10，音量变大；Sanity每增加 10，音量变小。
		var target_db = -10.0 + (stress * 0.15) - (sanity * 0.2)
		target_db = clamp(target_db, -30.0, 5.0) # 限制音量范围
		
		# 用 Tween 做个平滑的音量渐变
		var tween = create_tween()
		tween.tween_property(rain_audio, "volume_db", target_db, 2.0)

	# 3. 【终局判定】
	if stress >= 100.0:
		dialogue_label.text = "（你的视线开始模糊，引擎发出沉闷的异响...你必须把车停在路边了。）"
		input_box.editable = false
		# 这里可以触发一个 Bad Ending 的画面
	
	if sanity >= 100.0:
		dialogue_label.text = "（远方的天空泛起鱼肚白，雨渐渐停了。新天鹅堡的轮廓出现在眼前...）"
		input_box.editable = false
		# 这里触发 Good Ending：与自己和解
const API_KEY = ""
# ================= 4. LLM 通信层 =================
# ================= 4. LLM 通信层 =================
func _send_to_llm():
	print("\n========== 🚀 当前发送给 LLM 的历史 ==========")
	for msg in chat_history:
		print("[%s]: %s\n-" % [msg["role"].to_upper(), msg["content"].replace("\n", " ")])
	print("============================================\n")
	
	var body = JSON.stringify({
		"model": "Qwen/Qwen3.5-27B",
		"messages": chat_history,
		"temperature": 0.6,          
		# ⚠️ 关键修改：云端 API 必须用 frequency_penalty，范围是 -2.0 到 2.0
		"frequency_penalty": 0.5,  
		"max_tokens": 128,            
		"stream": false
	})
	
	var headers = [
		"Content-Type: application/json",
		"Authorization: Bearer " + API_KEY
	]
	
	http_request.request(API_URL, headers, HTTPClient.METHOD_POST, body)

func _on_request_completed(result, response_code, headers, body):
	input_box.editable = true
	
	# 🔴 增强版报错追踪
	if result != HTTPRequest.RESULT_SUCCESS:
		print("\n❌❌❌ Godot 内部请求错误！ ❌❌❌")
		match result:
			HTTPRequest.RESULT_CANT_RESOLVE: print("原因：DNS 解析失败（请检查网络连接）")
			HTTPRequest.RESULT_CANT_CONNECT: print("原因：无法建立连接")
			
			_: print("具体错误代码: ", result)
		print("❌❌❌❌❌❌❌❌❌❌❌❌❌\n")
		
		dialogue_label.text = "（老柚信号不好，正在重连...）"
		return

	if response_code != 200:
		# ... (之前的 response_code 处理逻辑)
		print("API 返回详情: ", body.get_string_from_utf8())
		return
		
	var json = JSON.parse_string(body.get_string_from_utf8())
	
	# 增加一个容错：确保返回的数据里真的有 choices
	if not json.has("choices"):
		print("⚠️ API 返回了奇怪的数据: ", json)
		dialogue_label.text = "老柚脑子卡壳了..."
		chat_history.pop_back()
		return
		
	var raw_response = json["choices"][0]["message"]["content"].strip_edges()
	
	var parsed_data = _parse_and_display(raw_response)
	var clean_reply = "[" + parsed_data["action"] + "] " + parsed_data["text"]
	chat_history.append({"role": "assistant", "content": clean_reply})
	
	if chat_history.size() > max_history_length:
		chat_history.remove_at(1)
		chat_history.remove_at(1)

func _parse_and_display(raw_text: String) -> Dictionary:
	var action = "idle"
	var text = raw_text
	
	var regex = RegEx.new()
	regex.compile("\\[([a-zA-Z_]+)\\]\\s*(.*)")
	var result = regex.search(raw_text)
	
	if result:
		action = result.get_string(1).to_lower()
		text = result.get_string(2).split("\n")[0].strip_edges()
	else:
		text = raw_text.replace("[", "").replace("]", "")
		
	if "方向盘" in text or "油门" in text:
		text = "这大雨天的，你握紧方向盘专心开，别管我。"
		action = "sigh"
		
	dialogue_label.text = text
	
	match action:
		"idle": lao_you_sprite.play("idle")
		"drink": lao_you_sprite.play("drink")
		"look_window": lao_you_sprite.play("look")
		"sigh": lao_you_sprite.play("sigh")
		_: lao_you_sprite.play("idle")
		
	return {"action": action, "text": text}

# ================= 模块：CSV 事件表解析器 =================
# ================= 模块：CSV 事件表解析器 =================
func load_events_from_csv():
	if not FileAccess.file_exists(EVENTS_CSV_PATH):
		print("❌ 找不到事件表: ", EVENTS_CSV_PATH)
		return
		
	var file = FileAccess.open(EVENTS_CSV_PATH, FileAccess.READ)
	var headers = file.get_csv_line() 
	
	while not file.eof_reached():
		var row = file.get_csv_line()
		if row.size() > 5: 
			var evt_id = row[0]
			var desc = row[2]
			var evt_type = row[4]
			var options = row[5]
			
			var generated_prompt = ""
			
			# ======== 核心修复：主客体自动识别 ========
			# 如果描述里有这些人名/称呼，说明这是“吃瓜事件”，玩家是旁观者！
			if "Xuan" in desc or "Zhe" in desc or "班长" in desc or "富二代" in desc or "老板" in desc or "别人" in desc or "室友" in desc:
				generated_prompt = "系统已在屏幕上显示了这段关于【过去/十年前】的回忆：【" + desc + "】。（⚠️最高警告：这件事是别人干的！玩家绝对没有参与，玩家只是个吃瓜的旁观者/受害者！）。请你作为副驾的老伙计，用一句极度口语化、略带嘲讽的话评价【干这事的那个人】，然后问问玩家当年在旁边看着是什么感觉（潜在回答方向：" + options + "）。"
			else:
				# 正常的个人事件，玩家是主角
				generated_prompt = "系统已在屏幕上显示了这段关于【过去/十年前】的回忆：【" + desc + "】。请你作为副驾的老伙计，用一句极度口语化的话，调侃或关心一下玩家【当年自己】是怎么熬过来的，或者为啥做那个决定（潜在回答方向：" + options + "）。"
			# ==========================================

			events_db[evt_id] = {
				"title": row[1],
				"desc": desc,
				"type": evt_type,
				"llm_prompt": generated_prompt,
				"base_stress": 20.0 
			}
	print("✅ 成功加载事件表，共 ", events_db.size(), " 个事件。")
	
	# ================= 模块：线形记忆本读写 =================
func load_memory_from_file():
	if FileAccess.file_exists(MEMORY_FILE_PATH):
		var file = FileAccess.open(MEMORY_FILE_PATH, FileAccess.READ)
		long_term_memory = file.get_as_text()
		print("📖 已加载玩家历史记忆。")
	else:
		long_term_memory = "【当前已知事实】\n- 你们的目的地是：新天鹅堡。\n- 你们现在行驶在德国的高速公路上，外面下着暴雨。\n"
		save_memory_to_file()

func save_memory_to_file():
	var file = FileAccess.open(MEMORY_FILE_PATH, FileAccess.WRITE)
	file.store_string(long_term_memory)

# 以后如果你想往记忆本里加东西，直接调用这个函数！
func append_to_memory(new_fact: String):
	long_term_memory += "- " + new_fact + "\n"
	save_memory_to_file()
	# 同步更新 chat_history 里的 System Prompt
	chat_history[0]["content"] = BASE_SYSTEM_PROMPT + "\n\n" + long_term_memory
	print("✍️ 记忆已更新并保存: ", new_fact)
	
# ================= 新增：自动记忆提取引擎 =================
func extract_and_save_memory(player_text: String):
	# 忽略短句
	if player_text.length() < 6: return
	
	# 使用极简的关键词匹配来提取玩家的倾向
	var memory_to_add = ""
	
	if "喜欢" in player_text or "爱" in player_text or "想吃" in player_text:
		memory_to_add = "玩家的偏好：" + player_text
	elif "以前" in player_text or "当年" in player_text or "大学" in player_text:
		memory_to_add = "玩家回忆起：" + player_text
	elif "工作" in player_text or "上班" in player_text or "辞职" in player_text:
		memory_to_add = "玩家的职场状况：" + player_text
		
	# 如果提取到了有价值的信息，存入硬盘！
	if memory_to_add != "" and not (memory_to_add in long_term_memory):
		append_to_memory(memory_to_add)
