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
    "stagePrebuiltFfmpegStaticLibraries",
    "validateFfmpegArchiveResolution",
    "verifyPublishedMedia3Repository",
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

// AAR output tasks launch Media3's own Gradle wrapper. Avoid configuring the
// same upstream projects in this build as well; normal library tasks still get
// the complete patched module graph.
if (!isAarOutputBuild) {
    apply(from = File("library_settings.gradle.kts"))
    include(":media3-ffmpeg-decoder")
}
