extends CanvasLayer

var manager
var context_owner
var _panel
var _text
var _title
var _lines = []
var _render_pending = false
var _pending_lines = []


func _ready() -> void:
	layer = 20
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.rect_clip_content = true
	# 标题的换行高度在容器分配宽度后才稳定，须重新收回首次布局撑大的面板。
	_panel.connect("minimum_size_changed", self, "_position", [], CONNECT_DEFERRED)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.05, 0.06, 0.94)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	_panel.add_stylebox_override("panel", style)
	add_child(_panel)
	var box = VBoxContainer.new()
	_panel.add_child(box)
	var font = DynamicFont.new()
	font.font_data = load("res://resources/fonts/raw/NotoSansSC-Medium.otf")
	font.size = 22
	_title = Label.new()
	manager.connect("automation_changed", self, "_update_title")
	_update_title()
	_title.autowrap = true
	_title.max_lines_visible = 3
	_title.rect_min_size.y = 64
	_title.add_font_override("font", font)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_title)
	_text = RichTextLabel.new()
	_text.mouse_filter = Control.MOUSE_FILTER_STOP
	_text.focus_mode = Control.FOCUS_NONE
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text.add_font_override("normal_font", font)
	_text.scroll_following = true
	_text.add_color_override("default_color", Color(0.9, 0.96, 0.92))
	box.add_child(_text)
	get_viewport().connect("size_changed", self, "_position")
	_position()
	_panel.visible = manager.log_visible and context_owner.is_active()


func _process(delta: float) -> void:
	_panel.visible = manager.log_visible and context_owner.is_active()
	if not _panel.visible:
		return
	for device in Input.get_connected_joypads():
		if manager.input_router.modifier_held(device):
			var axis = Input.get_joy_axis(device, JOY_AXIS_3)
			if abs(axis) > 0.25:
				_text.get_v_scroll().value += axis * 420.0 * delta


func _update_title() -> void:
	_title.text = manager.shortcut_hint()


func open() -> void:
	manager.log_visible = true
	_panel.visible = context_owner.is_active()


func toggle() -> void:
	manager.log_visible = not manager.log_visible
	_panel.visible = manager.log_visible and context_owner.is_active()


func clear_page() -> void:
	_lines.clear()
	_text.scroll_following = false
	_text.clear()
	_text.get_v_scroll().value = 0.0


func write(message: String) -> void:
	var time = OS.get_time()
	var line = "%02d:%02d:%02d %s" % [time.hour, time.minute, time.second, message]
	_lines.append(line)
	if _lines.size() > 90:
		_lines.pop_front()
	if not _render_pending:
		_render_pending = true
		call_deferred("_render")
	_pending_lines.append(line)


func _flush() -> void:
	if _pending_lines.empty():
		return
	var file = File.new()
	if file.open("user://potato_autobuy.log", File.READ_WRITE) != OK:
		file.open("user://potato_autobuy.log", File.WRITE)
	if file.is_open():
		file.seek_end()
		file.store_line(PoolStringArray(_pending_lines).join("\n"))
		file.close()
	ModLoaderLog.info(PoolStringArray(_pending_lines).join("\n"), "Potato-AutoBuild")
	_pending_lines.clear()


func _exit_tree() -> void:
	_flush()


func _render() -> void:
	_render_pending = false
	_flush()
	_text.text = PoolStringArray(_lines).join("\n")


func _position() -> void:
	var visible = get_viewport().get_visible_rect()
	var size = visible.size
	var height = clamp(size.y - 32.0, 1.0, 360.0)
	var bounds = context_owner.log_rect(size) if context_owner.has_method("log_rect") else Rect2(16, size.y - height - 16, min(820, size.x * 0.48), height)
	bounds.size.x = clamp(bounds.size.x, 1.0, max(1.0, size.x - 32.0))
	bounds.size.y = clamp(bounds.size.y, 1.0, max(1.0, size.y - 32.0))
	bounds.position.x = clamp(bounds.position.x, 0.0, max(0.0, size.x - bounds.size.x))
	bounds.position.y = clamp(bounds.position.y, 0.0, max(0.0, size.y - bounds.size.y))
	_panel.rect_position = visible.position + bounds.position
	_panel.rect_size = bounds.size
