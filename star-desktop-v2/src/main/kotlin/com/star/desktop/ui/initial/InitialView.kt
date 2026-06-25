package com.star.desktop.ui.initial

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.awtTransferable
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import java.awt.datatransfer.DataFlavor
import java.io.File

/** The startup screen (macOS `StartupView`/`InitialView`): open actions, a drop zone, recent files. */
@Composable
fun InitialView(vm: AppViewModel, modifier: Modifier = Modifier) {
    val recent by vm.recentFiles.collectAsState()

    Box(modifier.fillMaxSize().background(StarColors.appBackground), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier.widthIn(max = 560.dp).padding(40.dp),
        ) {
            Text("Star", color = StarColors.textPrimary, fontSize = 40.sp, fontWeight = FontWeight.Light)
            Text("Nighttime Timelapse Airplane Remover", color = StarColors.textSecondary, fontSize = 13.sp)
            OutlinedButton(onClick = vm::openInfoDialog) { Text("ⓘ  About Star") }

            DropZone(vm = vm, onOpenSequence = { open(vm, OpenKind.SEQUENCE) })

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(
                    onClick = { open(vm, OpenKind.SEQUENCE) },
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                ) { Text("Open Image Sequence…") }
                OutlinedButton(onClick = { open(vm, OpenKind.VIDEO) }) { Text("Open Video…") }
                OutlinedButton(onClick = { open(vm, OpenKind.CONFIG) }) { Text("Resume…") }
            }

            if (recent.isNotEmpty()) {
                Spacer(Modifier.height(4.dp))
                Text("Recent", color = StarColors.textSecondary, fontSize = 12.sp, modifier = Modifier.fillMaxWidth())
                RecentFilesList(
                    recent = recent,
                    onOpen = { path -> openPath(vm, path) },
                    onRemove = vm::removeRecent,
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class)
@Composable
private fun DropZone(vm: AppViewModel, onOpenSequence: () -> Unit) {
    var isHovering by remember { mutableStateOf(false) }
    val target = remember(vm) {
        object : DragAndDropTarget {
            override fun onEntered(event: DragAndDropEvent) { isHovering = true }
            override fun onExited(event: DragAndDropEvent) { isHovering = false }
            override fun onEnded(event: DragAndDropEvent) { isHovering = false }
            override fun onDrop(event: DragAndDropEvent): Boolean {
                isHovering = false
                val files = event.droppedFiles()
                if (files.isEmpty()) return false
                handleDroppedFiles(vm, files)
                return true
            }
        }
    }
    Box(
        Modifier
            .fillMaxWidth()
            .height(160.dp)
            .clip(StarShapes.card)
            .border(
                2.dp,
                SolidColor(if (isHovering) StarColors.accent else StarColors.textDisabled),
                StarShapes.card,
            )
            .background(StarColors.sidePanel.copy(alpha = if (isHovering) 0.55f else 0.35f))
            .clickable(onClick = onOpenSequence)
            // Accept every drag; the actual file extraction + validation happens in onDrop.
            .dragAndDropTarget(shouldStartDragAndDrop = { true }, target = target),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "Drop an image sequence folder, video, or config.json here\n(or click to choose a folder)",
            color = StarColors.textSecondary,
            fontSize = 13.sp,
        )
    }
}

/** Pull the dropped file list out of the desktop AWT transferable, or empty if it isn't a file drag. */
@OptIn(ExperimentalComposeUiApi::class)
private fun DragAndDropEvent.droppedFiles(): List<File> = try {
    val transferable = awtTransferable
    if (transferable.isDataFlavorSupported(DataFlavor.javaFileListFlavor)) {
        @Suppress("UNCHECKED_CAST")
        (transferable.getTransferData(DataFlavor.javaFileListFlavor) as? List<File>).orEmpty()
    } else {
        emptyList()
    }
} catch (t: Throwable) {
    emptyList()
}

/** Open the dropped files, routing them via [resolveDrop] (mirrors macOS `InitialView.handleDrop`). */
private fun handleDroppedFiles(vm: AppViewModel, files: List<File>) {
    val action = resolveDrop(files) ?: return
    when (action.kind) {
        OpenKind.SEQUENCE -> vm.openSequence(action.path)
        OpenKind.VIDEO -> vm.openVideo(action.path)
        OpenKind.CONFIG -> vm.openConfig(action.path)
    }
}

@Composable
private fun RecentFilesList(recent: List<String>, onOpen: (String) -> Unit, onRemove: (String) -> Unit) {
    LazyColumn(
        modifier = Modifier.fillMaxWidth().heightInCapped(),
        contentPadding = PaddingValues(vertical = 2.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        items(recent, key = { it }) { path ->
            val file = File(path)
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(4.dp))
                    .background(StarColors.sidePanel.copy(alpha = 0.4f))
                    .clickable { onOpen(path) }
                    .padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(file.name, color = StarColors.textPrimary, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(file.parent ?: path, color = StarColors.textDisabled, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Spacer(Modifier.width(8.dp))
                Box(
                    Modifier.size(20.dp).clip(RoundedCornerShape(10.dp)).clickable { onRemove(path) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text("✕", color = StarColors.textDisabled, fontSize = 12.sp)
                }
            }
        }
    }
}

private fun open(vm: AppViewModel, kind: OpenKind) {
    val path = when (kind) {
        OpenKind.SEQUENCE -> chooseDirectory()
        OpenKind.VIDEO -> chooseFile("Open Video")
        OpenKind.CONFIG -> chooseFile("Resume from config.json")
    } ?: return
    when (kind) {
        OpenKind.SEQUENCE -> vm.openSequence(path)
        OpenKind.VIDEO -> vm.openVideo(path)
        OpenKind.CONFIG -> vm.openConfig(path)
    }
}

private fun openPath(vm: AppViewModel, path: String) {
    when (inferOpenKind(path)) {
        OpenKind.SEQUENCE -> vm.openSequence(path)
        OpenKind.VIDEO -> vm.openVideo(path)
        OpenKind.CONFIG -> vm.openConfig(path)
    }
}

private fun Modifier.heightInCapped(): Modifier = this.then(Modifier.height(220.dp))
