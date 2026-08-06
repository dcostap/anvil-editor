local config = require "core.config"
local projection = require "core.markdown.pending_projection"
local style = require "core.style"

local pending_render = {}

function pending_render.current_source(
  view, line, previous, current_text, code,
  source_fallback, prose_render, scaled_font, heading_from_source, heading_font,
  reveal_code_delimiter, code_render
)
  local function inline_fragments(text, base_col)
    local fragments = {}
    for _, span in ipairs(projection.inline_spans(text, line, base_col)) do
      local content = span.content_ranges and span.content_ranges[1]
      local fragment = {
        source_col1 = span.col1,
        source_col2 = span.col2,
        text_source_col1 = content and content.col1 or span.col1,
        text_source_col2 = content and content.col2 or span.col2,
        text = span.text,
        color = style.text,
      }
      if span.type == "strong" then
        fragment.font = scaled_font(
          view, style.prose_strong_font, view:get_font():get_size()
        )
      elseif span.type == "emphasis" then
        fragment.font = scaled_font(
          view, style.prose_emphasis_font, view:get_font():get_size()
        )
      elseif span.type == "strong_emphasis" then
        fragment.font = scaled_font(
          view, style.prose_strong_emphasis_font, view:get_font():get_size()
        )
      elseif span.type == "code" then
        fragment.font = style.syntax_fonts.normal
        fragment.color = style.syntax.normal
        fragment.background = style.markdown_live_inline_code_bg
      elseif span.type == "strikethrough" then
        fragment.strikethrough = true
      elseif span.type == "highlight" then
        fragment.background = style.markdown_live_highlight_bg
      elseif span.type == "comment" then
        fragment.hidden = true
      elseif span.link then
        fragment.color = style.markdown_live_link
        fragment.underline = true
      end
      fragments[#fragments + 1] = fragment
    end
    return fragments
  end

  local owner = view.__markdown_live_owner
  local topology = owner and owner.provisional_topology
  if topology and topology.revision == view.doc.text_revision
    and topology.fence_delimiters and topology.fence_delimiters[line]
  then
    if reveal_code_delimiter then
      return source_fallback(view, previous, current_text, true)
    end
    return {
      source_text = current_text,
      metric_height = view:get_line_height(),
      markdown_pending_provenance = "unavailable",
      fragments = {
        {
          source_col1 = 1,
          source_col2 = #current_text + 1,
          hidden = true,
        },
      },
    }
  end
  if topology and topology.revision == view.doc.text_revision
    and topology.frontmatter[line]
  then
    local render = source_fallback(view, previous, current_text, false)
    render.markdown_pending_provenance = "unavailable"
    for _, fragment in ipairs(render.fragments or {}) do
      fragment.color = (current_text:match("^%s*%-%-%-%s*$")
          or current_text:match("^%s*%.%.%.%s*$"))
        and style.markdown_live_frontmatter_delimiter or style.text
    end
    return render
  end
  if topology and topology.revision == view.doc.text_revision
    and topology.html[line]
  then
    local render = source_fallback(view, previous, current_text, true)
    render.markdown_pending_provenance = "unavailable"
    return render
  end
  if topology and topology.revision == view.doc.text_revision
    and topology.comments[line]
  then
    return {
      source_text = current_text,
      markdown_pending_provenance = "unavailable",
      fragments = {
        {
          source_col1 = 1,
          source_col2 = #current_text + 1,
          hidden = true,
        },
      },
    }
  end

  if topology and topology.revision == view.doc.text_revision
    and topology.math[line]
  then
    local render = source_fallback(view, previous, current_text, false)
    render.markdown_pending_provenance = "unavailable"
    for _, fragment in ipairs(render.fragments or {}) do
      fragment.font = style.syntax_fonts.normal
      fragment.color = style.markdown_live_math
      fragment.background = style.markdown_live_math_background
    end
    return render
  end

  if code then
    if code_render then
      local render = code_render(view, line, current_text)
      render.markdown_pending_provenance = "unavailable"
      return render
    end
    local font = style.syntax_fonts.normal or view:get_font()
    local height = font:get_height()
    for _, candidate in pairs(style.syntax_fonts) do
      if candidate and candidate.get_height then
        height = math.max(height, candidate:get_height())
      end
    end
    return {
      source_text = current_text,
      x_offset = view:get_font():get_width(" "),
      text_row_height = math.max(math.floor(height * config.line_height), height),
      markdown_pending_provenance = "unavailable",
      fragments = {
        {
          source_col1 = 1,
          source_col2 = #current_text + 1,
          text = current_text,
          font = font,
          color = style.syntax.normal,
        },
      },
    }
  end

  if not code then
    local next_text = line and (view.doc.lines[line + 1] or ""):gsub("\n$", "") or ""
    local next_compact = next_text:gsub("%s", "")
    local setext_level = next_compact:match("^=+$") and 1
      or next_compact:match("^%-+$") and 2 or nil
    if setext_level and current_text ~= "" then
      local font = heading_font(view, setext_level)
      local fragments = inline_fragments(current_text, 1)
      if #fragments == 0 then
        fragments[1] = {
          source_col1 = 1,
          source_col2 = #current_text + 1,
          text = current_text,
          font = font,
          color = style.text,
        }
      else
        for _, fragment in ipairs(fragments) do
          if not fragment.font then fragment.font = font end
        end
      end
      local render = prose_render(view, current_text, {
        fragments = fragments,
        text_row_height = math.floor(font:get_height() * config.line_height),
      })
      render.markdown_pending_provenance = "unavailable"
      return render
    end

    local compact = current_text:gsub("%s", "")
    local setext_marker = compact:match("^=+$") or compact:match("^%-+$")
    local previous_text = line and line > 1
      and (view.doc.lines[line - 1] or ""):gsub("\n$", "") or ""
    if setext_marker and #compact >= 1 and previous_text ~= "" then
      return {
        source_text = current_text,
        markdown_pending_provenance = "unavailable",
        fragments = {
          {
            source_col1 = 1,
            source_col2 = #current_text + 1,
            hidden = true,
          },
        },
      }
    end
    local thematic = #compact >= 3 and (
      compact:gsub("%*", "") == ""
      or compact:gsub("_", "") == ""
      or compact:gsub("%-", "") == ""
    )
    if thematic then
      local render = prose_render(view, current_text, {
        fragments = {
          {
            source_col1 = 1,
            source_col2 = #current_text + 1,
            text = "────────────────",
            color = style.markdown_live_rule,
          },
        },
      })
      render.markdown_pending_provenance = "unavailable"
      return render
    end

    local _, callout_end, callout_type, callout_fold = current_text:find(
      "^%s*>%s*%[!([%w_-]+)%]([+-]?)%s*"
    )
    if callout_end then
      local content_col1 = callout_end + 1
      local title = current_text:sub(content_col1)
      local display_type = callout_type:lower()
        :gsub("[_-]+", " "):gsub("^%l", string.upper)
      local fold = callout_fold == "+" and "▾ "
        or callout_fold == "-" and "▸ " or ""
      local fragments = inline_fragments(title, content_col1)
      table.insert(fragments, 1, {
        source_col1 = 1,
        source_col2 = content_col1,
        text = "◆ " .. fold .. (title == "" and display_type or ""),
        color = style.markdown_live_callout_icon,
      })
      if #fragments == 1 and title ~= "" then
        fragments[#fragments + 1] = {
          source_col1 = content_col1,
          source_col2 = #current_text + 1,
          text = title,
          color = style.text,
        }
      end
      local render = prose_render(view, current_text, { fragments = fragments })
      render.markdown_pending_provenance = "unavailable"
      return render
    end

    local _, quote_end = current_text:find("^%s*>%s*")
    if quote_end then
      local content_col1 = quote_end + 1
      local fragments = inline_fragments(
        current_text:sub(content_col1), content_col1
      )
      table.insert(fragments, 1, {
        source_col1 = 1,
        source_col2 = content_col1,
        text = "│ ",
        color = style.markdown_live_quote_bar,
      })
      if #fragments == 1 and content_col1 <= #current_text then
        fragments[#fragments + 1] = {
          source_col1 = content_col1,
          source_col2 = #current_text + 1,
          text = current_text:sub(content_col1),
          color = style.text,
        }
      end
      local render = prose_render(view, current_text, { fragments = fragments })
      render.markdown_pending_provenance = "unavailable"
      return render
    end

    local heading = heading_from_source(current_text, line)
    if heading then
      local font = heading_font(view, heading.level)
      local fragments = inline_fragments(heading.text, heading.content_col1)
      table.insert(fragments, 1, {
        source_col1 = 1,
        source_col2 = heading.content_col1,
        hidden = true,
      })
      if #fragments == 1 then
        fragments[#fragments + 1] = {
          source_col1 = heading.content_col1,
          source_col2 = heading.content_col2,
          text = heading.text,
          font = font,
          color = style.text,
        }
      else
        for _, fragment in ipairs(fragments) do
          if not fragment.hidden and not fragment.font then fragment.font = font end
        end
      end
      if heading.content_col2 <= #current_text then
        fragments[#fragments + 1] = {
          source_col1 = heading.content_col2,
          source_col2 = #current_text + 1,
          hidden = true,
        }
      end
      local render = prose_render(view, current_text, {
        fragments = fragments,
        text_row_height = math.floor(font:get_height() * config.line_height),
      })
      render.markdown_pending_provenance = "unavailable"
      return render
    end

    local inline = inline_fragments(current_text, 1)
    if #inline > 0 then
      local render = prose_render(view, current_text, { fragments = inline })
      render.markdown_pending_provenance = "unavailable"
      return render
    end
  end
  return source_fallback(view, previous, current_text, code)
end

return pending_render
