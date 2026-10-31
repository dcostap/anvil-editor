package io.github.dcostap.anvil

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private const val NOTE = """# Notas del día

Un **niño** pidió una canción. El año que viene vamos a [[Andalucía|viajar al sur]].

## Ideas

Escribe aquí con **Gboard**, con deslizamiento y acentos: á é í ó ú ñ ü ¿? ¡! 🎉

Enlace simple: [[Mañana]]
"""

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { NoteEditor() }
    }
}

@androidx.compose.runtime.Composable
private fun NoteEditor() {
    var value by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(NOTE)) }
    val spans = remember(value.text) { MarkdownStyles.spans(value.text) }
    val preview = remember(spans, value.selection) { LivePreview(spans, value.selection) }
    BasicTextField(
        value = value,
        onValueChange = {
            // The Gboard test reads these lines with `adb logcat -s AnvilEditor`.
            Log.d("AnvilEditor", "selection=${it.selection} composition=${it.composition} length=${it.text.length}")
            value = it
        },
        visualTransformation = preview,
        textStyle = TextStyle(fontSize = 18.sp, lineHeight = 26.sp, color = Color(0xFF1F2328)),
        modifier = Modifier
            .fillMaxSize()
            .background(Color.White)
            .safeDrawingPadding()
            .padding(horizontal = 20.dp, vertical = 16.dp),
    )
}
