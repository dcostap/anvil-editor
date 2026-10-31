package io.github.dcostap.anvil

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.sp

/** A styled range in UTF-16 units. A marker's owner is the index of its element. */
class MarkdownSpan(val kind: Int, val start: Int, val end: Int, val owner: Int) {
    companion object {
        const val BOLD = 7
        const val WIKILINK = 8
        const val MARKER = 9
    }
}

object MarkdownStyles {
    init {
        System.loadLibrary("anvil_companion")
    }

    @JvmStatic
    private external fun scan(text: String): IntArray?

    fun spans(text: String): List<MarkdownSpan> {
        val items = scan(text) ?: return emptyList()
        return List(items.size / 4) { i ->
            MarkdownSpan(items[i * 4], items[i * 4 + 1], items[i * 4 + 2], items[i * 4 + 3])
        }
    }
}

private val headingSizes = listOf(30.sp, 26.sp, 23.sp, 21.sp, 19.sp, 18.sp)
private val linkColor = Color(0xFF2F6FDE)
private val hidden = SpanStyle(fontSize = 0.01.sp, color = Color.Transparent, letterSpacing = 0.sp)

/**
 * Live Preview without offset mapping: the text stays the same, and markers are invisible
 * while the selection is outside their element. The keyboard so sees the real text.
 */
class LivePreview(private val spans: List<MarkdownSpan>, private val selection: TextRange) : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        val styled = AnnotatedString.Builder(text)
        for (span in spans) {
            if (span.end > text.length) continue
            when (span.kind) {
                in 1..6 -> styled.addStyle(
                    SpanStyle(fontSize = headingSizes[span.kind - 1], fontWeight = FontWeight.Bold), span.start, span.end
                )
                MarkdownSpan.BOLD -> styled.addStyle(SpanStyle(fontWeight = FontWeight.Bold), span.start, span.end)
                MarkdownSpan.WIKILINK -> styled.addStyle(SpanStyle(color = linkColor), span.start, span.end)
            }
        }
        // Markers come last, so they win over the styles of their elements.
        for (span in spans) {
            if (span.kind != MarkdownSpan.MARKER || span.end > text.length) continue
            val element = spans.getOrNull(span.owner) ?: continue
            val editing = selection.min <= element.end && selection.max >= element.start
            if (!editing) styled.addStyle(hidden, span.start, span.end)
        }
        return TransformedText(styled.toAnnotatedString(), OffsetMapping.Identity)
    }
}
