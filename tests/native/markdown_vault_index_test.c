#include "markdown_vault_index.h"

#include <SDL3/SDL.h>
#include <stdio.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #expr); return 1; } } while (0)
static bool write_file(const char *path, const char *text) { FILE *f = fopen(path, "wb"); if (!f) return false; bool ok = fwrite(text, 1, strlen(text), f) == strlen(text); fclose(f); return ok; }
static bool cancel_now(void *p) { (void)p; return true; }

int main(void) {
  CHECK(SDL_Init(0));
  char root[256], note_path[320], source_path[320], image_path[320];
  SDL_snprintf(root, sizeof(root), "markdown-vault-native-%llu", (unsigned long long)SDL_GetTicksNS());
  CHECK(SDL_CreateDirectory(root));
  SDL_snprintf(note_path, sizeof(note_path), "%s/Note.md", root);
  SDL_snprintf(source_path, sizeof(source_path), "%s/Source.md", root);
  SDL_snprintf(image_path, sizeof(image_path), "%s/image.png", root);
  CHECK(write_file(note_path,
    "---\naliases: [\"Alias, One\", Second]\ntags: [#tag, other]\n---\n"
    "# Parent\nbody\n## Child\ntext ^block-id\n[[Source#Heading|source]]\n![image](image.png)\n"));
  CHECK(write_file(source_path, "# Heading\n[[Note]]\n"));
  CHECK(write_file(image_path, "png"));
  AnvilProjectFileManifestBuildSpec manifest_spec = { .root = root };
  char *error = NULL;
  AnvilProjectFileManifestSnapshot *manifest = anvil_project_file_manifest_build(&manifest_spec, &error);
  CHECK(manifest != NULL);
  AnvilMarkdownVaultBuildSpec spec = { .manifest = manifest, .shallow_note_bytes = 512 * 1024 };
  AnvilMarkdownVaultSnapshot *snapshot = anvil_markdown_vault_snapshot_build(&spec, &error);
  CHECK(snapshot != NULL);
  AnvilMarkdownVaultSummary summary; anvil_markdown_vault_snapshot_summary(snapshot, &summary);
  CHECK(summary.note_count == 2 && summary.attachment_count == 1);
  CHECK(summary.headings == 3 && summary.blocks == 1 && summary.links == 3);
  uint32_t index = 0; CHECK(anvil_markdown_vault_note_lookup(snapshot, "Note", &index));
  AnvilMarkdownVaultNoteView note; CHECK(anvil_markdown_vault_note_at(snapshot, index, &note));
  CHECK(note.alias_count == 2 && strcmp(note.aliases[0], "Alias, One") == 0);
  CHECK(note.tag_count == 2 && strcmp(note.tags[0], "tag") == 0);
  CHECK(note.heading_count == 2 && strcmp(note.headings[1].path_slug, "parent#child") == 0);
  CHECK(strcmp(note.headings[0].normalized_text, "parent") == 0);
  CHECK(note.block_count == 1 && strcmp(note.blocks[0].id, "block-id") == 0);
  uint32_t matches[4];
  CHECK(anvil_markdown_vault_resolve_notes(snapshot, "Alias, One", matches, 4) == 1);
  CHECK(anvil_markdown_vault_resolve_attachments(snapshot, "image.png", matches, 4) == 1);
  CHECK(anvil_markdown_vault_linked_notes(snapshot, "Note.md", matches, 4) == 1);
  CHECK(anvil_markdown_vault_completion_candidates(snapshot,
    ANVIL_MARKDOWN_VAULT_COMPLETION_NOTES, "Alias", 0, matches, 4) == 1);
  CHECK(anvil_markdown_vault_completion_candidates(snapshot,
    ANVIL_MARKDOWN_VAULT_COMPLETION_HEADINGS, "does-not-exist", 0, matches, 4) == 0);
  spec.previous = snapshot;
  AnvilMarkdownVaultSnapshot *reused = anvil_markdown_vault_snapshot_build(&spec, &error);
  CHECK(reused != NULL);
  anvil_markdown_vault_snapshot_summary(reused, &summary);
  CHECK(summary.reused_notes == 2 && summary.rebuilt_notes == 0 && summary.bytes_read == 0);
  anvil_markdown_vault_snapshot_release(reused);
  spec.previous = NULL;
  anvil_markdown_vault_snapshot_release(snapshot);

  spec.cancelled = cancel_now; snapshot = anvil_markdown_vault_snapshot_build(&spec, &error);
  CHECK(snapshot == NULL && error && strcmp(error, "cancelled") == 0); SDL_free(error);
  anvil_project_file_manifest_release(manifest);
  SDL_RemovePath(note_path); SDL_RemovePath(source_path); SDL_RemovePath(image_path); SDL_RemovePath(root);
  SDL_Quit(); return 0;
}
