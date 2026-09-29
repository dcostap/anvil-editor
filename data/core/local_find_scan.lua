-- Shared line matching for the UI slices and long-line workers.
local scan = {}

function scan.compile(query, is_regex, case_sensitive)
  local compiled
  if is_regex then
    local ok, result = pcall(regex.compile, query, case_sensitive and "" or "i")
    if not ok or not result then return nil, "Invalid regex" end
    compiled = result
  elseif not case_sensitive then
    query = query:lower()
  end
  return { query = query, regex = is_regex, case_sensitive = case_sensitive, compiled = compiled }
end

function scan.line(text, search, emit, checkpoint)
  local source = (not search.regex and not search.case_sensitive) and text:lower() or text
  local pos = 1
  while pos <= #source do
    local s, e
    if search.regex then
      s, e = regex.find_offsets(search.compiled, source, pos)
    else
      s, e = source:find(search.query, pos, true)
    end
    if not s then break end
    if e and e >= s and (e ~= #source or s ~= e) then
      emit(s, e == #source and e or e + 1)
    end
    pos = math.max((e or s) + 1, s + 1)
    if checkpoint then checkpoint() end
  end
  if checkpoint then checkpoint() end
end

return scan
