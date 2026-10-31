package io.github.dcostap.anvil

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

internal val NOTE = """# Notas del día

Un **niño** pidió una canción. El año que viene vamos a [[Andalucía|viajar al sur]].

## Ideas

Escribe aquí con **Gboard**, con deslizamiento y acentos: á é í ó ú ñ ü ¿? ¡! 🎉

Enlace simple: [[Mañana]]

## Lista

""" + (1..40).joinToString("\n") { "- Tarea $it" } + "\n"

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { NoteEditor() }
    }
}

@Composable
private fun NoteEditor() {
    val state = rememberTextFieldState(NOTE)
    LaunchedEffect(state) {
        // Read these lines with `adb logcat -s AnvilEditor`.
        snapshotFlow { "selection=${state.selection} composition=${state.composition} length=${state.text.length}" }
            .collect { Log.d("AnvilEditor", it) }
    }
    // The note scrolls outside the text field, and the padding is outside it too.
    // So the field is as tall as its text, and its coordinates are its text layout's.
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.White)
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 16.dp)
    ) {
        BasicTextField(
            state = state,
            outputTransformation = LivePreview(),
            textStyle = TextStyle(fontSize = 18.sp, lineHeight = 26.sp, color = Color(0xFF1F2328)),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}
