extends Control
## Title screen: Play drops into the loading screen, which streams the
## Kathmandu world in before handing off; Quit exits the app.

const LOADING_SCENE := "res://scenes/loading_screen.tscn"

@onready var _play_button: Button = %PlayButton
@onready var _quit_button: Button = %QuitButton

func _ready() -> void:
	_play_button.pressed.connect(_on_play_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)
	_play_button.grab_focus()

func _on_play_pressed() -> void:
	get_tree().change_scene_to_file(LOADING_SCENE)

func _on_quit_pressed() -> void:
	get_tree().quit()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()
