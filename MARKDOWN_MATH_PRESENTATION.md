# Markdown math presentation

Implemented as the Phase 7 styled-source math slice.

Markdown Live Preview presents parser-confirmed inline and display LaTeX as editable source rather than pretending to provide mathematical layout. Every source character and source column is retained; math ranges use the first-party math color, code font, and background. Multiline display ranges style each covered source line through the same semantic snapshot.

Touching a math construct reveals the ordinary raw Editor path for the entire semantic construct. Source Mode remains the whole-view escape hatch. Incomplete delimiters, parser failures, capture overflow, code, HTML, and other excluded contexts remain raw.

No runtime web renderer, remote script, MathJax process, or HTML surface is introduced. True rendered math still requires the bundled/native TeX layout strategy and security review specified in `MARKDOWN_LIVE_EDITOR_PLAN.md`; until then, this source treatment is the intentional supported behavior.

Focused UI regression coverage verifies inline math, multiline display math, first-party styling, exact source text, and active-construct reveal.
