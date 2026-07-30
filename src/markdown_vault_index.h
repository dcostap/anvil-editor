#ifndef ANVIL_MARKDOWN_VAULT_INDEX_H
#define ANVIL_MARKDOWN_VAULT_INDEX_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "project_file_manifest.h"

typedef struct AnvilMarkdownVaultSnapshot AnvilMarkdownVaultSnapshot;
typedef bool (*AnvilMarkdownVaultCancelledFn)(void *userdata);

typedef struct AnvilMarkdownVaultBuildSpec {
  AnvilProjectFileManifestSnapshot *manifest;
  const AnvilMarkdownVaultSnapshot *previous;
  uint64_t shallow_note_bytes;
  AnvilMarkdownVaultCancelledFn cancelled;
  void *cancel_userdata;
} AnvilMarkdownVaultBuildSpec;

typedef struct AnvilMarkdownVaultHeadingView {
  const char *text;
  const char *slug;
  const char *path_text;
  const char *path_slug;
  uint32_t line;
  uint32_t level;
  const char **preview;
  uint32_t preview_count;
} AnvilMarkdownVaultHeadingView;

typedef struct AnvilMarkdownVaultBlockView {
  const char *id;
  uint32_t line;
  uint32_t col1;
  uint32_t col2;
  const char **preview;
  uint32_t preview_count;
} AnvilMarkdownVaultBlockView;

typedef struct AnvilMarkdownVaultLinkView {
  const char *kind;
  const char *raw_target;
  const char *path;
  const char *alias;
  const char *subtarget;
  bool block_subtarget;
  uint32_t source_line;
  uint32_t source_col1;
  uint32_t source_col2;
} AnvilMarkdownVaultLinkView;

typedef struct AnvilMarkdownVaultMetadataView {
  const char *key;
  const char **values;
  uint32_t value_count;
  bool list;
} AnvilMarkdownVaultMetadataView;

typedef struct AnvilMarkdownVaultNoteView {
  const char *absolute_path;
  const char *relative_path;
  const char *relative_no_extension;
  const char *display_name;
  uint64_t size;
  int64_t modified;
  bool shallow;
  uint32_t fact_signature;
  const char **aliases;
  uint32_t alias_count;
  const char **tags;
  uint32_t tag_count;
  const char **preview;
  uint32_t preview_count;
  AnvilMarkdownVaultHeadingView *headings;
  uint32_t heading_count;
  AnvilMarkdownVaultBlockView *blocks;
  uint32_t block_count;
  AnvilMarkdownVaultLinkView *links;
  uint32_t link_count;
  AnvilMarkdownVaultMetadataView *metadata;
  uint32_t metadata_count;
} AnvilMarkdownVaultNoteView;

typedef struct AnvilMarkdownVaultAttachmentView {
  const char *absolute_path;
  const char *relative_path;
  const char *display_name;
  uint64_t size;
  int64_t modified;
} AnvilMarkdownVaultAttachmentView;

typedef struct AnvilMarkdownVaultSummary {
  uint64_t note_count;
  uint64_t attachment_count;
  uint64_t headings;
  uint64_t blocks;
  uint64_t links;
  uint64_t bytes_read;
  uint64_t shallow_notes;
  uint64_t failed_notes;
  uint64_t reused_notes;
  uint64_t rebuilt_notes;
  double build_ms;
} AnvilMarkdownVaultSummary;

AnvilMarkdownVaultSnapshot *anvil_markdown_vault_snapshot_build(const AnvilMarkdownVaultBuildSpec *spec, char **error);
AnvilMarkdownVaultSnapshot *anvil_markdown_vault_overlay_build(
  const char *absolute_path, const char *relative_path,
  const char *text, size_t text_len, uint64_t shallow_note_bytes,
  AnvilMarkdownVaultCancelledFn cancelled, void *cancel_userdata, char **error
);
void anvil_markdown_vault_snapshot_retain(AnvilMarkdownVaultSnapshot *snapshot);
void anvil_markdown_vault_snapshot_release(AnvilMarkdownVaultSnapshot *snapshot);
void anvil_markdown_vault_snapshot_summary(const AnvilMarkdownVaultSnapshot *snapshot, AnvilMarkdownVaultSummary *summary);
bool anvil_markdown_vault_note_at(const AnvilMarkdownVaultSnapshot *snapshot, uint32_t index, AnvilMarkdownVaultNoteView *view);
bool anvil_markdown_vault_attachment_at(const AnvilMarkdownVaultSnapshot *snapshot, uint32_t index, AnvilMarkdownVaultAttachmentView *view);
bool anvil_markdown_vault_note_lookup(const AnvilMarkdownVaultSnapshot *snapshot, const char *path, uint32_t *index);
bool anvil_markdown_vault_attachment_lookup(const AnvilMarkdownVaultSnapshot *snapshot, const char *path, uint32_t *index);
uint32_t anvil_markdown_vault_resolve_notes(const AnvilMarkdownVaultSnapshot *snapshot, const char *target, uint32_t *indices, uint32_t capacity);
uint32_t anvil_markdown_vault_resolve_attachments(const AnvilMarkdownVaultSnapshot *snapshot, const char *target, uint32_t *indices, uint32_t capacity);
uint32_t anvil_markdown_vault_linked_notes(const AnvilMarkdownVaultSnapshot *snapshot, const char *target, uint32_t *indices, uint32_t capacity);

#endif
