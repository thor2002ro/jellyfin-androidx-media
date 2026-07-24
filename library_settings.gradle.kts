val mediaRootDir = file(System.getenv("ANDROIDX_MEDIA_ROOT") ?: "media")
val modulePrefix = ":androidx-media-"

gradle.extra["androidxMediaModulePrefix"] = modulePrefix
if (!gradle.extra.has("androidxMediaSettingsDir")) {
    gradle.extra["androidxMediaSettingsDir"] = mediaRootDir.canonicalPath
}

data class Media3Module(
    val name: String,
    val libraryDirectory: String,
    val optional: Boolean = false,
)

fun includeMedia3Module(module: Media3Module) {
    val projectDir = mediaRootDir.resolve("libraries/${module.libraryDirectory}")
    if (module.optional && !projectDir.isDirectory) {
        return
    }

    val projectPath = "$modulePrefix${module.name}"
    include(projectPath)
    project(projectPath).projectDir = projectDir
}

// Keep each Gradle project beside its upstream directory. The optional flag is
// explicit because inspector_frame is not present in every supported revision.
listOf(
    Media3Module("lib-common", "common"),
    Media3Module("lib-container", "container"),
    Media3Module("lib-exoplayer", "exoplayer"),
    Media3Module("lib-exoplayer-dash", "exoplayer_dash"),
    Media3Module("lib-database", "database"),
    Media3Module("lib-datasource", "datasource"),
    Media3Module("lib-decoder", "decoder"),
    Media3Module("lib-decoder-ffmpeg", "decoder_ffmpeg"),
    Media3Module("lib-extractor", "extractor"),
    Media3Module("lib-effect", "effect"),
    Media3Module("lib-inspector", "inspector"),
    Media3Module("lib-inspector-frame", "inspector_frame", optional = true),
    Media3Module("lib-muxer", "muxer"),
    Media3Module("lib-transformer", "transformer"),
    Media3Module("test-utils-robolectric", "test_utils_robolectric"),
    Media3Module("test-data", "test_data"),
    Media3Module("test-utils", "test_utils"),
).forEach { module -> includeMedia3Module(module) }
