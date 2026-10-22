-- Line or row changes between two layout states.
--
-- A change list maps positions of an old state to a new state. It is a sorted
-- list of regions `{ old1, old2, new1, new2 }`. Each region replaces positions
-- `old1..old2` with `new1..new2`. Both spans include their ends and are not
-- empty. A position outside every region moves by the size changes of the
-- regions before it.
local layout_changes = {}

local function delta(region)
  return (region.new2 - region.new1) - (region.old2 - region.old1)
end

---Return the changes from the old state of `first` to the new state of
---`second`. The new state of `first` is the old state of `second`. Regions of
---the two lists that overlap there become one region.
function layout_changes.compose(first, second)
  if not first or #first == 0 then return second end
  if not second or #second == 0 then return first end
  -- Each item is a span in the middle state.
  local items = {}
  for _, region in ipairs(first) do
    items[#items + 1] = { region.new1, region.new2, delta(region), 0 }
  end
  for _, region in ipairs(second) do
    items[#items + 1] = { region.old1, region.old2, 0, delta(region) }
  end
  table.sort(items, function(a, b)
    if a[1] == b[1] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  local result = {}
  -- The size changes of all earlier regions of each list.
  local first_delta, second_delta = 0, 0
  local index = 1
  while index <= #items do
    local item = items[index]
    local mid1, mid2 = item[1], item[2]
    local cluster_first, cluster_second = item[3], item[4]
    index = index + 1
    while index <= #items and items[index][1] <= mid2 do
      item = items[index]
      mid2 = math.max(mid2, item[2])
      cluster_first = cluster_first + item[3]
      cluster_second = cluster_second + item[4]
      index = index + 1
    end
    result[#result + 1] = {
      old1 = mid1 - first_delta,
      old2 = mid2 - first_delta - cluster_first,
      new1 = mid1 + second_delta,
      new2 = mid2 + second_delta + cluster_second,
    }
    first_delta = first_delta + cluster_first
    second_delta = second_delta + cluster_second
  end
  return result
end

---The line changes of a Buffer transaction.
function layout_changes.from_transaction(transaction)
  local result = {}
  for _, range in ipairs(transaction and transaction.changed_ranges or {}) do
    result[#result + 1] = {
      old1 = range.old_line1, old2 = range.old_line2,
      new1 = range.new_line1, new2 = range.new_line2,
    }
  end
  return result
end

---Changes that replace positions `first..last` with the same number of positions.
function layout_changes.span(first, last)
  return { { old1 = first, old2 = last, new1 = first, new2 = last } }
end

---Changes that replace each span `{ first, last }` with the same number of
---positions. Spans can overlap and can be in any order.
function layout_changes.spans(spans)
  table.sort(spans, function(a, b) return a[1] < b[1] end)
  local result = {}
  for _, span in ipairs(spans) do
    local last = result[#result]
    if last and span[1] <= last.new2 then
      last.new2 = math.max(last.new2, span[2])
      last.old2 = last.new2
    else
      result[#result + 1] = { old1 = span[1], old2 = span[2], new1 = span[1], new2 = span[2] }
    end
  end
  return result
end

---The sum of the size changes.
function layout_changes.total_delta(changes)
  local total = 0
  for _, region in ipairs(changes or {}) do total = total + delta(region) end
  return total
end

return layout_changes
