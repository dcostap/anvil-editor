-- File previews load on a worker. Wait until the preview shows or is blocked.
-- The picker's live search can finish during the wait. Keep the test's results.
return function(picker)
  local results, selected = picker.results, picker.selected
  local deadline = system.get_time() + 30
  local preview = picker:update_preview_view()
  while not preview and not picker.preview_blocked and system.get_time() < deadline do
    coroutine.yield(0.001)
    picker.results, picker.selected = results, selected
    preview = picker:update_preview_view()
  end
  return preview
end
