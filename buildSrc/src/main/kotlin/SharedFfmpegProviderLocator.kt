import java.io.File

enum class SharedFfmpegProviderSource {
    EXPLICIT,
    DISCOVERED,
    NONE,
}

data class SharedFfmpegProviderSelection(
    val aar: File?,
    val source: SharedFfmpegProviderSource,
)

fun selectSharedFfmpegProvider(
    projectDirectory: File,
    configuredPath: String?,
): SharedFfmpegProviderSelection {
    val explicitPath = configuredPath?.trim()?.takeIf(String::isNotEmpty)
    if (explicitPath != null) {
        return SharedFfmpegProviderSelection(
            projectDirectory.resolve(explicitPath).canonicalFile,
            SharedFfmpegProviderSource.EXPLICIT,
        )
    }

    val artifactRoot = projectDirectory.parentFile.resolve(
        "mpv-android-lib/OUTPUT/maven/io/github/abdallahmehiz/mpv-ffmpeg-android"
    )
    val discovered = artifactRoot
        .takeIf(File::isDirectory)
        ?.walkTopDown()
        ?.filter { file ->
            file.isFile &&
                file.name.startsWith("mpv-ffmpeg-android-") &&
                file.extension == "aar"
        }
        ?.maxWithOrNull(compareBy<File>({ it.lastModified() }, { it.absolutePath }))
        ?.canonicalFile

    return if (discovered != null) {
        SharedFfmpegProviderSelection(discovered, SharedFfmpegProviderSource.DISCOVERED)
    } else {
        SharedFfmpegProviderSelection(null, SharedFfmpegProviderSource.NONE)
    }
}
