extends Reference

const SLICE_USEC = 8000


static func checkpoint(work: Dictionary):
	if not work.has("tree"):
		return true
	var now = OS.get_ticks_usec()
	var started = work.get("slice_started", now)
	work.slice_started = started
	work.max_slice_usec = max(work.get("max_slice_usec", 0), now - started)
	if now - started < SLICE_USEC:
		return true
	yield(work.tree, "idle_frame")
	work.slice_started = OS.get_ticks_usec()
	work.yields = work.get("yields", 0) + 1
	return work.is_current.is_valid() and work.is_current.call_func(work.signature)
