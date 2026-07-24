extends Control
## Streams scenes/kathmandu.tscn in on a background thread (so the progress
## bar reflects real load progress) and hands off once it's ready. Building
## the world itself (terrain mesh, starting chunks) still happens
## synchronously inside the scene's _ready, so the bar parks near full and
## the status label switches to a "generating" message for that last stretch
## instead of claiming false progress.

const TARGET_SCENE := "res://scenes/kathmandu.tscn"

@onready var _status: Label = %StatusLabel
@onready var _bar: ProgressBar = %ProgressBar

func _ready() -> void:
	_status.text = "Loading map data..."
	# Let the label/bar actually paint before the load call takes over the thread.
	await get_tree().process_frame
	await get_tree().process_frame

	var err := ResourceLoader.load_threaded_request(TARGET_SCENE)
	if err != OK:
		_status.text = "Failed to load (error %d)" % err
		return

	while true:
		var progress: Array = []
		var status := ResourceLoader.load_threaded_get_status(TARGET_SCENE, progress)
		match status:
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				_bar.value = progress[0] * 100.0
				await get_tree().process_frame
			ResourceLoader.THREAD_LOAD_LOADED:
				break
			_:
				_status.text = "Failed to load (status %d)" % status
				return

	_bar.value = 100.0
	_status.text = "Generating streets, buildings and traffic..."
	await get_tree().process_frame
	await get_tree().process_frame

	var packed: PackedScene = ResourceLoader.load_threaded_get(TARGET_SCENE)
	get_tree().change_scene_to_packed(packed)
