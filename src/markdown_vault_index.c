#include "markdown_vault_index.h"
#include "markdown_parser.h"
#include "treesitter/snapshot.h"

#include <SDL3/SDL.h>

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

typedef struct OwnedNote {
  AnvilMarkdownVaultNoteView view;
} OwnedNote;

typedef struct OwnedAttachment {
  AnvilMarkdownVaultAttachmentView view;
} OwnedAttachment;

typedef struct TargetGroup {
  char *key;
  uint32_t *indices;
  uint32_t count;
} TargetGroup;

struct AnvilMarkdownVaultSnapshot {
  SDL_AtomicInt refcount;
  OwnedNote *notes;
  uint32_t note_count;
  uint32_t note_capacity;
  OwnedAttachment *attachments;
  uint32_t attachment_count;
  uint32_t attachment_capacity;
  TargetGroup *note_targets;
  uint32_t note_target_count;
  TargetGroup *attachment_targets;
  uint32_t attachment_target_count;
  AnvilMarkdownVaultSummary summary;
};

typedef struct Lines {
  char **items;
  uint32_t count;
} Lines;

typedef struct StructuralLines {
  bool *excluded;
  uint32_t count;
} StructuralLines;

static bool path_match(const char *candidate, const char *target);
static int owned_note_compare(const void *left, const void *right);
static int owned_attachment_compare(const void *left, const void *right);
static bool build_target_indexes(AnvilMarkdownVaultSnapshot *snapshot,
  AnvilMarkdownVaultCancelledFn cancelled_fn, void *cancel_userdata);

static char *dup_range(const char *text, size_t len) {
  char *copy = (char *)SDL_malloc(len + 1);
  if (!copy) return NULL;
  if (len) memcpy(copy, text, len);
  copy[len] = '\0';
  return copy;
}

static char *trim_copy(const char *text, size_t len) {
  while (len && isspace((unsigned char)*text)) { text++; len--; }
  while (len && isspace((unsigned char)text[len - 1])) len--;
  return dup_range(text, len);
}

static const char *basename_ptr(const char *path) {
  const char *base = path;
  for (const char *cursor = path; *cursor; cursor++) if (*cursor == '/' || *cursor == '\\') base = cursor + 1;
  return base;
}

static char *display_name(const char *relative, bool markdown) {
  const char *base = basename_ptr(relative);
  size_t len = strlen(base);
  if (markdown) {
    const char *dot = strrchr(base, '.');
    if (dot) len = (size_t)(dot - base);
  }
  return dup_range(base, len);
}

static bool cancelled(const AnvilMarkdownVaultBuildSpec *spec) {
  return spec->cancelled && spec->cancelled(spec->cancel_userdata);
}

static void set_error(char **error, const char *message) {
  if (error) *error = SDL_strdup(message ? message : "Markdown vault snapshot failed");
}

static bool add_string(const char ***items, uint32_t *count, const char *value, size_t len) {
  char **grown = (char **)SDL_realloc((void *)*items, ((size_t)*count + 1) * sizeof(char *));
  if (!grown) return false;
  char *copy = trim_copy(value, len);
  if (!copy) { *items = (const char **)grown; return false; }
  grown[*count] = copy;
  *items = (const char **)grown;
  (*count)++;
  return true;
}

static void free_strings(const char *const *items, uint32_t count) {
  for (uint32_t i = 0; i < count; i++) SDL_free((void *)items[i]);
  SDL_free((void *)items);
}

static Lines split_lines(char *text, size_t len) {
  Lines lines = { 0 };
  uint32_t count = 1;
  for (size_t i = 0; i < len; i++) if (text[i] == '\n') count++;
  lines.items = (char **)SDL_calloc(count, sizeof(char *));
  if (!lines.items) return lines;
  lines.items[lines.count++] = text;
  for (size_t i = 0; i < len; i++) {
    if (text[i] == '\r' && i + 1 < len && text[i + 1] == '\n') text[i] = '\0';
    if (text[i] == '\n') { text[i] = '\0'; if (i + 1 < len) lines.items[lines.count++] = text + i + 1; }
  }
  return lines;
}

static char ascii_lower(char c) { return c >= 'A' && c <= 'Z' ? (char)(c + 32) : c; }

static bool equals_ci(const char *a, const char *b) {
  if (!a || !b) return false;
  while (*a && *b) if (ascii_lower(*a++) != ascii_lower(*b++)) return false;
  return !*a && !*b;
}

static bool contains_ci(const char *haystack, const char *needle) {
  if (!haystack || !needle) return false;
  size_t n = strlen(needle);
  if (!n) return true;
  for (const char *h = haystack; *h; h++) {
    size_t i = 0;
    while (i < n && h[i] && ascii_lower(h[i]) == ascii_lower(needle[i])) i++;
    if (i == n) return true;
  }
  return false;
}

static char *strip_markdown_extension(const char *path) {
  size_t len = strlen(path);
  const char *dot = strrchr(path, '.');
  if (dot && (equals_ci(dot, ".md") || equals_ci(dot, ".markdown") || equals_ci(dot, ".mdown"))) len = (size_t)(dot - path);
  return dup_range(path, len);
}

static char *heading_slug(const char *text) {
  size_t len = strlen(text);
  char *slug = (char *)SDL_malloc(len * 3 + 4);
  if (!slug) return NULL;
  size_t out = 0;
  bool dash = false, code = false;
  for (size_t i = 0; i < len; i++) {
    char c = text[i];
    if (c == '`') { code = !code; continue; }
    if (c == '&' && i + 4 < len && strncmp(text + i, "&amp;", 5) == 0) {
      if (out && dash) slug[out++] = '-';
      dash = false;
      memcpy(slug + out, "and", 3); out += 3; i += 4; continue;
    }
    if (isalnum((unsigned char)c) || c == '_' || c == '-') {
      if (out && dash) slug[out++] = '-';
      dash = false;
      slug[out++] = ascii_lower(c);
    } else if (isspace((unsigned char)c)) dash = out > 0;
    else if ((unsigned char)c >= 128) slug[out++] = c;
    (void)code;
  }
  while (out && slug[out - 1] == '-') out--;
  slug[out] = '\0';
  return slug;
}

static char *clean_preview(const char *line) {
  while (*line && isspace((unsigned char)*line)) line++;
  while (*line == '#') line++;
  while (*line && isspace((unsigned char)*line)) line++;
  size_t len = strlen(line);
  while (len && isspace((unsigned char)line[len - 1])) len--;
  while (len && line[len - 1] == '#') { len--; while (len && isspace((unsigned char)line[len - 1])) len--; }
  const char *caret = len ? line + len : line;
  while (caret > line && (isalnum((unsigned char)caret[-1]) || caret[-1] == '-')) caret--;
  if (caret > line && caret[-1] == '^') {
    size_t before = (size_t)(caret - line - 1);
    while (before && isspace((unsigned char)line[before - 1])) before--;
    len = before;
  }
  bool truncated = len > 240;
  if (truncated) len = 237;
  char *copy = truncated ? (char *)SDL_malloc(len + 4) : dup_range(line, len);
  if (copy && truncated) { memcpy(copy, line, len); memcpy(copy + len, "...", 4); }
  return copy;
}

static bool line_is_fence(const char *line) {
  while (*line == ' ' || *line == '\t') line++;
  return strncmp(line, "```", 3) == 0 || strncmp(line, "~~~", 3) == 0;
}

static bool position_in_code(const char *line, size_t position) {
  bool code = false, escaped = false;
  for (size_t i = 0; line[i] && i < position; i++) {
    if (escaped) escaped = false;
    else if (line[i] == '\\') escaped = true;
    else if (line[i] == '`') code = !code;
  }
  return code;
}

static bool append_metadata(AnvilMarkdownVaultNoteView *note, const char *key, const char **values, uint32_t count, bool list) {
  AnvilMarkdownVaultMetadataView *grown = (AnvilMarkdownVaultMetadataView *)SDL_realloc((void *)note->metadata,
    ((size_t)note->metadata_count + 1) * sizeof(*grown));
  if (!grown) return false;
  note->metadata = grown;
  AnvilMarkdownVaultMetadataView *meta = &grown[note->metadata_count++];
  meta->key = SDL_strdup(key); meta->values = values; meta->value_count = count; meta->list = list;
  return meta->key != NULL;
}

static bool parse_list_values(const char *value, const char ***values, uint32_t *count) {
  size_t len = strlen(value);
  const char *start = value;
  if (len >= 2 && value[0] == '[' && value[len - 1] == ']') { start++; len -= 2; }
  size_t item = 0; char quote = 0; bool escaped = false;
  for (size_t i = 0; i <= len; i++) {
    char c = i < len ? start[i] : ',';
    if (escaped) escaped = false;
    else if (quote == '"' && c == '\\') escaped = true;
    else if (quote) { if (c == quote) quote = 0; }
    else if (c == '"' || c == '\'') quote = c;
    else if (c == ',') {
      const char *raw = start + item; size_t raw_len = i - item;
      while (raw_len && isspace((unsigned char)*raw)) { raw++; raw_len--; }
      while (raw_len && isspace((unsigned char)raw[raw_len - 1])) raw_len--;
      if (raw_len >= 2 && ((raw[0] == '"' && raw[raw_len - 1] == '"') || (raw[0] == '\'' && raw[raw_len - 1] == '\''))) { raw++; raw_len -= 2; }
      if (raw_len && !add_string(values, count, raw, raw_len)) return false;
      item = i + 1;
    }
  }
  return true;
}

static bool parse_frontmatter(AnvilMarkdownVaultNoteView *note, Lines *lines, uint32_t *body_start) {
  *body_start = 0;
  if (!lines->count || (strcmp(lines->items[0], "---") != 0 && strcmp(lines->items[0], "+++") != 0)) return true;
  const char *delimiter = lines->items[0];
  *body_start = 1;
  AnvilMarkdownVaultMetadataView *current = NULL;
  for (uint32_t line = 1; line < lines->count; line++) {
    if (strcmp(lines->items[line], delimiter) == 0) { *body_start = line + 1; return true; }
    char *colon = strchr(lines->items[line], ':');
    if (!colon) {
      const char *item = lines->items[line]; while (*item && isspace((unsigned char)*item)) item++;
      if (current && item[0] == '-' && isspace((unsigned char)item[1])) {
        item += 2; while (*item && isspace((unsigned char)*item)) item++;
        size_t item_len = strlen(item);
        if (item_len >= 2 && ((item[0] == '"' && item[item_len - 1] == '"') || (item[0] == '\'' && item[item_len - 1] == '\''))) { item++; item_len -= 2; }
        if (!add_string(&current->values, &current->value_count, item, item_len)) return false;
        const char *stored = current->values[current->value_count - 1];
        if (strcmp(current->key, "aliases") == 0 || strcmp(current->key, "alias") == 0) {
          if (!add_string(&note->aliases, &note->alias_count, stored, strlen(stored))) return false;
        } else if (strcmp(current->key, "tags") == 0 || strcmp(current->key, "tag") == 0) {
          const char *tag = stored[0] == '#' ? stored + 1 : stored;
          if (!add_string(&note->tags, &note->tag_count, tag, strlen(tag))) return false;
        }
      }
      continue;
    }
    char *key = trim_copy(lines->items[line], (size_t)(colon - lines->items[line]));
    char *value = trim_copy(colon + 1, strlen(colon + 1));
    if (!key || !value) { SDL_free(key); SDL_free(value); return false; }
    for (char *c = key; *c; c++) *c = ascii_lower(*c);
    const char **values = NULL; uint32_t count = 0;
    bool list = value[0] == '[';
    if (list) {
      if (!parse_list_values(value, &values, &count)) { SDL_free(key); SDL_free(value); return false; }
    } else if (value[0]) {
      const char *raw = value; size_t raw_len = strlen(value);
      if (raw_len >= 2 && ((raw[0] == '"' && raw[raw_len - 1] == '"') || (raw[0] == '\'' && raw[raw_len - 1] == '\''))) { raw++; raw_len -= 2; }
      if (!add_string(&values, &count, raw, raw_len)) { SDL_free(key); SDL_free(value); return false; }
    }
    if (!append_metadata(note, key, values, count, list)) { SDL_free(key); SDL_free(value); return false; }
    current = value[0] == '\0' ? &note->metadata[note->metadata_count - 1] : NULL;
    if (strcmp(key, "aliases") == 0 || strcmp(key, "alias") == 0) {
      for (uint32_t i = 0; i < count; i++) if (!add_string(&note->aliases, &note->alias_count, values[i], strlen(values[i]))) return false;
    }
    if (strcmp(key, "tags") == 0 || strcmp(key, "tag") == 0) {
      for (uint32_t i = 0; i < count; i++) {
        const char *tag = values[i][0] == '#' ? values[i] + 1 : values[i];
        if (!add_string(&note->tags, &note->tag_count, tag, strlen(tag))) return false;
      }
    }
    SDL_free(key); SDL_free(value);
  }
  return true;
}

static bool append_heading(AnvilMarkdownVaultNoteView *note, const char *text, uint32_t line, uint32_t level,
  char **hierarchy, char **slug_hierarchy) {
  AnvilMarkdownVaultHeadingView *grown = (AnvilMarkdownVaultHeadingView *)SDL_realloc((void *)note->headings,
    ((size_t)note->heading_count + 1) * sizeof(*grown));
  if (!grown) return false;
  note->headings = grown;
  AnvilMarkdownVaultHeadingView *heading = &grown[note->heading_count++];
  SDL_memset(heading, 0, sizeof(*heading));
  heading->text = SDL_strdup(text); heading->slug = heading_slug(text); heading->line = line; heading->level = level;
  if (!heading->text || !heading->slug) return false;
  for (uint32_t i = level; i < 6; i++) { SDL_free(hierarchy[i]); hierarchy[i] = NULL; SDL_free(slug_hierarchy[i]); slug_hierarchy[i] = NULL; }
  SDL_free(hierarchy[level - 1]); SDL_free(slug_hierarchy[level - 1]);
  hierarchy[level - 1] = SDL_strdup(text); slug_hierarchy[level - 1] = heading_slug(text);
  size_t text_len = 0, slug_len = 0;
  for (uint32_t i = 0; i < level; i++) if (hierarchy[i]) { text_len += strlen(hierarchy[i]) + 1; slug_len += strlen(slug_hierarchy[i]) + 1; }
  char *path_text = (char *)SDL_calloc(text_len + 1, 1), *path_slug = (char *)SDL_calloc(slug_len + 1, 1);
  if (!path_text || !path_slug) { SDL_free(path_text); SDL_free(path_slug); return false; }
  for (uint32_t i = 0; i < level; i++) if (hierarchy[i]) {
    if (*path_text) strcat(path_text, "#");
    strcat(path_text, hierarchy[i]);
    if (*path_slug) strcat(path_slug, "#");
    strcat(path_slug, slug_hierarchy[i]);
  }
  heading->path_text = path_text; heading->path_slug = path_slug;
  return true;
}

static bool append_block(AnvilMarkdownVaultNoteView *note, const char *id, size_t len, uint32_t line, uint32_t col) {
  AnvilMarkdownVaultBlockView *grown = (AnvilMarkdownVaultBlockView *)SDL_realloc((void *)note->blocks,
    ((size_t)note->block_count + 1) * sizeof(*grown));
  if (!grown) return false;
  note->blocks = grown;
  AnvilMarkdownVaultBlockView *block = &grown[note->block_count++];
  SDL_memset(block, 0, sizeof(*block)); block->id = dup_range(id, len); block->line = line; block->col1 = col; block->col2 = col + (uint32_t)len + 1;
  return block->id != NULL;
}

static bool append_link(AnvilMarkdownVaultNoteView *note, const char *kind, const char *target, size_t target_len,
  const char *alias, size_t alias_len, uint32_t line, uint32_t col1, uint32_t col2) {
  AnvilMarkdownVaultLinkView *grown = (AnvilMarkdownVaultLinkView *)SDL_realloc((void *)note->links,
    ((size_t)note->link_count + 1) * sizeof(*grown));
  if (!grown) return false;
  note->links = grown;
  AnvilMarkdownVaultLinkView *link = &grown[note->link_count++]; SDL_memset(link, 0, sizeof(*link));
  link->kind = SDL_strdup(kind); link->raw_target = trim_copy(target, target_len);
  if (alias) link->alias = trim_copy(alias, alias_len);
  link->source_line = line; link->source_col1 = col1; link->source_col2 = col2;
  if (!link->kind || !link->raw_target || (alias && !link->alias)) return false;
  char *hash = strchr((char *)link->raw_target, '#');
  if (hash) {
    link->path = dup_range(link->raw_target, (size_t)(hash - link->raw_target));
    link->subtarget = SDL_strdup(hash + 1);
    link->block_subtarget = hash[1] == '^';
    if (link->block_subtarget && link->subtarget) memmove((char *)link->subtarget, link->subtarget + 1, strlen(link->subtarget));
  } else link->path = SDL_strdup(link->raw_target);
  return link->path && (!hash || link->subtarget);
}

static bool parse_links(AnvilMarkdownVaultNoteView *note, const char *line, uint32_t line_number) {
  size_t len = strlen(line);
  for (size_t i = 0; i < len; i++) {
    if (position_in_code(line, i)) continue;
    bool embed = line[i] == '!' && i + 2 < len && line[i + 1] == '[' && line[i + 2] == '[';
    bool wiki = line[i] == '[' && i + 1 < len && line[i + 1] == '[';
    if (embed || wiki) {
      size_t open = i + (embed ? 3 : 2), close = open;
      while (close + 1 < len && !(line[close] == ']' && line[close + 1] == ']')) close++;
      if (close + 1 >= len) continue;
      const char *pipe = memchr(line + open, '|', close - open);
      size_t target_len = pipe ? (size_t)(pipe - (line + open)) : close - open;
      if (!append_link(note, embed ? "embed" : "wiki", line + open, target_len,
          pipe ? pipe + 1 : NULL, pipe ? (size_t)(line + close - pipe - 1) : 0,
          line_number, (uint32_t)i + 1, (uint32_t)close + 3)) return false;
      i = close + 1; continue;
    }
    bool image = line[i] == '!' && i + 1 < len && line[i + 1] == '[';
    if (image || line[i] == '[') {
      size_t label_open = i + (image ? 1 : 0), label_close = label_open + 1;
      while (label_close < len && line[label_close] != ']') label_close++;
      if (label_close + 1 >= len || line[label_close + 1] != '(') continue;
      size_t dest_start = label_close + 2, close = dest_start;
      while (close < len && line[close] != ')') close++;
      if (close >= len) continue;
      while (dest_start < close && isspace((unsigned char)line[dest_start])) dest_start++;
      size_t dest_end = dest_start;
      if (dest_start < close && line[dest_start] == '<') {
        dest_start++; dest_end = dest_start; while (dest_end < close && line[dest_end] != '>') dest_end++;
      } else while (dest_end < close && !isspace((unsigned char)line[dest_end])) dest_end++;
      if (dest_end > dest_start && !append_link(note, image ? "image" : "markdown", line + dest_start, dest_end - dest_start,
          line + label_open + 1, label_close - label_open - 1, line_number, (uint32_t)i + 1, (uint32_t)close + 2)) return false;
      i = close;
    }
  }
  return true;
}

static StructuralLines parse_structural_lines(const char *text, size_t len,
  AnvilMarkdownVaultCancelledFn cancelled_fn, void *cancel_userdata) {
  StructuralLines lines = { 0 };
  char *owned_text = dup_range(text, len), *error = NULL;
  if (!owned_text) return lines;
  AnvilTSSnapshot *source = anvil_ts_snapshot_new_take_text(owned_text, (uint32_t)len, &error);
  if (!source) { SDL_free(error); return lines; }
  AnvilMarkdownTree *tree = anvil_markdown_tree_parse(
    source, 0, (AnvilMarkdownCancelCallback)cancelled_fn, cancel_userdata, &error
  );
  if (!tree) { SDL_free(error); anvil_ts_snapshot_free(source); return lines; }
  lines.count = source->line_count;
  lines.excluded = (bool *)SDL_calloc(lines.count ? lines.count : 1, sizeof(bool));
  if (lines.excluded) {
    TSTreeCursor cursor = ts_tree_cursor_new(ts_tree_root_node(anvil_markdown_tree_block_tree(tree)));
    bool walking = true;
    while (walking) {
      TSNode node = ts_tree_cursor_current_node(&cursor); const char *type = ts_node_type(node);
      if (strcmp(type, "fenced_code_block") == 0 || strcmp(type, "indented_code_block") == 0
          || strcmp(type, "html_block") == 0) {
        uint32_t first = ts_node_start_point(node).row, last = ts_node_end_point(node).row;
        if (last >= lines.count) last = lines.count ? lines.count - 1 : 0;
        for (uint32_t row = first; row < lines.count && row <= last; row++) lines.excluded[row] = true;
      }
      if (ts_tree_cursor_goto_first_child(&cursor)) continue;
      while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
        if (!ts_tree_cursor_goto_parent(&cursor)) { walking = false; break; }
      }
    }
    ts_tree_cursor_delete(&cursor);
  }
  anvil_markdown_tree_free(tree); anvil_ts_snapshot_free(source); SDL_free(error);
  return lines;
}

static bool parse_note_text(OwnedNote *owned, char *text, size_t len, bool shallow,
  AnvilMarkdownVaultCancelledFn cancelled_fn, void *cancel_userdata) {
  AnvilMarkdownVaultNoteView *note = &owned->view;
  StructuralLines structural = shallow ? (StructuralLines){ 0 }
    : parse_structural_lines(text, len, cancelled_fn, cancel_userdata);
  if (cancelled_fn && cancelled_fn(cancel_userdata)) { SDL_free(structural.excluded); return false; }
  Lines lines = split_lines(text, len);
  if (!lines.items) { SDL_free(structural.excluded); return false; }
  uint32_t body_start = 0;
  if (!parse_frontmatter(note, &lines, &body_start)) { SDL_free(lines.items); SDL_free(structural.excluded); return false; }
  for (uint32_t i = body_start; i < lines.count && note->preview_count < 3; i++) {
    char *preview = clean_preview(lines.items[i]);
    if (preview && preview[0] && strcmp(preview, "---") && strcmp(preview, "+++")) {
      const char **grown = (const char **)SDL_realloc((void *)note->preview, ((size_t)note->preview_count + 1) * sizeof(char *));
      if (!grown) { SDL_free(preview); SDL_free(lines.items); SDL_free(structural.excluded); return false; }
      note->preview = grown; ((char **)note->preview)[note->preview_count++] = preview;
    } else SDL_free(preview);
  }
  if (shallow) { SDL_free(lines.items); SDL_free(structural.excluded); return true; }
  bool fence = false, html = false;
  char *hierarchy[6] = { 0 }, *slug_hierarchy[6] = { 0 };
  for (uint32_t i = body_start; i < lines.count; i++) {
    if ((i & 127u) == 0 && cancelled_fn && cancelled_fn(cancel_userdata)) {
      for (uint32_t level = 0; level < 6; level++) { SDL_free(hierarchy[level]); SDL_free(slug_hierarchy[level]); }
      SDL_free(lines.items); SDL_free(structural.excluded); return false;
    }
    const char *line = lines.items[i];
    if (line_is_fence(line)) { fence = !fence; continue; }
    const char *trim = line; while (*trim && isspace((unsigned char)*trim)) trim++;
    if (!fence && trim[0] == '<' &&
        (isalpha((unsigned char)trim[1]) || trim[1] == '/' || trim[1] == '!')) html = true;
    bool excluded = fence || html || (structural.excluded && i < structural.count && structural.excluded[i]);
    if (!excluded) {
      uint32_t level = 0; while (line[level] == '#' && level < 6) level++;
      if (level && isspace((unsigned char)line[level])) {
        const char *start = line + level; while (*start && isspace((unsigned char)*start)) start++;
        size_t text_len = strlen(start); while (text_len && isspace((unsigned char)start[text_len - 1])) text_len--;
        while (text_len && start[text_len - 1] == '#') { text_len--; while (text_len && isspace((unsigned char)start[text_len - 1])) text_len--; }
        char *heading = dup_range(start, text_len);
        bool ok = heading && append_heading(note, heading, i + 1, level, hierarchy, slug_hierarchy); SDL_free(heading);
        if (!ok) { SDL_free(lines.items); SDL_free(structural.excluded); return false; }
      } else if (i + 1 < lines.count && line[0]) {
        const char *underline = lines.items[i + 1]; while (*underline && isspace((unsigned char)*underline)) underline++;
        if ((*underline == '=' || *underline == '-') && strspn(underline, *underline == '=' ? "=" : "-") == strlen(underline)) {
          if (!append_heading(note, line, i + 1, *underline == '=' ? 1 : 2, hierarchy, slug_hierarchy)) { SDL_free(lines.items); SDL_free(structural.excluded); return false; }
        }
      }
      for (size_t p = 0; line[p]; p++) if (line[p] == '^' && !position_in_code(line, p)) {
        bool before = p == 0 || isspace((unsigned char)line[p - 1]);
        size_t end = p + 1; while (isalnum((unsigned char)line[end]) || line[end] == '-') end++;
        bool after = !line[end] || isspace((unsigned char)line[end]) || strchr(".,;:!?)]", line[end]);
        if (before && after && end > p + 1 && !append_block(note, line + p + 1, end - p - 1, i + 1, p + 1)) { SDL_free(lines.items); SDL_free(structural.excluded); return false; }
      }
      if (!parse_links(note, line, i + 1)) { SDL_free(lines.items); SDL_free(structural.excluded); return false; }
    }
    if (html && ((trim[0] == '<' && trim[1] == '/') || contains_ci(trim, "-->"))) html = false;
  }
  for (uint32_t i = 0; i < 6; i++) { SDL_free(hierarchy[i]); SDL_free(slug_hierarchy[i]); }
  for (uint32_t h = 0; h < note->heading_count; h++) {
    uint32_t line = note->headings[h].line;
    uint32_t end = lines.count;
    for (uint32_t next = h + 1; next < note->heading_count; next++) if (note->headings[next].level <= note->headings[h].level) { end = note->headings[next].line - 1; break; }
    for (uint32_t i = line; i < end && note->headings[h].preview_count < 2; i++) {
      char *preview = clean_preview(lines.items[i]);
      if (preview && preview[0]) {
        const char **grown = (const char **)SDL_realloc((void *)note->headings[h].preview,
          ((size_t)note->headings[h].preview_count + 1) * sizeof(char *));
        if (!grown) { SDL_free(preview); SDL_free(lines.items); SDL_free(structural.excluded); return false; }
        note->headings[h].preview = grown; ((char **)note->headings[h].preview)[note->headings[h].preview_count++] = preview;
      } else SDL_free(preview);
    }
  }
  for (uint32_t b = 0; b < note->block_count; b++) {
    char *preview = clean_preview(lines.items[note->blocks[b].line - 1]);
    if (preview && preview[0]) {
      const char **items = (const char **)SDL_malloc(sizeof(char *)); if (!items) { SDL_free(preview); SDL_free(lines.items); SDL_free(structural.excluded); return false; }
      items[0] = preview; note->blocks[b].preview = items; note->blocks[b].preview_count = 1;
    } else SDL_free(preview);
  }
  SDL_free(lines.items); SDL_free(structural.excluded);
  return true;
}

static void fact_hash_bytes(uint32_t *hash, const void *bytes, size_t len) {
  const unsigned char *data = (const unsigned char *)bytes;
  for (size_t i = 0; i < len; i++) { *hash ^= data[i]; *hash *= 16777619u; }
  *hash ^= 0xffu; *hash *= 16777619u;
}

static void fact_hash_string(uint32_t *hash, const char *text) { fact_hash_bytes(hash, text ? text : "", text ? strlen(text) : 0); }

static uint32_t note_fact_hash(const AnvilMarkdownVaultNoteView *note) {
  uint32_t hash = 2166136261u;
  for (uint32_t i = 0; i < note->alias_count; i++) fact_hash_string(&hash, note->aliases[i]);
  for (uint32_t i = 0; i < note->tag_count; i++) fact_hash_string(&hash, note->tags[i]);
  for (uint32_t i = 0; i < note->preview_count; i++) fact_hash_string(&hash, note->preview[i]);
  for (uint32_t i = 0; i < note->heading_count; i++) {
    const AnvilMarkdownVaultHeadingView *heading = &note->headings[i];
    fact_hash_string(&hash, heading->text); fact_hash_string(&hash, heading->path_slug);
    fact_hash_bytes(&hash, &heading->line, sizeof(heading->line)); fact_hash_bytes(&hash, &heading->level, sizeof(heading->level));
    for (uint32_t p = 0; p < heading->preview_count; p++) fact_hash_string(&hash, heading->preview[p]);
  }
  for (uint32_t i = 0; i < note->block_count; i++) {
    const AnvilMarkdownVaultBlockView *block = &note->blocks[i]; fact_hash_string(&hash, block->id);
    fact_hash_bytes(&hash, &block->line, sizeof(block->line));
    for (uint32_t p = 0; p < block->preview_count; p++) fact_hash_string(&hash, block->preview[p]);
  }
  for (uint32_t i = 0; i < note->link_count; i++) {
    const AnvilMarkdownVaultLinkView *link = &note->links[i];
    fact_hash_string(&hash, link->kind); fact_hash_string(&hash, link->raw_target); fact_hash_string(&hash, link->alias);
    fact_hash_bytes(&hash, &link->source_line, sizeof(link->source_line)); fact_hash_bytes(&hash, &link->source_col1, sizeof(link->source_col1)); fact_hash_bytes(&hash, &link->source_col2, sizeof(link->source_col2));
  }
  return hash;
}

static void free_note(OwnedNote *owned) {
  AnvilMarkdownVaultNoteView *note = &owned->view;
  SDL_free((void *)note->absolute_path); SDL_free((void *)note->relative_path);
  SDL_free((void *)note->relative_no_extension); SDL_free((void *)note->display_name);
  free_strings(note->aliases, note->alias_count); free_strings(note->tags, note->tag_count); free_strings(note->preview, note->preview_count);
  for (uint32_t i = 0; i < note->heading_count; i++) {
    SDL_free((void *)note->headings[i].text); SDL_free((void *)note->headings[i].slug);
    SDL_free((void *)note->headings[i].path_text); SDL_free((void *)note->headings[i].path_slug);
    free_strings(note->headings[i].preview, note->headings[i].preview_count);
  }
  SDL_free((void *)note->headings);
  for (uint32_t i = 0; i < note->block_count; i++) { SDL_free((void *)note->blocks[i].id); free_strings(note->blocks[i].preview, note->blocks[i].preview_count); }
  SDL_free((void *)note->blocks);
  for (uint32_t i = 0; i < note->link_count; i++) {
    SDL_free((void *)note->links[i].kind); SDL_free((void *)note->links[i].raw_target); SDL_free((void *)note->links[i].path);
    SDL_free((void *)note->links[i].alias); SDL_free((void *)note->links[i].subtarget);
  }
  SDL_free((void *)note->links);
  for (uint32_t i = 0; i < note->metadata_count; i++) { SDL_free((void *)note->metadata[i].key); free_strings(note->metadata[i].values, note->metadata[i].value_count); }
  SDL_free((void *)note->metadata);
}

static bool clone_string_list(const char ***out, uint32_t *out_count, const char *const *items, uint32_t count) {
  for (uint32_t i = 0; i < count; i++) if (!add_string(out, out_count, items[i], strlen(items[i]))) return false;
  return true;
}

static bool clone_note(OwnedNote *destination, const AnvilMarkdownVaultNoteView *source) {
  SDL_memset(destination, 0, sizeof(*destination)); AnvilMarkdownVaultNoteView *note = &destination->view;
  note->absolute_path = SDL_strdup(source->absolute_path); note->relative_path = SDL_strdup(source->relative_path);
  note->relative_no_extension = SDL_strdup(source->relative_no_extension);
  note->display_name = SDL_strdup(source->display_name); note->size = source->size; note->modified = source->modified;
  note->shallow = source->shallow; note->fact_signature = source->fact_signature;
  if (!note->absolute_path || !note->relative_path || !note->relative_no_extension || !note->display_name
      || !clone_string_list(&note->aliases, &note->alias_count, source->aliases, source->alias_count)
      || !clone_string_list(&note->tags, &note->tag_count, source->tags, source->tag_count)
      || !clone_string_list(&note->preview, &note->preview_count, source->preview, source->preview_count)) goto failed;
  if (source->heading_count) {
    note->headings = (AnvilMarkdownVaultHeadingView *)SDL_calloc(source->heading_count, sizeof(*note->headings)); if (!note->headings) goto failed;
    note->heading_count = source->heading_count;
    for (uint32_t i = 0; i < source->heading_count; i++) {
      const AnvilMarkdownVaultHeadingView *from = &source->headings[i]; AnvilMarkdownVaultHeadingView *to = &note->headings[i];
      to->text = SDL_strdup(from->text); to->slug = SDL_strdup(from->slug); to->path_text = SDL_strdup(from->path_text); to->path_slug = SDL_strdup(from->path_slug);
      to->line = from->line; to->level = from->level;
      if (!to->text || !to->slug || !to->path_text || !to->path_slug
          || !clone_string_list(&to->preview, &to->preview_count, from->preview, from->preview_count)) goto failed;
    }
  }
  if (source->block_count) {
    note->blocks = (AnvilMarkdownVaultBlockView *)SDL_calloc(source->block_count, sizeof(*note->blocks)); if (!note->blocks) goto failed;
    note->block_count = source->block_count;
    for (uint32_t i = 0; i < source->block_count; i++) {
      const AnvilMarkdownVaultBlockView *from = &source->blocks[i]; AnvilMarkdownVaultBlockView *to = &note->blocks[i];
      to->id = SDL_strdup(from->id); to->line = from->line; to->col1 = from->col1; to->col2 = from->col2;
      if (!to->id || !clone_string_list(&to->preview, &to->preview_count, from->preview, from->preview_count)) goto failed;
    }
  }
  if (source->link_count) {
    note->links = (AnvilMarkdownVaultLinkView *)SDL_calloc(source->link_count, sizeof(*note->links)); if (!note->links) goto failed;
    note->link_count = source->link_count;
    for (uint32_t i = 0; i < source->link_count; i++) {
      AnvilMarkdownVaultLinkView *to = &note->links[i]; const AnvilMarkdownVaultLinkView *from = &source->links[i]; *to = *from;
      to->kind = SDL_strdup(from->kind); to->raw_target = SDL_strdup(from->raw_target); to->path = SDL_strdup(from->path);
      to->alias = from->alias ? SDL_strdup(from->alias) : NULL; to->subtarget = from->subtarget ? SDL_strdup(from->subtarget) : NULL;
      if (!to->kind || !to->raw_target || !to->path || (from->alias && !to->alias) || (from->subtarget && !to->subtarget)) goto failed;
    }
  }
  if (source->metadata_count) {
    note->metadata = (AnvilMarkdownVaultMetadataView *)SDL_calloc(source->metadata_count, sizeof(*note->metadata)); if (!note->metadata) goto failed;
    note->metadata_count = source->metadata_count;
    for (uint32_t i = 0; i < source->metadata_count; i++) {
      AnvilMarkdownVaultMetadataView *to = &note->metadata[i]; const AnvilMarkdownVaultMetadataView *from = &source->metadata[i];
      to->key = SDL_strdup(from->key); to->list = from->list;
      if (!to->key || !clone_string_list(&to->values, &to->value_count, from->values, from->value_count)) goto failed;
    }
  }
  return true;
failed:
  free_note(destination); SDL_memset(destination, 0, sizeof(*destination)); return false;
}

static const AnvilMarkdownVaultNoteView *find_reusable_note(const AnvilMarkdownVaultSnapshot *snapshot,
  const AnvilProjectFileManifestRecord *record) {
  if (!snapshot) return NULL;
  uint32_t index = 0;
  if (anvil_markdown_vault_note_lookup(snapshot, record->absolute_path, &index)) {
    const AnvilMarkdownVaultNoteView *note = &snapshot->notes[index].view;
    if (note->size == record->size && note->modified == record->modified) return note;
  }
  return NULL;
}

static char *load_file_cancellable(const char *path, size_t *size,
  AnvilMarkdownVaultCancelledFn cancelled_fn, void *cancel_userdata) {
  *size = 0; SDL_IOStream *stream = SDL_IOFromFile(path, "rb"); if (!stream) return NULL;
  Sint64 total = SDL_GetIOSize(stream);
  if (total < 0 || (uint64_t)total > SIZE_MAX - 1) { SDL_CloseIO(stream); return NULL; }
  char *text = (char *)SDL_malloc((size_t)total + 1); if (!text) { SDL_CloseIO(stream); return NULL; }
  size_t offset = 0;
  while (offset < (size_t)total) {
    if (cancelled_fn && cancelled_fn(cancel_userdata)) { SDL_free(text); SDL_CloseIO(stream); return NULL; }
    size_t chunk = (size_t)total - offset; if (chunk > 64 * 1024) chunk = 64 * 1024;
    size_t read = SDL_ReadIO(stream, text + offset, chunk); if (!read) { SDL_free(text); SDL_CloseIO(stream); return NULL; }
    offset += read;
  }
  text[offset] = '\0'; *size = offset; SDL_CloseIO(stream); return text;
}

static bool add_note(AnvilMarkdownVaultSnapshot *snapshot, const AnvilProjectFileManifestRecord *record,
  const AnvilMarkdownVaultBuildSpec *spec) {
  if (snapshot->note_count == snapshot->note_capacity) {
    uint32_t next = snapshot->note_capacity ? snapshot->note_capacity * 2 : 128;
    OwnedNote *grown = (OwnedNote *)SDL_realloc(snapshot->notes, (size_t)next * sizeof(*grown)); if (!grown) return false;
    snapshot->notes = grown; snapshot->note_capacity = next;
  }
  OwnedNote *owned = &snapshot->notes[snapshot->note_count]; SDL_memset(owned, 0, sizeof(*owned));
  const AnvilMarkdownVaultNoteView *reusable = find_reusable_note(spec->previous, record);
  bool expected_shallow = spec->shallow_note_bytes && record->size > spec->shallow_note_bytes;
  if (reusable && reusable->shallow == expected_shallow) {
    if (!clone_note(owned, reusable)) return false;
    snapshot->summary.reused_notes++; snapshot->summary.bytes_read += 0;
    snapshot->summary.shallow_notes += reusable->shallow ? 1 : 0;
    snapshot->summary.headings += reusable->heading_count; snapshot->summary.blocks += reusable->block_count;
    snapshot->summary.links += reusable->link_count; snapshot->note_count++; return true;
  }
  AnvilMarkdownVaultNoteView *note = &owned->view;
  note->absolute_path = SDL_strdup(record->absolute_path); note->relative_path = SDL_strdup(record->relative_path);
  note->relative_no_extension = strip_markdown_extension(record->relative_path);
  note->display_name = display_name(record->relative_path, true); note->size = record->size; note->modified = record->modified;
  note->shallow = spec->shallow_note_bytes && record->size > spec->shallow_note_bytes;
  if (!note->absolute_path || !note->relative_path || !note->relative_no_extension || !note->display_name) { free_note(owned); return false; }
  size_t size = 0; char *text = load_file_cancellable(
    record->absolute_path, &size, spec->cancelled, spec->cancel_userdata
  );
  if (!text) {
    if (spec->cancelled && spec->cancelled(spec->cancel_userdata)) { free_note(owned); return false; }
    snapshot->summary.failed_notes++; free_note(owned); return true;
  }
  snapshot->summary.bytes_read += size;
  bool ok = parse_note_text(owned, text, size, note->shallow, spec->cancelled, spec->cancel_userdata);
  SDL_free(text);
  if (!ok) { free_note(owned); return false; }
  note->fact_signature = note_fact_hash(note);
  snapshot->summary.rebuilt_notes++;
  if (note->shallow) snapshot->summary.shallow_notes++;
  snapshot->summary.headings += note->heading_count; snapshot->summary.blocks += note->block_count; snapshot->summary.links += note->link_count;
  snapshot->note_count++;
  return true;
}

static bool add_attachment(AnvilMarkdownVaultSnapshot *snapshot, const AnvilProjectFileManifestRecord *record) {
  if (snapshot->attachment_count == snapshot->attachment_capacity) {
    uint32_t next = snapshot->attachment_capacity ? snapshot->attachment_capacity * 2 : 64;
    OwnedAttachment *grown = (OwnedAttachment *)SDL_realloc(snapshot->attachments, (size_t)next * sizeof(*grown)); if (!grown) return false;
    snapshot->attachments = grown; snapshot->attachment_capacity = next;
  }
  AnvilMarkdownVaultAttachmentView *view = &snapshot->attachments[snapshot->attachment_count].view; SDL_memset(view, 0, sizeof(*view));
  view->absolute_path = SDL_strdup(record->absolute_path); view->relative_path = SDL_strdup(record->relative_path);
  view->display_name = display_name(record->relative_path, false); view->size = record->size; view->modified = record->modified;
  if (!view->absolute_path || !view->relative_path || !view->display_name) return false;
  snapshot->attachment_count++; return true;
}

AnvilMarkdownVaultSnapshot *anvil_markdown_vault_snapshot_build(const AnvilMarkdownVaultBuildSpec *spec, char **error) {
  if (error) *error = NULL;
  if (!spec || !spec->manifest) { set_error(error, "Markdown vault build requires a manifest"); return NULL; }
  if (cancelled(spec)) { set_error(error, "cancelled"); return NULL; }
  Uint64 started = SDL_GetTicksNS();
  AnvilMarkdownVaultSnapshot *snapshot = (AnvilMarkdownVaultSnapshot *)SDL_calloc(1, sizeof(*snapshot));
  if (!snapshot) { set_error(error, "out of memory allocating Markdown vault snapshot"); return NULL; }
  SDL_SetAtomicInt(&snapshot->refcount, 1);
  uint64_t count = anvil_project_file_manifest_count(spec->manifest);
  for (uint64_t i = 0; i < count; i++) {
    if (cancelled(spec)) { set_error(error, "cancelled"); anvil_markdown_vault_snapshot_release(snapshot); return NULL; }
    AnvilProjectFileManifestRecord record;
    if (!anvil_project_file_manifest_record_at(spec->manifest, i, &record)) continue;
    bool ok = record.kind == ANVIL_MANIFEST_MARKDOWN ? add_note(snapshot, &record, spec) :
      (record.kind == ANVIL_MANIFEST_ATTACHMENT ? add_attachment(snapshot, &record) : true);
    if (!ok) {
      set_error(error, cancelled(spec) ? "cancelled" : "out of memory building Markdown vault facts");
      anvil_markdown_vault_snapshot_release(snapshot); return NULL;
    }
  }
  snapshot->summary.note_count = snapshot->note_count; snapshot->summary.attachment_count = snapshot->attachment_count;
  if (snapshot->note_count > 1) qsort(snapshot->notes, snapshot->note_count, sizeof(*snapshot->notes), owned_note_compare);
  if (snapshot->attachment_count > 1) qsort(snapshot->attachments, snapshot->attachment_count, sizeof(*snapshot->attachments), owned_attachment_compare);
  if (!build_target_indexes(snapshot, spec->cancelled, spec->cancel_userdata)) {
    set_error(error, cancelled(spec) ? "cancelled" : "out of memory building Markdown vault lookup indexes");
    anvil_markdown_vault_snapshot_release(snapshot); return NULL;
  }
  snapshot->summary.build_ms = (double)(SDL_GetTicksNS() - started) / 1000000.0;
  return snapshot;
}

AnvilMarkdownVaultSnapshot *anvil_markdown_vault_overlay_build(
  const char *absolute_path, const char *relative_path,
  const char *text, size_t text_len, uint64_t shallow_note_bytes,
  AnvilMarkdownVaultCancelledFn cancelled_fn, void *cancel_userdata, char **error
) {
  if (error) *error = NULL;
  if (!absolute_path || !relative_path || (!text && text_len)) {
    set_error(error, "Markdown vault overlay requires path, relative path, and text");
    return NULL;
  }
  if (cancelled_fn && cancelled_fn(cancel_userdata)) { set_error(error, "cancelled"); return NULL; }
  Uint64 started = SDL_GetTicksNS();
  AnvilMarkdownVaultSnapshot *snapshot = (AnvilMarkdownVaultSnapshot *)SDL_calloc(1, sizeof(*snapshot));
  if (!snapshot) { set_error(error, "out of memory allocating Markdown overlay"); return NULL; }
  SDL_SetAtomicInt(&snapshot->refcount, 1);
  snapshot->notes = (OwnedNote *)SDL_calloc(1, sizeof(*snapshot->notes));
  if (!snapshot->notes) { set_error(error, "out of memory allocating Markdown overlay note"); anvil_markdown_vault_snapshot_release(snapshot); return NULL; }
  snapshot->note_capacity = 1;
  AnvilMarkdownVaultNoteView *note = &snapshot->notes[0].view;
  note->absolute_path = SDL_strdup(absolute_path); note->relative_path = SDL_strdup(relative_path);
  note->relative_no_extension = strip_markdown_extension(relative_path);
  note->display_name = display_name(relative_path, true); note->size = text_len;
  note->shallow = shallow_note_bytes && text_len > shallow_note_bytes;
  char *mutable_text = dup_range(text ? text : "", text_len);
  if (!note->absolute_path || !note->relative_path || !note->relative_no_extension || !note->display_name || !mutable_text
      || !parse_note_text(&snapshot->notes[0], mutable_text, text_len, note->shallow, cancelled_fn, cancel_userdata)) {
    SDL_free(mutable_text); set_error(error, "out of memory building Markdown overlay facts");
    anvil_markdown_vault_snapshot_release(snapshot); return NULL;
  }
  SDL_free(mutable_text);
  if (cancelled_fn && cancelled_fn(cancel_userdata)) { set_error(error, "cancelled"); anvil_markdown_vault_snapshot_release(snapshot); return NULL; }
  note->fact_signature = note_fact_hash(note);
  snapshot->note_count = 1; snapshot->summary.note_count = 1; snapshot->summary.bytes_read = text_len;
  snapshot->summary.shallow_notes = note->shallow ? 1 : 0; snapshot->summary.headings = note->heading_count;
  snapshot->summary.blocks = note->block_count; snapshot->summary.links = note->link_count;
  if (!build_target_indexes(snapshot, cancelled_fn, cancel_userdata)) {
    set_error(error, cancelled_fn && cancelled_fn(cancel_userdata) ? "cancelled" : "out of memory building Markdown overlay lookup indexes");
    anvil_markdown_vault_snapshot_release(snapshot); return NULL;
  }
  snapshot->summary.build_ms = (double)(SDL_GetTicksNS() - started) / 1000000.0;
  return snapshot;
}

void anvil_markdown_vault_snapshot_retain(AnvilMarkdownVaultSnapshot *snapshot) { if (snapshot) SDL_AddAtomicInt(&snapshot->refcount, 1); }
void anvil_markdown_vault_snapshot_release(AnvilMarkdownVaultSnapshot *snapshot) {
  if (!snapshot || SDL_AddAtomicInt(&snapshot->refcount, -1) != 1) return;
  for (uint32_t i = 0; i < snapshot->note_count; i++) free_note(&snapshot->notes[i]);
  for (uint32_t i = 0; i < snapshot->attachment_count; i++) {
    SDL_free((void *)snapshot->attachments[i].view.absolute_path); SDL_free((void *)snapshot->attachments[i].view.relative_path); SDL_free((void *)snapshot->attachments[i].view.display_name);
  }
  for (uint32_t i = 0; i < snapshot->note_target_count; i++) { SDL_free(snapshot->note_targets[i].key); SDL_free(snapshot->note_targets[i].indices); }
  for (uint32_t i = 0; i < snapshot->attachment_target_count; i++) { SDL_free(snapshot->attachment_targets[i].key); SDL_free(snapshot->attachment_targets[i].indices); }
  SDL_free(snapshot->note_targets); SDL_free(snapshot->attachment_targets);
  SDL_free(snapshot->notes); SDL_free(snapshot->attachments); SDL_free(snapshot);
}
void anvil_markdown_vault_snapshot_summary(const AnvilMarkdownVaultSnapshot *snapshot, AnvilMarkdownVaultSummary *summary) {
  if (!summary) return;
  if (snapshot) *summary = snapshot->summary; else SDL_memset(summary, 0, sizeof(*summary));
}
bool anvil_markdown_vault_note_at(const AnvilMarkdownVaultSnapshot *snapshot, uint32_t index, AnvilMarkdownVaultNoteView *view) {
  if (!snapshot || index >= snapshot->note_count || !view) return false;
  *view = snapshot->notes[index].view; return true;
}
bool anvil_markdown_vault_attachment_at(const AnvilMarkdownVaultSnapshot *snapshot, uint32_t index, AnvilMarkdownVaultAttachmentView *view) {
  if (!snapshot || index >= snapshot->attachment_count || !view) return false;
  *view = snapshot->attachments[index].view; return true;
}

static bool path_match(const char *candidate, const char *target) {
  if (equals_ci(candidate, target)) return true;
  for (; *candidate && *target; candidate++, target++) {
    char a = *candidate == '\\' ? '/' : *candidate, b = *target == '\\' ? '/' : *target;
    if (ascii_lower(a) != ascii_lower(b)) return false;
  }
  return !*candidate && !*target;
}

static int path_compare(const char *a, const char *b) {
  while (*a && *b) {
    char left = ascii_lower(*a == '\\' ? '/' : *a), right = ascii_lower(*b == '\\' ? '/' : *b);
    if (left != right) return (unsigned char)left < (unsigned char)right ? -1 : 1;
    a++; b++;
  }
  return *a ? 1 : (*b ? -1 : 0);
}

static int owned_note_compare(const void *left, const void *right) {
  return path_compare(((const OwnedNote *)left)->view.relative_path, ((const OwnedNote *)right)->view.relative_path);
}

static int owned_attachment_compare(const void *left, const void *right) {
  return path_compare(((const OwnedAttachment *)left)->view.relative_path, ((const OwnedAttachment *)right)->view.relative_path);
}

typedef struct TargetPair { char *key; uint32_t index; } TargetPair;

static char *target_key(const char *text) {
  char *key = SDL_strdup(text ? text : ""); if (!key) return NULL;
  for (char *cursor = key; *cursor; cursor++) {
    if (*cursor == '\\') *cursor = '/'; else *cursor = ascii_lower(*cursor);
  }
  return key;
}

static int target_pair_compare(const void *left, const void *right) {
  const TargetPair *a = (const TargetPair *)left, *b = (const TargetPair *)right;
  int compared = strcmp(a->key, b->key); if (compared) return compared;
  return a->index < b->index ? -1 : (a->index > b->index ? 1 : 0);
}

static bool add_target_pair(TargetPair *pairs, uint32_t *count, const char *text, uint32_t index) {
  pairs[*count].key = target_key(text); if (!pairs[*count].key) return false;
  pairs[*count].index = index; (*count)++; return true;
}

static bool collapse_target_pairs(TargetPair *pairs, uint32_t pair_count, TargetGroup **out, uint32_t *out_count) {
  if (!pair_count) return true;
  qsort(pairs, pair_count, sizeof(*pairs), target_pair_compare);
  uint32_t groups = 1; for (uint32_t i = 1; i < pair_count; i++) if (strcmp(pairs[i - 1].key, pairs[i].key) != 0) groups++;
  TargetGroup *result = (TargetGroup *)SDL_calloc(groups, sizeof(*result)); if (!result) return false;
  uint32_t group = 0, start = 0;
  while (start < pair_count) {
    uint32_t end = start + 1; while (end < pair_count && strcmp(pairs[start].key, pairs[end].key) == 0) end++;
    result[group].key = pairs[start].key; pairs[start].key = NULL;
    result[group].indices = (uint32_t *)SDL_malloc((end - start) * sizeof(uint32_t));
    if (!result[group].indices) {
      for (uint32_t i = 0; i <= group; i++) { SDL_free(result[i].key); SDL_free(result[i].indices); }
      SDL_free(result); return false;
    }
    uint32_t previous = UINT32_MAX;
    for (uint32_t i = start; i < end; i++) if (pairs[i].index != previous) {
      result[group].indices[result[group].count++] = pairs[i].index; previous = pairs[i].index;
    }
    group++; start = end;
  }
  *out = result; *out_count = groups; return true;
}

static bool build_target_indexes(AnvilMarkdownVaultSnapshot *snapshot,
  AnvilMarkdownVaultCancelledFn cancelled_fn, void *cancel_userdata) {
  uint64_t note_pairs = 0;
  for (uint32_t i = 0; i < snapshot->note_count; i++) note_pairs += 4 + snapshot->notes[i].view.alias_count;
  uint64_t attachment_pairs = (uint64_t)snapshot->attachment_count * 2;
  if (note_pairs > UINT32_MAX || attachment_pairs > UINT32_MAX) return false;
  TargetPair *notes = note_pairs ? (TargetPair *)SDL_calloc((size_t)note_pairs, sizeof(*notes)) : NULL;
  TargetPair *attachments = attachment_pairs ? (TargetPair *)SDL_calloc((size_t)attachment_pairs, sizeof(*attachments)) : NULL;
  if ((note_pairs && !notes) || (attachment_pairs && !attachments)) { SDL_free(notes); SDL_free(attachments); return false; }
  uint32_t note_count = 0, attachment_count = 0; bool ok = true;
  for (uint32_t i = 0; ok && i < snapshot->note_count; i++) {
    if ((i & 255u) == 0 && cancelled_fn && cancelled_fn(cancel_userdata)) { ok = false; break; }
    const AnvilMarkdownVaultNoteView *note = &snapshot->notes[i].view;
    ok = add_target_pair(notes, &note_count, note->relative_path, i)
      && add_target_pair(notes, &note_count, note->relative_no_extension, i)
      && add_target_pair(notes, &note_count, basename_ptr(note->relative_no_extension), i)
      && add_target_pair(notes, &note_count, note->display_name, i);
    for (uint32_t a = 0; ok && a < note->alias_count; a++) ok = add_target_pair(notes, &note_count, note->aliases[a], i);
  }
  for (uint32_t i = 0; ok && i < snapshot->attachment_count; i++) {
    if ((i & 255u) == 0 && cancelled_fn && cancelled_fn(cancel_userdata)) { ok = false; break; }
    const AnvilMarkdownVaultAttachmentView *entry = &snapshot->attachments[i].view;
    ok = add_target_pair(attachments, &attachment_count, entry->relative_path, i)
      && add_target_pair(attachments, &attachment_count, entry->display_name, i);
  }
  if (ok) ok = collapse_target_pairs(notes, note_count, &snapshot->note_targets, &snapshot->note_target_count)
    && collapse_target_pairs(attachments, attachment_count, &snapshot->attachment_targets, &snapshot->attachment_target_count);
  for (uint32_t i = 0; i < note_count; i++) SDL_free(notes[i].key);
  for (uint32_t i = 0; i < attachment_count; i++) SDL_free(attachments[i].key);
  SDL_free(notes); SDL_free(attachments); return ok;
}

static const TargetGroup *find_target_group(const TargetGroup *groups, uint32_t count, const char *target) {
  char *key = target_key(target); if (!key) return NULL;
  uint32_t low = 0, high = count;
  while (low < high) { uint32_t middle = low + (high - low) / 2; int compared = strcmp(groups[middle].key, key); if (compared < 0) low = middle + 1; else high = middle; }
  const TargetGroup *result = low < count && strcmp(groups[low].key, key) == 0 ? &groups[low] : NULL; SDL_free(key); return result;
}

static bool path_is_absolute(const char *path) {
  return path && ((isalpha((unsigned char)path[0]) && path[1] == ':' && (path[2] == '/' || path[2] == '\\'))
    || ((path[0] == '/' || path[0] == '\\') && (path[1] == '/' || path[1] == '\\')) || path[0] == '/');
}

static bool binary_note_path(const AnvilMarkdownVaultSnapshot *snapshot, const char *path, bool absolute, uint32_t *index) {
  uint32_t low = 0, high = snapshot->note_count;
  while (low < high) {
    uint32_t middle = low + (high - low) / 2; const AnvilMarkdownVaultNoteView *note = &snapshot->notes[middle].view;
    int compared = path_compare(absolute ? note->absolute_path : note->relative_path, path);
    if (compared < 0) low = middle + 1; else high = middle;
  }
  if (low < snapshot->note_count) {
    const AnvilMarkdownVaultNoteView *note = &snapshot->notes[low].view;
    if (path_match(absolute ? note->absolute_path : note->relative_path, path)) { if (index) *index = low; return true; }
  }
  return false;
}

static bool binary_attachment_path(const AnvilMarkdownVaultSnapshot *snapshot, const char *path, bool absolute, uint32_t *index) {
  uint32_t low = 0, high = snapshot->attachment_count;
  while (low < high) {
    uint32_t middle = low + (high - low) / 2; const AnvilMarkdownVaultAttachmentView *entry = &snapshot->attachments[middle].view;
    int compared = path_compare(absolute ? entry->absolute_path : entry->relative_path, path);
    if (compared < 0) low = middle + 1; else high = middle;
  }
  if (low < snapshot->attachment_count) {
    const AnvilMarkdownVaultAttachmentView *entry = &snapshot->attachments[low].view;
    if (path_match(absolute ? entry->absolute_path : entry->relative_path, path)) { if (index) *index = low; return true; }
  }
  return false;
}

bool anvil_markdown_vault_note_lookup(const AnvilMarkdownVaultSnapshot *snapshot, const char *path, uint32_t *index) {
  if (!snapshot || !path) return false;
  if (path_is_absolute(path)) return binary_note_path(snapshot, path, true, index);
  if (binary_note_path(snapshot, path, false, index)) return true;
  for (uint32_t i = 0; i < snapshot->note_count; i++) {
    const AnvilMarkdownVaultNoteView *note = &snapshot->notes[i].view;
    if (path_match(note->absolute_path, path) || path_match(note->relative_path, path)) { if (index) *index = i; return true; }
    if (path_match(note->relative_no_extension, path)) { if (index) *index = i; return true; }
  }
  return false;
}
bool anvil_markdown_vault_attachment_lookup(const AnvilMarkdownVaultSnapshot *snapshot, const char *path, uint32_t *index) {
  if (!snapshot || !path) return false;
  if (path_is_absolute(path)) return binary_attachment_path(snapshot, path, true, index);
  if (binary_attachment_path(snapshot, path, false, index)) return true;
  for (uint32_t i = 0; i < snapshot->attachment_count; i++) {
    const AnvilMarkdownVaultAttachmentView *entry = &snapshot->attachments[i].view;
    if (path_match(entry->absolute_path, path) || path_match(entry->relative_path, path)) { if (index) *index = i; return true; }
  }
  return false;
}
uint32_t anvil_markdown_vault_resolve_notes(const AnvilMarkdownVaultSnapshot *snapshot, const char *target, uint32_t *indices, uint32_t capacity) {
  if (!snapshot || !target) return 0;
  const TargetGroup *group = find_target_group(snapshot->note_targets, snapshot->note_target_count, target);
  if (!group) return 0;
  uint32_t copied = group->count < capacity ? group->count : capacity;
  if (indices && copied) memcpy(indices, group->indices, copied * sizeof(uint32_t));
  return group->count;
}
uint32_t anvil_markdown_vault_resolve_attachments(const AnvilMarkdownVaultSnapshot *snapshot, const char *target, uint32_t *indices, uint32_t capacity) {
  if (!snapshot || !target) return 0;
  const TargetGroup *group = find_target_group(snapshot->attachment_targets, snapshot->attachment_target_count, target);
  if (!group) return 0;
  uint32_t copied = group->count < capacity ? group->count : capacity;
  if (indices && copied) memcpy(indices, group->indices, copied * sizeof(uint32_t));
  return group->count;
}
uint32_t anvil_markdown_vault_linked_notes(const AnvilMarkdownVaultSnapshot *snapshot, const char *target, uint32_t *indices, uint32_t capacity) {
  if (!snapshot || !target) return 0;
  uint32_t count = 0; const char *target_base = basename_ptr(target); char *target_no_ext = strip_markdown_extension(target_base);
  for (uint32_t i = 0; i < snapshot->note_count; i++) {
    const AnvilMarkdownVaultNoteView *note = &snapshot->notes[i].view; bool match = false;
    for (uint32_t l = 0; !match && l < note->link_count; l++) {
      const char *path = note->links[l].path;
      match = path && (path_match(path, target) || path_match(path, target_base) || (target_no_ext && path_match(path, target_no_ext)));
    }
    if (match) { if (count < capacity) indices[count] = i; count++; }
  }
  SDL_free(target_no_ext); return count;
}
