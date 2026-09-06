val aarOutputTasks = setOf(
    "assemblePatchedMedia3Aars",
    "buildFfmpegStaticLibraries",
    "buildLibyuv",
    "buildMedia3Aars",
    "cleanAarOutput",
    "exportFfmpegStaticLibraries",
    "prepareFfmpegPrebuiltDependencies",
    "prepareFfmpegSourceDependencies",
    "prepareNativeDependencies",
    "stageFfmpegConfigHeader",
    "stageFfmpegStaticLibraries",
    "stageSharedFfmpegProvider",
    "stagePrebuiltFfmpegStaticLibraries",
    "validateFfmpegArchiveResolution",
    "verifyPublishedMedia3Repository",
    "verifySharedFfmpegProvider",
    "validatePrebuiltFfmpegStaticLibraries",
)
val aarOutputTaskPrefixes = listOf(
    "configureLibyuv",
    "compileLibyuv",
    "stageLibyuv",
)

fun String.shortTaskName() = substringAfterLast(":")

val isAarOutputBuild = gradle.startParameter.taskNames.any { requestedTask ->
    val taskName = requestedTask.shortTaskName()
    taskName in aarOutputTasks || aarOutputTaskPrefixes.any { prefix -> taskName.startsWith(prefix) }
}
val diagnosticTasks = setOf("help", "projects", "properties", "tasks")
val isHelpOnly = gradle.startParameter.taskNames.isEmpty() ||
    gradle.startParameter.taskNames.all { requestedTask -> requestedTask.shortTaskName() in diagnosticTasks }

// AAR output tasks launch Media3's own Gradle wrapper. Avoid configuring the
// same upstream projects in this build as well; normal library tasks still get
// the complete patched module graph.
if (!isAarOutputBuild && !isHelpOnly) {
    apply(from = File("library_settings.gradle.kts"))
    include(":media3-ffmpeg-decoder")
}
