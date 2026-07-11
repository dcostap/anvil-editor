# Markdown reference links and footnote baseline

## Reference links

Markdown Live Preview resolves parser-confirmed full, collapsed, and shortcut CommonMark reference links against parser-confirmed definitions in the same current semantic snapshot.

- Labels are matched case-insensitively with collapsed whitespace.
- The first definition for a normalized label wins, matching CommonMark behavior.
- Destinations pass through the ordinary Markdown link resolution, status, POI, modifier-click, and navigation paths.
- Inactive links show their label while preserving exact source columns.
- Definition labels and destinations remain source-preserving styled text.
- Missing, malformed, multiline, or capture-bound-overflow cases remain raw rather than using a textual guess.
- Touching a reference-link line uses safe whole-line reveal because Tree-sitter can interpret bracket syntax inside other constructs as shortcut references.

The per-view definition cache is generation keyed and rebuilt only from bounded semantic queries.

## Footnotes

The selected Live Preview support level is source-preserving presentation, consistent with the plan's Obsidian compatibility decision:

- parser-confirmed `[^label]` references and semantically confirmed definition markers are styled as footnotes;
- footnotes are not treated as URL reference links;
- definition bodies remain editable source;
- inline-footnote rendering is left to Reading view;
- Live Preview does not synthesize bottom-of-document footnote widgets or renumber source.

This avoids inventing navigation or layout behavior that the current parser backend does not model reliably while keeping normal footnote authoring legible.
