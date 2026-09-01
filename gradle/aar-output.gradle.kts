import org.gradle.api.GradleException
import org.gradle.api.tasks.Copy
import org.gradle.api.tasks.Delete
import org.gradle.api.tasks.Exec
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.Sync
import java.io.File
import java.security.MessageDigest
import java.util.Properties
import java.util.zip.ZipFile

// Build model and directory layout

/** A Media3 library assembled by the upstream Media3 Gradle build. */
data class Media3Aar(
    val projectPath: String,
    val libraryDirectory: String,
    val sourceName: String,
    val outputName: String,
)

val mediaRoot = rootProject.file("media")
val ffmpegRoot = rootProject.file("ffmpeg")
val outputRoot = rootProject.file(
    providers.gradleProperty("outputDir")
        .orElse(providers.environmentVariable("OUTPUT_DIR"))
        .orElse("OUTPUT")
        .get()
)
val media3MavenRoot = outputRoot.resolve("maven")
val prebuiltFfmpegRoot = rootProject.file(
    providers.gradleProperty("ffmpegPrebuiltDir")
        .orElse(providers.environmentVariable("FFMPEG_PREBUILT_DIR"))
        .orElse("OUTPUT/android-libs")
        .get()
)
val stagedFfmpegRoot = ffmpegRoot.resolve("android-libs")
val ffmpegAvconfigHeader = ffmpegRoot.resolve("libavutil/avconfig.h")
val decoderMainRoot = mediaRoot.resolve("libraries/decoder_ffmpeg/src/main")
val decoderJniRoot = decoderMainRoot.resolve("jni")
val libyuvRoot = decoderJniRoot.resolve("libyuv")
val ffmpegCmakeFile = decoderJniRoot.resolve("CMakeLists.txt")
val ffmpegBuildScript = decoderJniRoot.resolve("build_ffmpeg.sh")
val ffmpegWslBuildScript = rootProject.file("gradle/build-ffmpeg-static-wsl.sh")

val media3Aars = listOf(
    Media3Aar(":lib-common", "common", "lib-common-release.aar", "media3-common-release.aar"),
    Media3Aar(":lib-container", "container", "lib-container-release.aar", "media3-container-release.aar"),
    Media3Aar(":lib-database", "database", "lib-database-release.aar", "media3-database-release.aar"),
    Media3Aar(":lib-datasource", "datasource", "lib-datasource-release.aar", "media3-datasource-release.aar"),
    Media3Aar(
        ":lib-datasource-okhttp",
        "datasource_okhttp",
        "lib-datasource-okhttp-release.aar",
        "media3-datasource-okhttp-release.aar",
    ),
    Media3Aar(":lib-decoder", "decoder", "lib-decoder-release.aar", "media3-decoder-release.aar"),
    Media3Aar(":lib-effect", "effect", "lib-effect-release.aar", "media3-effect-release.aar"),
    Media3Aar(":lib-extractor", "extractor", "lib-extractor-release.aar", "media3-extractor-release.aar"),
    Media3Aar(":lib-exoplayer", "exoplayer", "lib-exoplayer-release.aar", "media3-exoplayer-release.aar"),
    Media3Aar(
        ":lib-exoplayer-hls",
        "exoplayer_hls",
        "lib-exoplayer-hls-release.aar",
        "media3-exoplayer-hls-release.aar",
    ),
    Media3Aar(":lib-session", "session", "lib-session-release.aar", "media3-session-release.aar"),
    Media3Aar(":lib-ui", "ui", "lib-ui-release.aar", "media3-ui-release.aar"),
)
val ffmpegAar = Media3Aar(
    ":lib-decoder-ffmpeg",
    "decoder_ffmpeg",
    "lib-decoder-ffmpeg-release.aar",
    "media3-ffmpeg-decoder-release.aar",
)
val allAars = media3Aars + ffmpegAar
val publishedMedia3ArtifactIds = allAars.associateWith { aar ->
    "media3-${aar.libraryDirectory.replace('_', '-')}"
}
val expectedAbis = listOf("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
val configuredFfmpegArchives = providers.gradleProperty("ffmpegArchives")
    .orElse(providers.environmentVariable("FFMPEG_ARCHIVES"))
val configuredFfmpegDecoders = providers.gradleProperty("ffmpegDecoders")
    .orElse(providers.environmentVariable("FFMPEG_DECODERS"))
val configuredFfmpegStaticMode = providers.gradleProperty("ffmpegStaticMode")
    .orElse(providers.environmentVariable("FFMPEG_STATIC_MODE"))
    .orElse("source")
val configuredSharedFfmpegAar = providers.gradleProperty("jellyfinSharedFfmpegAar")
val isWindows = System.getProperty("os.name").startsWith("Windows", ignoreCase = true)
val cmakeVersion = "3.31.1"
val androidApi = providers.gradleProperty("androidApi")
    .orElse(providers.environmentVariable("ANDROID_API"))
    .orElse("23")
val nativeJobs = providers.gradleProperty("nativeJobs")
    .orElse(providers.environmentVariable("NATIVE_JOBS"))
    .orElse(maxOf(1, Runtime.getRuntime().availableProcessors()).toString())
    .map { value ->
        value.toIntOrNull()?.takeIf { it > 0 }
            ?: throw GradleException("nativeJobs/NATIVE_JOBS must be a positive integer: $value")
    }

// Shared configuration helpers

fun Media3Aar.sourceFile() = mediaRoot.resolve(
    "libraries/$libraryDirectory/buildout/outputs/aar/$sourceName"
)

fun configuredPath(propertyName: String, vararg environmentNames: String): String? {
    val propertyValue = providers.gradleProperty(propertyName).orNull
    if (!propertyValue.isNullOrBlank()) {
        return propertyValue
    }
    for (environmentName in environmentNames) {
        val environmentValue = providers.environmentVariable(environmentName).orNull
        if (!environmentValue.isNullOrBlank()) {
            return environmentValue
        }
    }
    return null
}

fun resolveAndroidSdkRoot(): File? {
    val path = configuredPath("androidSdkPath", "ANDROID_HOME", "ANDROID_SDK_ROOT")
    if (path != null) {
        return rootProject.file(path)
    }
    return System.getenv("LOCALAPPDATA")
        ?.let { File(it, "Android/Sdk") }
        ?.takeIf(File::isDirectory)
}

// Android SDK and NDK discovery

data class InstalledNdk(
    val root: File,
    val revision: String,
)

fun readNdkRevision(ndkRoot: File): String {
    val sourceProperties = ndkRoot.resolve("source.properties")
    val declaredRevision = sourceProperties
        .takeIf(File::isFile)
        ?.useLines { lines ->
            lines.firstNotNullOfOrNull { line ->
                Regex("""^\s*Pkg\.Revision\s*=\s*(.+?)\s*$""")
                    .matchEntire(line)
                    ?.groupValues
                    ?.get(1)
            }
        }
    return declaredRevision?.takeIf(String::isNotBlank) ?: ndkRoot.name
}

fun compareNdkRevisions(left: String, right: String): Int {
    fun numericParts(value: String): List<Long> =
        Regex("""\d+""").findAll(value.substringBefore('-'))
            .map { match -> match.value.toLong() }
            .toList()

    val leftParts = numericParts(left)
    val rightParts = numericParts(right)
    val componentCount = maxOf(leftParts.size, rightParts.size)
    for (index in 0 until componentCount) {
        val leftPart = leftParts.getOrElse(index) { 0L }
        val rightPart = rightParts.getOrElse(index) { 0L }
        if (leftPart != rightPart) {
            return leftPart.compareTo(rightPart)
        }
    }

    // Prefer a stable revision over a preview with the same numeric components.
    val leftIsPreview = '-' in left
    val rightIsPreview = '-' in right
    if (leftIsPreview != rightIsPreview) {
        return if (leftIsPreview) -1 else 1
    }
    return left.compareTo(right, ignoreCase = true)
}

fun isUsableNdkRoot(ndkRoot: File): Boolean =
    ndkRoot.isDirectory &&
        ndkRoot.resolve("build/cmake/android.toolchain.cmake").isFile &&
        ndkRoot.resolve("toolchains/llvm/prebuilt").isDirectory

var cachedAndroidNdkRoot: File? = null

fun resolveAndroidNdkRoot(): File {
    cachedAndroidNdkRoot?.let { return it }

    val requestedVersion = providers.gradleProperty("androidNdkVersion")
        .orElse(providers.environmentVariable("ANDROID_NDK_VERSION"))
        .orNull
        ?.trim()
        ?.takeIf(String::isNotEmpty)

    val explicitNdkPath = configuredPath(
        "androidNdkPath",
        "ANDROID_NDK_PATH",
        "ANDROID_NDK_ROOT",
        "ANDROID_NDK_HOME",
    )
    if (explicitNdkPath != null) {
        val explicitNdk = rootProject.file(explicitNdkPath)
        if (!isUsableNdkRoot(explicitNdk)) {
            throw GradleException(
                "Configured Android NDK is incomplete or does not exist: ${explicitNdk.absolutePath}"
            )
        }
        val explicitVersion = readNdkRevision(explicitNdk)
        if (requestedVersion != null && explicitVersion != requestedVersion) {
            throw GradleException(
                "Repository-pinned Android NDK $requestedVersion does not match " +
                    "$explicitVersion at ${explicitNdk.absolutePath}."
            )
        }
        return explicitNdk.canonicalFile.also { selected ->
            cachedAndroidNdkRoot = selected
            logger.lifecycle("Using configured Android NDK $explicitVersion: ${selected.absolutePath}")
        }
    }

    if (requestedVersion != null) {
        val sdkRoot = resolveAndroidSdkRoot()
            ?: throw GradleException(
                "Android NDK $requestedVersion is pinned by the repository, but no Android SDK is configured. " +
                    "Set ANDROID_HOME or ANDROID_SDK_ROOT."
            )
        val requestedRoot = sdkRoot.resolve("ndk/$requestedVersion")
        if (!isUsableNdkRoot(requestedRoot)) {
            throw GradleException(
                "Repository-pinned Android NDK $requestedVersion is not installed or is incomplete: " +
                    requestedRoot.absolutePath
            )
        }
        return requestedRoot.canonicalFile.also { selected ->
            cachedAndroidNdkRoot = selected
            logger.lifecycle("Using repository-pinned Android NDK $requestedVersion: ${selected.absolutePath}")
        }
    }

    val sdkRoot = resolveAndroidSdkRoot()
        ?: throw GradleException(
            "Set ANDROID_HOME/ANDROID_SDK_ROOT, -PandroidNdkPath, or ANDROID_NDK_PATH."
        )
    val sideBySideRoot = sdkRoot.resolve("ndk")
    val installations = sideBySideRoot.listFiles()
        .orEmpty()
        .asSequence()
        .filter(::isUsableNdkRoot)
        .map { root -> InstalledNdk(root, readNdkRevision(root)) }
        .toList()

    val selectedNdk = installations.maxWithOrNull { left, right ->
        compareNdkRevisions(left.revision, right.revision)
    } ?: sdkRoot.resolve("ndk-bundle")
        .takeIf(::isUsableNdkRoot)
        ?.let { root -> InstalledNdk(root, readNdkRevision(root)) }
        ?: throw GradleException(
            "No usable Android NDK installation was found under ${sideBySideRoot.absolutePath}. " +
                "Install an NDK with SDK Manager or set -PandroidNdkPath/ANDROID_NDK_PATH."
        )

    return selectedNdk.root.canonicalFile.also { selected ->
        cachedAndroidNdkRoot = selected
        logger.lifecycle("Using Android NDK ${selectedNdk.revision}: ${selected.absolutePath}")
    }
}

val selectedAndroidNdkVersion = providers.provider {
    readNdkRevision(resolveAndroidNdkRoot())
}
rootProject.extensions.extraProperties["jellyfinAndroidNdkVersionProvider"] =
    selectedAndroidNdkVersion

// Native host tools

fun resolveCmakeCommand(): String {
    val configuredCommand = configuredPath("cmakePath", "CMAKE")
    if (configuredCommand != null) {
        return configuredCommand
    }
    val executableName = if (isWindows) "cmake.exe" else "cmake"
    val sdkExecutable = resolveAndroidSdkRoot()?.resolve("cmake/$cmakeVersion/bin/$executableName")
    return if (sdkExecutable?.isFile == true) sdkExecutable.absolutePath else executableName
}

fun resolveNinjaCommand(): String {
    val configuredCommand = configuredPath("ninjaPath", "NINJA")
    if (configuredCommand != null) {
        return configuredCommand
    }
    val executableName = if (isWindows) "ninja.exe" else "ninja"
    val sdkExecutable = resolveAndroidSdkRoot()?.resolve("cmake/$cmakeVersion/bin/$executableName")
    return if (sdkExecutable?.isFile == true) sdkExecutable.absolutePath else executableName
}

// FFmpeg configuration and archive discovery

fun normalizeFfmpegArchiveName(value: String): String {
    val token = value.trim()
    if (token.isEmpty()) {
        throw GradleException("FFmpeg archive names must not be empty.")
    }

    val withExtension = if (token.endsWith(".a")) token else "$token.a"
    val archiveName = if (withExtension.startsWith("lib")) withExtension else "lib$withExtension"
    if (!Regex("""lib[A-Za-z0-9_.+-]+\.a""").matches(archiveName)) {
        throw GradleException("Invalid FFmpeg archive name: $value")
    }
    return archiveName
}

fun cmakeTokens(value: String): List<String> = value
    .lineSequence()
    .map { line -> line.substringBefore('#') }
    .joinToString(" ")
    .split(Regex("""[\s;]+"""))
    .map { token -> token.trim().trim('"') }
    .filter { token -> token.isNotEmpty() }

fun cmakeListVariable(contents: String, variableName: String): List<String> {
    val pattern = Regex(
        """(?is)\bset\s*\(\s*${Regex.escape(variableName)}\s+([^)]+)\)"""
    )
    return pattern.find(contents)?.groupValues?.get(1)?.let(::cmakeTokens).orEmpty()
}

fun discoverFfmpegArchivesFromCmake(): List<String> {
    if (!ffmpegCmakeFile.isFile) {
        return emptyList()
    }

    val contents = ffmpegCmakeFile.readText()
    val loopPattern = Regex("""(?is)\bforeach\s*\(\s*ffmpeg_lib\s+([^)]+)\)""")
    return loopPattern.findAll(contents)
        .flatMap { match ->
            val tokens = cmakeTokens(match.groupValues[1])
            val libraries = when {
                tokens.size >= 2 &&
                    tokens[0].equals("IN", ignoreCase = true) &&
                    tokens[1].equals("ITEMS", ignoreCase = true) -> tokens.drop(2)
                tokens.size >= 2 &&
                    tokens[0].equals("IN", ignoreCase = true) &&
                    tokens[1].equals("LISTS", ignoreCase = true) ->
                    tokens.drop(2).flatMap { variable -> cmakeListVariable(contents, variable) }
                tokens.firstOrNull()?.equals("IN", ignoreCase = true) == true -> emptyList()
                else -> tokens
            }
            libraries.asSequence()
        }
        .filter { token ->
            !token.contains('$') &&
                Regex("""[A-Za-z0-9_.+-]+(?:\.a)?""").matches(token)
        }
        .map(::normalizeFfmpegArchiveName)
        .distinct()
        .sorted()
        .toList()
}

fun discoverFfmpegArchivesFromPrebuilts(): List<String> {
    val archives = expectedAbis
        .flatMap { abi ->
            prebuiltFfmpegRoot.resolve(abi)
                .listFiles { file -> file.isFile && file.extension == "a" }
                ?.map { file -> file.name }
                .orEmpty()
        }
        .distinct()
        .sorted()

    if (archives.isEmpty()) {
        throw GradleException(
            "No prebuilt FFmpeg archives were found under ${prebuiltFfmpegRoot.absolutePath}."
        )
    }
    return archives
}

fun resolveRequiredFfmpegArchives(): List<String> {
    val cmakeArchives = discoverFfmpegArchivesFromCmake()
    val configured = configuredFfmpegArchives.orNull
    if (!configured.isNullOrBlank()) {
        val archives = configured
            .split(Regex("""[\s,;]+"""))
            .filter { token -> token.isNotBlank() }
            .map(::normalizeFfmpegArchiveName)
            .distinct()
            .sorted()
        if (archives.isEmpty()) {
            throw GradleException("ffmpegArchives/FFMPEG_ARCHIVES did not contain an archive name.")
        }
        val omittedCmakeArchives = cmakeArchives.filterNot(archives::contains)
        if (omittedCmakeArchives.isNotEmpty()) {
            throw GradleException(
                "ffmpegArchives/FFMPEG_ARCHIVES omits libraries required by the JNI CMake file: " +
                    omittedCmakeArchives.joinToString(", ")
            )
        }
        return archives
    }

    return if (cmakeArchives.isNotEmpty()) {
        cmakeArchives
    } else {
        discoverFfmpegArchivesFromPrebuilts()
    }
}

val defaultFfmpegDecoders = listOf(
    "aac", "mp3", "mp1", "mp2", "ac3", "eac3", "truehd", "dca", "vorbis", "opus",
    "amrnb", "amrwb", "flac", "alac", "pcm_mulaw", "pcm_alaw", "gsm_ms",
    "h264", "hevc", "av1", "vp8", "vp9", "flv", "mpeg1video", "mpeg2video",
    "mpeg4", "msmpeg4v2", "msmpeg4v3", "h263", "vc1", "wmv1", "wmv2", "wmv3",
)

fun resolveFfmpegDecoders(): List<String> {
    val configured = configuredFfmpegDecoders.orNull
    if (configured.isNullOrBlank()) {
        return defaultFfmpegDecoders
    }
    val decoders = configured
        .split(Regex("""[\s,;]+"""))
        .map { decoder -> decoder.trim() }
        .filter { decoder -> decoder.isNotEmpty() }
        .distinct()
    if (decoders.isEmpty()) {
        throw GradleException("ffmpegDecoders/FFMPEG_DECODERS did not contain a decoder name.")
    }
    val invalid = decoders.filterNot { decoder -> Regex("""[A-Za-z0-9_.+-]+""").matches(decoder) }
    if (invalid.isNotEmpty()) {
        throw GradleException("Invalid FFmpeg decoder names: ${invalid.joinToString(", ")}")
    }
    return decoders
}

fun resolveFfmpegStaticMode(): String {
    val mode = configuredFfmpegStaticMode.get().trim().lowercase()
    if (mode !in setOf("source", "prebuilt")) {
        throw GradleException(
            "ffmpegStaticMode/FFMPEG_STATIC_MODE must be 'source' or 'prebuilt', not '$mode'."
        )
    }
    return mode
}

fun resolveWslPath(file: File): String {
    val windowsPath = file.absolutePath.replace('\\', '/')
    val process = try {
        ProcessBuilder("wsl.exe", "wslpath", "-a", windowsPath)
            .start()
    } catch (error: Exception) {
        throw GradleException(
            "Could not start WSL. Install/enable WSL or select prebuilt FFmpeg mode with " +
                "-PffmpegStaticMode=prebuilt.",
            error,
        )
    }
    val output = process.inputStream.bufferedReader().use { reader -> reader.readText() }.trim()
    val errorOutput = process.errorStream.bufferedReader().use { reader -> reader.readText() }.trim()
    val exitCode = process.waitFor()
    if (exitCode != 0 || output.isEmpty()) {
        throw GradleException("Could not convert to a WSL path: ${file.absolutePath}\n$errorOutput")
    }
    return output
}

fun requireHostCommand(command: String, installHint: String) {
    val process = try {
        ProcessBuilder("bash", "-lc", "command -v '$command' >/dev/null 2>&1")
            .redirectErrorStream(true)
            .start()
    } catch (error: Exception) {
        throw GradleException("Could not check for required command '$command'.", error)
    }
    if (process.waitFor() != 0) {
        throw GradleException("Required command '$command' was not found. $installHint")
    }
}

fun ffmpegArchiveFiles(root: File, archiveNames: List<String>): List<File> =
    expectedAbis.flatMap { abi -> archiveNames.map { archive -> root.resolve("$abi/$archive") } }

fun assertFilesExist(files: List<File>, missingMessage: String) {
    val missing = files.filterNot(File::isFile)
    if (missing.isNotEmpty()) {
        throw GradleException(
            buildString {
                appendLine("$missingMessage:")
                missing.forEach { file -> appendLine("  ${file.absolutePath}") }
            }.trimEnd()
        )
    }
}

fun assertFfmpegArchives(root: File, archiveNames: List<String>, description: String) {
    assertFilesExist(
        ffmpegArchiveFiles(root, archiveNames),
        "$description are missing",
    )
}

// Source and artifact metadata

fun resolveFfmpegVersion(directory: File): String {
    for (name in listOf("VERSION", "RELEASE")) {
        val value = directory.resolve(name)
            .takeIf(File::isFile)
            ?.readText()
            ?.lineSequence()
            ?.map { line -> line.trim() }
            ?.firstOrNull { line -> line.isNotEmpty() }
        if (value != null) {
            return value
        }
    }

    val generatedHeader = directory.resolve("libavutil/ffversion.h")
    if (generatedHeader.isFile) {
        val value = Regex(
            """(?m)^\s*#define\s+FFMPEG_VERSION\s+"([^"]+)"\s*$"""
        ).find(generatedHeader.readText())?.groupValues?.get(1)
        if (value != null) {
            return value
        }
    }

    throw GradleException(
        "Could not determine the FFmpeg version from VERSION, RELEASE, or libavutil/ffversion.h " +
            "under ${directory.absolutePath}."
    )
}

fun resolveLibyuvVersion(directory: File): String {
    val versionHeader = directory.resolve("include/libyuv/version.h")
    if (!versionHeader.isFile) {
        throw GradleException(
            "libyuv version header does not exist: ${versionHeader.absolutePath}"
        )
    }

    val version = Regex(
        """(?m)^\s*#define\s+LIBYUV_VERSION\s+([0-9]+)\s*$"""
    ).find(versionHeader.readText())?.groupValues?.get(1)

    return version ?: throw GradleException(
        "Could not read LIBYUV_VERSION from ${versionHeader.absolutePath}."
    )
}

fun resolveGitVersion(directory: File): String {
    if (!directory.isDirectory) {
        throw GradleException("Source directory does not exist: ${directory.absolutePath}")
    }

    val command = listOf(
        "git",
        "-c",
        "safe.directory=*",
        "-C",
        directory.absolutePath,
        "describe",
        "--tags",
        "--always",
        "--abbrev=12",
    )
    val process = try {
        ProcessBuilder(command)
            .redirectErrorStream(true)
            .start()
    } catch (error: Exception) {
        throw GradleException("Could not execute Git for ${directory.absolutePath}.", error)
    }
    val output = process.inputStream.bufferedReader().use { reader -> reader.readText() }.trim()
    val exitCode = process.waitFor()
    if (exitCode != 0 || output.isEmpty()) {
        throw GradleException(
            "Could not determine the source version for ${directory.absolutePath}: $output"
        )
    }
    return output
}

data class SharedFfmpegProvider(
    val aar: File,
    val mavenRoot: File,
    val group: String,
    val artifact: String,
    val version: String,
    val ffmpegVersion: String,
    val commit: String,
    val sha256: String,
)

fun sha256(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
}

fun readSharedFfmpegProvider(): SharedFfmpegProvider? {
    val configured = configuredSharedFfmpegAar.orNull?.trim()?.takeIf(String::isNotEmpty)
        ?: return null
    val configuredFile = File(configured)
    if (configuredFile.isAbsolute) {
        throw GradleException(
            "jellyfinSharedFfmpegAar must be relative to ${rootProject.projectDir.absolutePath}: $configured"
        )
    }
    val aar = rootProject.projectDir.resolve(configured).canonicalFile
    if (!aar.isFile) {
        throw GradleException("Shared FFmpeg provider AAR does not exist: ${aar.absolutePath}")
    }

    val requiredLibraries = listOf(
        "libavcodec.so", "libavdevice.so", "libavfilter.so", "libavformat.so",
        "libavutil.so", "libswresample.so", "libswscale.so",
    )
    val metadataPath = "META-INF/mpv-ffmpeg-android.properties"
    val properties = Properties()
    ZipFile(aar).use { zip ->
        val metadataEntry = zip.getEntry(metadataPath)
            ?: throw GradleException("Shared FFmpeg provider metadata is missing: $metadataPath")
        zip.getInputStream(metadataEntry).use(properties::load)
        expectedAbis.forEach { abi ->
            listOf(
                "headers/$abi/libavcodec/version_major.h",
                "headers/$abi/libavutil/avconfig.h",
            ).forEach { path ->
                if (zip.getEntry(path) == null) {
                    throw GradleException("Shared FFmpeg provider entry is missing: $path")
                }
            }
            requiredLibraries.forEach { library ->
                val path = "jni/$abi/$library"
                if (zip.getEntry(path) == null) {
                    throw GradleException("Shared FFmpeg provider entry is missing: $path")
                }
            }
        }
        if (zip.getEntry("prefab/prefab.json") == null) {
            throw GradleException("Shared FFmpeg provider entry is missing: prefab/prefab.json")
        }
        requiredLibraries.forEach { library ->
            val module = library.removePrefix("lib").removeSuffix(".so")
            val path = "prefab/modules/$module/module.json"
            if (zip.getEntry(path) == null) {
                throw GradleException("Shared FFmpeg provider entry is missing: $path")
            }
        }
    }

    fun requireProperty(name: String, expected: String? = null): String {
        val value = properties.getProperty(name)?.trim().orEmpty()
        if (value.isEmpty()) {
            throw GradleException("Shared FFmpeg provider metadata property is missing: $name")
        }
        if (expected != null && value != expected) {
            throw GradleException(
                "Shared FFmpeg provider metadata $name must be '$expected', not '$value'."
            )
        }
        return value
    }

    val group = requireProperty("group", "io.github.abdallahmehiz")
    val artifact = requireProperty("artifact", "mpv-ffmpeg-android")
    val version = requireProperty("version")
    val ffmpegVersion = requireProperty("ffmpeg_version")
    val commit = requireProperty("ffmpeg_commit")
    require(Regex("""^[0-9]+\.[0-9]+(?:\.[0-9]+)?$""").matches(ffmpegVersion)) {
        "Shared FFmpeg provider FFmpeg version is invalid: $ffmpegVersion"
    }
    require(Regex("""^[0-9a-f]{40}$""").matches(commit)) {
        "Shared FFmpeg provider commit is invalid: $commit"
    }
    require(version == "$ffmpegVersion-thor.${commit.take(12)}") {
        "Shared FFmpeg provider version $version does not match FFmpeg $ffmpegVersion at $commit"
    }
    requireProperty("ndk_version", "29.0.14206865")
    requireProperty("abis", expectedAbis.joinToString(","))
    requireProperty("optimization", "O3,thin-lto,armv7-neon,armv7-thumb,arm64-neon")
    val decoders = requireProperty("decoders").split(',').map(String::trim).toSet()
    val missingDecoders = defaultFfmpegDecoders.filterNot(decoders::contains)
    if (missingDecoders.isNotEmpty()) {
        throw GradleException(
            "Shared FFmpeg provider is missing required decoders: ${missingDecoders.joinToString(", ")}"
        )
    }
    require(aar.name == "$artifact-$version.aar") {
        "Shared FFmpeg provider AAR name does not match its metadata: ${aar.name}"
    }
    val versionDirectory = aar.parentFile
    require(versionDirectory.name == version) {
        "Shared FFmpeg provider AAR is not in its Maven version directory: ${aar.absolutePath}"
    }
    val artifactDirectory = versionDirectory.parentFile
    require(artifactDirectory.name == artifact) {
        "Shared FFmpeg provider AAR is not in its Maven artifact directory: ${aar.absolutePath}"
    }
    var groupDirectory = artifactDirectory.parentFile
    group.split('.').asReversed().forEach { segment ->
        require(groupDirectory.name == segment) {
            "Shared FFmpeg provider AAR is not in its Maven group directory: ${aar.absolutePath}"
        }
        groupDirectory = groupDirectory.parentFile
    }
    val pom = versionDirectory.resolve("$artifact-$version.pom")
    require(pom.isFile) {
        "Shared FFmpeg provider POM does not exist: ${pom.absolutePath}"
    }
    return SharedFfmpegProvider(
        aar,
        groupDirectory,
        group,
        artifact,
        version,
        ffmpegVersion,
        commit,
        sha256(aar),
    )
}

fun resolveGitRevision(directory: File): String {
    if (!directory.isDirectory) {
        throw GradleException("Source directory does not exist: ${directory.absolutePath}")
    }

    val command = listOf(
        "git",
        "-c",
        "safe.directory=*",
        "-C",
        directory.absolutePath,
        "rev-parse",
        "--short=12",
        "HEAD",
    )
    val process = try {
        ProcessBuilder(command)
            .redirectErrorStream(true)
            .start()
    } catch (error: Exception) {
        throw GradleException("Could not execute Git for ${directory.absolutePath}.", error)
    }
    val output = process.inputStream.bufferedReader().use { reader -> reader.readText() }.trim()
    val exitCode = process.waitFor()
    if (exitCode != 0 || !Regex("""[0-9a-f]{12}""").matches(output)) {
        throw GradleException(
            "Could not determine the source revision for ${directory.absolutePath}: $output"
        )
    }
    return output
}

fun writeTextIfChanged(file: File, contents: String) {
    file.parentFile.mkdirs()
    if (!file.isFile || file.readText() != contents) {
        file.writeText(contents)
    }
}

fun taskSuffix(value: String): String = value
    .split('-', '_')
    .joinToString("") { part -> part.replaceFirstChar { it.uppercaseChar() } }

// Lazily resolved build inputs

val cmakeRequiredFfmpegArchives = providers.provider {
    discoverFfmpegArchivesFromCmake().ifEmpty {
        throw GradleException(
            "Could not resolve FFmpeg JNI archives from ${ffmpegCmakeFile.absolutePath}. " +
                "Run update-repo.sh or update-repo.bat so both Media3 patches are applied."
        )
    }
}
val requiredFfmpegArchives = providers.provider { resolveRequiredFfmpegArchives() }
val ffmpegDecoders = providers.provider { resolveFfmpegDecoders() }
val ffmpegStaticMode = providers.provider { resolveFfmpegStaticMode() }
val sharedFfmpegEnabled = configuredSharedFfmpegAar.isPresent
val sharedFfmpegProvider = providers.provider {
    checkNotNull(readSharedFfmpegProvider()) {
        "jellyfinSharedFfmpegAar was not supplied."
    }
}
val sharedFfmpegRoot = layout.buildDirectory.dir("shared-ffmpeg-provider")
val stagedFfmpegArchiveFiles = requiredFfmpegArchives.map { archives ->
    ffmpegArchiveFiles(stagedFfmpegRoot, archives)
}
val prebuiltFfmpegArchiveFiles = requiredFfmpegArchives.map { archives ->
    ffmpegArchiveFiles(prebuiltFfmpegRoot, archives)
}
val outputFfmpegArchiveFiles = requiredFfmpegArchives.map { archives ->
    ffmpegArchiveFiles(outputRoot.resolve("android-libs"), archives)
}
val ffmpegBuildStamp = stagedFfmpegRoot.resolve(".jellyfin-source-build.txt")
val ffmpegCachedAvconfigHeader = stagedFfmpegRoot.resolve(".jellyfin-avconfig.h")
val artifactVersion = providers.provider {
    rootProject.version.toString()
        .trim()
        .takeUnless { value -> value.isEmpty() || value == "unspecified" }
        ?: throw GradleException(
            "The artifact version is unspecified. Set -Pjellyfin.version or JELLYFIN_VERSION."
        )
}
val mediaSourceVersion = providers.provider { resolveGitVersion(mediaRoot) }
val mediaSourceRevision = providers.provider { resolveGitRevision(mediaRoot) }
val media3ReleaseVersion = providers.provider {
    val versionCatalog = mediaRoot.resolve("gradle/libs.versions.toml")
    requireNotNull(
        Regex("""(?m)^\s*releaseVersion\s*=\s*"([^"]+)"\s*$""")
            .find(versionCatalog.readText())
            ?.groupValues
            ?.get(1)
    ) {
        "releaseVersion was not found in ${versionCatalog.absolutePath}"
    }
}
val ffmpegVersion = providers.provider { resolveFfmpegVersion(ffmpegRoot) }
val ffmpegSourceRevision = providers.provider { resolveGitVersion(ffmpegRoot) }
val libyuvVersion = providers.provider { resolveLibyuvVersion(libyuvRoot) }
val libyuvSourceRevision = providers.provider { resolveGitVersion(libyuvRoot) }

val media3VersionFile = outputRoot.resolve("version-media3.txt")
val ffmpegVersionFile = outputRoot.resolve("version-ffmpeg.txt")
val libyuvVersionFile = outputRoot.resolve("version-libyuv.txt")
val allVersionFiles = listOf(media3VersionFile, ffmpegVersionFile, libyuvVersionFile)

// Output housekeeping and validation

val cleanAarOutput by tasks.registering(Delete::class) {
    group = "build"
    description = "Removes previously generated Media3 Maven artifacts, AARs, FFmpeg, and version files from OUTPUT."
    delete(media3MavenRoot)
    delete(allAars.map { outputRoot.resolve(it.outputName) })
    delete(fileTree(outputRoot) { include("version-*.txt") })
}

val validateFfmpegArchiveResolution by tasks.registering {
    group = "verification"
    description = "Validates the dynamic FFmpeg archive list against the patched JNI CMake file."
    inputs.property("cmakeRequiredFfmpegArchives", cmakeRequiredFfmpegArchives)
    inputs.property("resolvedFfmpegArchives", requiredFfmpegArchives)

    doLast {
        val cmakeArchives = cmakeRequiredFfmpegArchives.get()
        val resolvedArchives = requiredFfmpegArchives.get()
        val omitted = cmakeArchives.filterNot(resolvedArchives::contains)
        if (omitted.isNotEmpty()) {
            throw GradleException(
                "Resolved FFmpeg archive list omits JNI link inputs: ${omitted.joinToString(", ")}"
            )
        }
        logger.lifecycle(
            "FFmpeg JNI archives resolved from ${ffmpegCmakeFile.absolutePath}: " +
                cmakeArchives.joinToString(", ")
        )
    }
}

// FFmpeg source and prebuilt pipelines

val buildFfmpegStaticLibraries by tasks.registering(Exec::class) {
    group = "build"
    description = "Builds FFmpeg static libraries from the checked-out FFmpeg source when required."
    dependsOn(validateFfmpegArchiveResolution)
    inputs.property("ffmpegSourceRevision", ffmpegSourceRevision)
    inputs.property("androidApi", androidApi)
    inputs.property("ffmpegDecoders", ffmpegDecoders)
    inputs.property("requiredFfmpegArchives", requiredFfmpegArchives)
    inputs.property("androidNdkPath", providers.provider { resolveAndroidNdkRoot().canonicalPath })
    inputs.file(ffmpegBuildScript)
        .withPropertyName("ffmpegBuildScript")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    if (isWindows) {
        inputs.file(ffmpegWslBuildScript)
            .withPropertyName("ffmpegWslBuildScript")
            .withPathSensitivity(PathSensitivity.RELATIVE)
    }
    outputs.files(stagedFfmpegArchiveFiles)
    outputs.file(ffmpegBuildStamp)
    outputs.file(ffmpegCachedAvconfigHeader)

    doFirst {
        if (!ffmpegRoot.isDirectory) {
            throw GradleException("FFmpeg source is missing: ${ffmpegRoot.absolutePath}")
        }
        if (!ffmpegBuildScript.isFile) {
            throw GradleException(
                "The patched Media3 FFmpeg build script is missing: ${ffmpegBuildScript.absolutePath}"
            )
        }
        if (!decoderJniRoot.resolve("ffmpeg").exists()) {
            throw GradleException(
                "Media3 FFmpeg source link is missing. Run update-repo.sh or update-repo.bat first."
            )
        }

        val ndkRoot = resolveAndroidNdkRoot()
        val decoders = ffmpegDecoders.get()
        project.delete(stagedFfmpegRoot)
        stagedFfmpegRoot.mkdirs()

        logger.lifecycle(
            "Building FFmpeg ${ffmpegSourceRevision.get()} for Android with decoders: " +
                decoders.joinToString(", ")
        )

        if (isWindows) {
            if (!ffmpegWslBuildScript.isFile) {
                throw GradleException(
                    "The WSL FFmpeg helper is missing: ${ffmpegWslBuildScript.absolutePath}"
                )
            }
            commandLine(
                "wsl.exe",
                "bash",
                resolveWslPath(ffmpegWslBuildScript),
                resolveWslPath(decoderMainRoot),
                selectedAndroidNdkVersion.get(),
                resolveWslPath(ffmpegBuildScript),
                androidApi.get(),
                *decoders.toTypedArray(),
            )
        } else {
            requireHostCommand("make", "Install GNU make before building FFmpeg from source.")
            val linuxToolchain = ndkRoot.resolve("toolchains/llvm/prebuilt/linux-x86_64/bin")
            if (!linuxToolchain.isDirectory) {
                throw GradleException(
                    "Linux NDK LLVM toolchain is missing: ${linuxToolchain.absolutePath}"
                )
            }
            commandLine(
                "bash",
                ffmpegBuildScript.absolutePath,
                decoderMainRoot.absolutePath,
                ndkRoot.absolutePath,
                "linux-x86_64",
                androidApi.get(),
                *decoders.toTypedArray(),
            )
        }
    }

    doLast {
        val archives = requiredFfmpegArchives.get()
        assertFfmpegArchives(
            stagedFfmpegRoot,
            archives,
            "FFmpeg static libraries built from source",
        )
        if (!ffmpegAvconfigHeader.isFile) {
            throw GradleException(
                "FFmpeg did not generate its public config header: ${ffmpegAvconfigHeader.absolutePath}"
            )
        }
        ffmpegCachedAvconfigHeader.parentFile.mkdirs()
        ffmpegAvconfigHeader.copyTo(ffmpegCachedAvconfigHeader, overwrite = true)
        writeTextIfChanged(
            ffmpegBuildStamp,
            "source_revision=${ffmpegSourceRevision.get()}\n" +
                "ndk_version=${selectedAndroidNdkVersion.get()}\n" +
                "android_api=${androidApi.get()}\n" +
                "decoders=${ffmpegDecoders.get().joinToString(",")}\n" +
                "archives=${archives.joinToString(",")}\n",
        )
    }
}

val validatePrebuiltFfmpegStaticLibraries by tasks.registering {
    group = "verification"
    description = "Validates user-supplied FFmpeg static libraries before staging them."
    dependsOn(validateFfmpegArchiveResolution)
    inputs.property("requiredFfmpegArchives", requiredFfmpegArchives)
    inputs.files(prebuiltFfmpegArchiveFiles)
        .withPropertyName("prebuiltFfmpegArchives")
        .withPathSensitivity(PathSensitivity.RELATIVE)

    doLast {
        val sourcePath = prebuiltFfmpegRoot.canonicalFile.toPath()
        val stagingPath = stagedFfmpegRoot.canonicalFile.toPath()
        if (
            sourcePath == stagingPath ||
            sourcePath.startsWith(stagingPath) ||
            stagingPath.startsWith(sourcePath)
        ) {
            throw GradleException(
                "The prebuilt FFmpeg source and staging directories must not overlap: " +
                    "${prebuiltFfmpegRoot.absolutePath} and ${stagedFfmpegRoot.absolutePath}"
            )
        }
        assertFfmpegArchives(
            prebuiltFfmpegRoot,
            requiredFfmpegArchives.get(),
            "Required prebuilt FFmpeg archives",
        )
    }
}

val stagePrebuiltFfmpegStaticLibraries by tasks.registering(Sync::class) {
    group = "build"
    description = "Stages validated prebuilt FFmpeg archives when prebuilt mode is selected."
    dependsOn(validatePrebuiltFfmpegStaticLibraries)

    from(prebuiltFfmpegRoot) {
        include(*expectedAbis.map { abi -> "$abi/*.a" }.toTypedArray())
        eachFile {
            if (name !in requiredFfmpegArchives.get()) {
                exclude()
            }
        }
    }
    into(stagedFfmpegRoot)
    includeEmptyDirs = false
    inputs.property("requiredFfmpegArchives", requiredFfmpegArchives)
}

val stageFfmpegStaticLibraries by tasks.registering {
    group = "build"
    description = "Builds or stages FFmpeg static libraries and verifies all JNI link inputs."
    dependsOn(
        if (ffmpegStaticMode.get() == "source") {
            buildFfmpegStaticLibraries
        } else {
            stagePrebuiltFfmpegStaticLibraries
        }
    )

    doLast {
        val archives = requiredFfmpegArchives.get()
        assertFfmpegArchives(
            stagedFfmpegRoot,
            archives,
            "Staged FFmpeg static libraries",
        )
        logger.lifecycle(
            "Using FFmpeg static mode '${ffmpegStaticMode.get()}' and archives: " +
                archives.joinToString(", ")
        )
    }
}

val exportFfmpegStaticLibraries by tasks.registering(Sync::class) {
    group = "build"
    description = "Copies the verified FFmpeg static libraries into OUTPUT/android-libs."
    dependsOn(stageFfmpegStaticLibraries)

    from(stagedFfmpegRoot) {
        include(*expectedAbis.map { abi -> "$abi/*.a" }.toTypedArray())
        eachFile {
            if (name !in requiredFfmpegArchives.get()) {
                exclude()
            }
        }
    }
    into(outputRoot.resolve("android-libs"))
    includeEmptyDirs = false
    inputs.property("requiredFfmpegArchives", requiredFfmpegArchives)
    outputs.files(outputFfmpegArchiveFiles)

    doFirst {
        assertFfmpegArchives(
            stagedFfmpegRoot,
            requiredFfmpegArchives.get(),
            "FFmpeg static libraries selected for OUTPUT",
        )
    }
}

// Native headers and libyuv

val stageFfmpegConfigHeader by tasks.registering {
    group = "build"
    description = "Restores the FFmpeg config header generated with the libraries, " +
        "or writes the prebuilt fallback."
    dependsOn(stageFfmpegStaticLibraries)

    val fallbackHeaderText = """
        #ifndef AVUTIL_AVCONFIG_H
        #define AVUTIL_AVCONFIG_H
        #define AV_HAVE_BIGENDIAN 0
        #define AV_HAVE_FAST_UNALIGNED 0
        #endif
    """.trimIndent() + System.lineSeparator()

    inputs.property("ffmpegStaticMode", ffmpegStaticMode)
    inputs.property("fallbackContents", fallbackHeaderText)
    inputs.files(providers.provider {
        if (ffmpegStaticMode.get() == "source") listOf(ffmpegCachedAvconfigHeader) else emptyList()
    })
        .withPropertyName("sourceBuiltAvconfigHeader")
        .withPathSensitivity(PathSensitivity.NONE)
    outputs.file(ffmpegAvconfigHeader)

    doLast {
        ffmpegAvconfigHeader.parentFile.mkdirs()
        if (ffmpegStaticMode.get() == "source") {
            if (!ffmpegCachedAvconfigHeader.isFile) {
                throw GradleException(
                    "Cached FFmpeg config header is missing: ${ffmpegCachedAvconfigHeader.absolutePath}"
                )
            }
            ffmpegCachedAvconfigHeader.copyTo(ffmpegAvconfigHeader, overwrite = true)
        } else {
            writeTextIfChanged(ffmpegAvconfigHeader, fallbackHeaderText)
        }
    }
}

val stagedLibyuvArchiveFiles = expectedAbis.map { abi ->
    libyuvRoot.resolve("android-libs/$abi/libyuv.so")
}
val libyuvSourceFiles = fileTree(libyuvRoot) {
    exclude(".git/**")
    exclude("build-*/**")
    exclude("android-libs/**")
    exclude("out/**")
}

val libyuvArchiveTasks = expectedAbis.map { abi ->
    val suffix = taskSuffix(abi)
    val nativeBuildDirectory = libyuvRoot.resolve("build-$abi")
    val cmakeCache = nativeBuildDirectory.resolve("CMakeCache.txt")
    val outputArchive = nativeBuildDirectory.resolve("libyuv.so")
    val stagedArchiveDirectory = libyuvRoot.resolve("android-libs/$abi")
    val stagedArchive = stagedArchiveDirectory.resolve("libyuv.so")

    val configureTask = tasks.register<Exec>("configureLibyuv$suffix") {
        group = "build"
        description = "Configures libyuv for $abi when its CMake inputs change."

        inputs.property("abi", abi)
        inputs.property("androidApi", androidApi)
        inputs.property("cmakeCommand", providers.provider { resolveCmakeCommand() })
        inputs.property("ninjaCommand", providers.provider { resolveNinjaCommand() })
        inputs.property("ndkPath", providers.provider { resolveAndroidNdkRoot().canonicalPath })
        inputs.property("releaseFlags", "-O3 -flto=thin")
        inputs.property("interproceduralOptimizationRelease", true)
        outputs.file(cmakeCache)

        doFirst {
            if (!libyuvRoot.isDirectory) {
                throw GradleException(
                    "libyuv source is missing. Run update-repo.sh or update-repo.bat first."
                )
            }
            val toolchainFile = resolveAndroidNdkRoot()
                .resolve("build/cmake/android.toolchain.cmake")
            commandLine(
                resolveCmakeCommand(),
                "-S", libyuvRoot.absolutePath,
                "-B", nativeBuildDirectory.absolutePath,
                "-G", "Ninja",
                "-DCMAKE_MAKE_PROGRAM=${resolveNinjaCommand()}",
                "-DCMAKE_TOOLCHAIN_FILE=${toolchainFile.absolutePath}",
                "-DANDROID_ABI=$abi",
                "-DANDROID_PLATFORM=${androidApi.get()}",
                "-DCMAKE_BUILD_TYPE=Release",
                "-DCMAKE_C_FLAGS_RELEASE=-O3 -flto=thin",
                "-DCMAKE_CXX_FLAGS_RELEASE=-O3 -flto=thin",
                "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=ON",
            )
        }
    }

    val compileTask = tasks.register<Exec>("compileLibyuv$suffix") {
        group = "build"
        description = "Incrementally builds libyuv for $abi."
        dependsOn(configureTask)

        inputs.files(libyuvSourceFiles)
            .withPropertyName("libyuvSources")
            .withPathSensitivity(PathSensitivity.RELATIVE)
        inputs.file(cmakeCache)
            .withPropertyName("cmakeCache")
            .withPathSensitivity(PathSensitivity.NONE)
        outputs.file(outputArchive)

        doFirst {
            commandLine(
                resolveCmakeCommand(),
                "--build", nativeBuildDirectory.absolutePath,
                "--target", "yuv_shared",
                "--parallel", nativeJobs.get().toString(),
            )
        }
    }

    tasks.register<Sync>("stageLibyuv$suffix") {
        group = "build"
        description = "Stages the libyuv archive for $abi only when it changes."
        dependsOn(compileTask)
        from(outputArchive)
        into(stagedArchiveDirectory)

        doFirst {
            if (!outputArchive.isFile) {
                throw GradleException("libyuv archive was not produced: ${outputArchive.absolutePath}")
            }
        }

        doLast {
            if (!stagedArchive.isFile) {
                throw GradleException("libyuv archive was not staged: ${stagedArchive.absolutePath}")
            }
        }
    }
}

val buildLibyuv by tasks.registering {
    group = "build"
    description = "Builds or reuses the shared libyuv dependency required by the renderer patch."
    dependsOn(libyuvArchiveTasks)

    doLast {
        assertFilesExist(
            stagedLibyuvArchiveFiles,
            "libyuv did not produce all required archives",
        )
    }
}

// Native dependency orchestration

val prepareFfmpegSourceDependencies by tasks.registering {
    group = "build"
    description = "Builds and verifies FFmpeg JNI inputs from the selected FFmpeg source revision."
    dependsOn(buildFfmpegStaticLibraries, stageFfmpegConfigHeader)

    doLast {
        assertFfmpegArchives(
            stagedFfmpegRoot,
            cmakeRequiredFfmpegArchives.get(),
            "Source-built FFmpeg JNI archives",
        )
        logger.lifecycle("FFmpeg source dependencies are ready.")
    }
}

val prepareFfmpegPrebuiltDependencies by tasks.registering {
    group = "build"
    description = "Stages and verifies externally built FFmpeg JNI inputs."
    dependsOn(stagePrebuiltFfmpegStaticLibraries, stageFfmpegConfigHeader)

    doLast {
        assertFfmpegArchives(
            stagedFfmpegRoot,
            cmakeRequiredFfmpegArchives.get(),
            "Prebuilt FFmpeg JNI archives",
        )
        logger.lifecycle("FFmpeg prebuilt dependencies are ready.")
    }
}

val prepareNativeDependencies by tasks.registering {
    group = "build"
    description = "Prepares FFmpeg and libyuv before any nested Media3 native build starts."
    dependsOn(buildLibyuv)
    dependsOn(
        if (sharedFfmpegEnabled) {
            stageSharedFfmpegProvider
        } else if (ffmpegStaticMode.get() == "source") {
            prepareFfmpegSourceDependencies
        } else {
            prepareFfmpegPrebuiltDependencies
        }
    )

    doLast {
        if (sharedFfmpegEnabled) {
            val provider = checkNotNull(sharedFfmpegProvider.get())
            require(sharedFfmpegRoot.get().asFile.isDirectory) {
                "Shared FFmpeg provider was not staged."
            }
            logger.lifecycle(
                "Native dependencies use shared FFmpeg " +
                    "${provider.group}:${provider.artifact}:${provider.version}."
            )
        } else {
            assertFfmpegArchives(
                stagedFfmpegRoot,
                cmakeRequiredFfmpegArchives.get(),
                "Prepared FFmpeg JNI archives",
            )
            logger.lifecycle(
                "Native dependencies use static FFmpeg mode '${ffmpegStaticMode.get()}'."
            )
        }
        assertFilesExist(
            stagedLibyuvArchiveFiles,
            "Prepared libyuv JNI archives are missing",
        )
    }
}

// Nested Media3 build and exported artifacts

val assemblePatchedMedia3Aars by tasks.registering(Exec::class) {
    group = "build"
    description = "Publishes patched Media3 modules to a local Maven repository and assembles " +
        "the FFmpeg decoder with the Media3 Gradle wrapper."
    dependsOn(cleanAarOutput, prepareNativeDependencies)
    mustRunAfter(
        cleanAarOutput,
        prepareFfmpegSourceDependencies,
        prepareFfmpegPrebuiltDependencies,
    )

    workingDir(mediaRoot)

    val mediaGradleArguments = buildList {
        addAll(allAars.map { "${it.projectPath}:publishReleasePublicationToMavenRepository" })
        add("-PmavenRepo=${media3MavenRoot.absolutePath}")
        add("-Pmedia3MavenVersion=${media3MavenVersion.get()}")
        add("-PjellyfinAndroidNdkVersion=${selectedAndroidNdkVersion.get()}")
        if (sharedFfmpegEnabled) {
            val provider = sharedFfmpegProvider.get()
            add("-PjellyfinSharedFfmpegRoot=${sharedFfmpegRoot.get().asFile.absolutePath}")
            add("-PjellyfinSharedFfmpegMavenRepo=${provider.mavenRoot.absolutePath}")
            add("-PjellyfinSharedFfmpegGroup=${provider.group}")
            add("-PjellyfinSharedFfmpegArtifact=${provider.artifact}")
            add("-PjellyfinSharedFfmpegVersion=${provider.version}")
        }
    }
    if (isWindows) {
        commandLine(
            "cmd.exe",
            "/d",
            "/c",
            "gradlew.bat",
            *mediaGradleArguments.toTypedArray(),
        )
    } else {
        commandLine(
            mediaRoot.resolve("gradlew").absolutePath,
            *mediaGradleArguments.toTypedArray(),
        )
    }

    doFirst {
        if (sharedFfmpegEnabled) {
            checkNotNull(sharedFfmpegProvider.get())
        } else {
            assertFfmpegArchives(
                stagedFfmpegRoot,
                cmakeRequiredFfmpegArchives.get(),
                "FFmpeg JNI link archives declared by CMake",
            )
            if (!ffmpegAvconfigHeader.isFile) {
                throw GradleException(
                    "FFmpeg JNI config header is missing: ${ffmpegAvconfigHeader.absolutePath}"
                )
            }
        }
        val wrapper = mediaRoot.resolve(if (isWindows) "gradlew.bat" else "gradlew")
        if (!wrapper.isFile) {
            throw GradleException("Media3 Gradle wrapper was not found: ${wrapper.absolutePath}")
        }
        val androidSdkRoot = resolveAndroidSdkRoot()
            ?: throw GradleException("Set ANDROID_HOME/ANDROID_SDK_ROOT or -PandroidSdkPath to the Android SDK.")
        if (!androidSdkRoot.isDirectory) {
            throw GradleException("Android SDK directory does not exist: ${androidSdkRoot.absolutePath}")
        }
        val androidNdkRoot = resolveAndroidNdkRoot()
        environment("ANDROID_HOME", androidSdkRoot.absolutePath)
        environment("ANDROID_SDK_ROOT", androidSdkRoot.absolutePath)
        environment("ANDROID_NDK_PATH", androidNdkRoot.absolutePath)
        environment("ANDROID_NDK_ROOT", androidNdkRoot.absolutePath)
        environment("ANDROID_NDK_HOME", androidNdkRoot.absolutePath)
        if (!decoderJniRoot.resolve("ffmpeg").exists()) {
            throw GradleException(
                "Media3 FFmpeg source link is missing. Run update-repo.sh or update-repo.bat first."
            )
        }
    }
}

val buildMedia3Aars by tasks.registering(Copy::class) {
    group = "build"
    description = "Builds custom Media3 and FFmpeg release AARs into OUTPUT."
    dependsOn(prepareNativeDependencies, assemblePatchedMedia3Aars)
    if (!sharedFfmpegEnabled) {
        dependsOn(exportFfmpegStaticLibraries)
    }

    inputs.property("artifactVersion", artifactVersion)
    inputs.property("mediaSourceVersion", mediaSourceVersion)
    inputs.property("mediaSourceRevision", mediaSourceRevision)
    inputs.property("media3MavenVersion", media3MavenVersion)
    inputs.property("ffmpegVersion", ffmpegVersion)
    inputs.property("ffmpegSourceRevision", ffmpegSourceRevision)
    inputs.property("androidNdkVersion", selectedAndroidNdkVersion)
    inputs.property("libyuvVersion", libyuvVersion)
    inputs.property("libyuvSourceRevision", libyuvSourceRevision)
    outputs.files(allVersionFiles)

    into(outputRoot)
    allAars.forEach { aar ->
        from(aar.sourceFile()) {
            rename { aar.outputName }
        }
    }

    doFirst {
        val missing = allAars.map { it.sourceFile() }.filterNot { it.isFile }
        if (missing.isNotEmpty()) {
            throw GradleException(
                buildString {
                    appendLine("Expected AAR outputs were not produced:")
                    missing.forEach { appendLine("  ${it.absolutePath}") }
                }
            )
        }
        outputRoot.mkdirs()
        val retainedVersionFiles = allVersionFiles.map { it.canonicalFile }.toSet()
        outputRoot.listFiles { file ->
            file.isFile && file.name.startsWith("version-") && file.extension == "txt"
        }?.filterNot { file -> file.canonicalFile in retainedVersionFiles }
            ?.forEach { legacyFile ->
                if (!legacyFile.delete()) {
                    throw GradleException("Could not remove legacy version file: ${legacyFile.absolutePath}")
                }
            }
    }

    doLast {
        val programVersion = artifactVersion.get()
        writeTextIfChanged(
            media3VersionFile,
            "artifact_version=$programVersion\n" +
                "source_version=${mediaSourceVersion.get()}\n" +
                "maven_version=${media3MavenVersion.get()}\n",
        )
        writeTextIfChanged(
            ffmpegVersionFile,
            "artifact_version=$programVersion\n" +
                if (!sharedFfmpegEnabled) {
                    "mode=static\n" +
                        "version=${ffmpegVersion.get()}\n" +
                        "source_revision=${ffmpegSourceRevision.get()}\n"
                } else {
                    val provider = sharedFfmpegProvider.get()
                    "mode=shared\n" +
                        "version=${provider.ffmpegVersion}\n" +
                        "provider_version=${provider.version}\n" +
                        "provider=${provider.group}:${provider.artifact}:${provider.version}\n" +
                        "source_revision=${provider.commit}\n" +
                        "sha256=${provider.sha256}\n"
                } +
                "ndk_version=${selectedAndroidNdkVersion.get()}\n",
        )
        writeTextIfChanged(
            libyuvVersionFile,
            "version=${libyuvVersion.get()}\nsource_revision=${libyuvSourceRevision.get()}\n",
        )

        logger.lifecycle("Built Media3 AARs:")
        allAars.forEach { logger.lifecycle("  ${outputRoot.resolve(it.outputName)}") }
        logger.lifecycle("Published Media3 Maven repository:")
        logger.lifecycle("  $media3MavenRoot")
        logger.lifecycle("Wrote version files:")
        allVersionFiles.forEach { versionFile -> logger.lifecycle("  $versionFile") }
    }
}

val verifySharedFfmpegProvider by tasks.registering {
    group = "verification"
    description = "Validates the optional shared FFmpeg provider AAR."
    configuredSharedFfmpegAar.orNull?.let { configured ->
        inputs.property("jellyfinSharedFfmpegAar", configured)
    }

    doLast {
        if (!sharedFfmpegEnabled) {
            logger.quiet("Shared FFmpeg provider not supplied; Media3 static FFmpeg mode selected.")
        } else {
            val provider = sharedFfmpegProvider.get()
            logger.quiet(
                "Validated shared FFmpeg provider ${provider.group}:${provider.artifact}:${provider.version} " +
                    "(${provider.sha256})."
            )
        }
    }
}

val stageSharedFfmpegProvider by tasks.registering(Sync::class) {
    group = "build"
    description = "Stages the validated shared FFmpeg provider for the nested Media3 native build."
    dependsOn(verifySharedFfmpegProvider)
    onlyIf { sharedFfmpegEnabled }
    from(configuredSharedFfmpegAar.map {
        val provider = checkNotNull(sharedFfmpegProvider.get())
        zipTree(provider.aar)
    })
    into(sharedFfmpegRoot)
}

val verifyPublishedMedia3Repository by tasks.registering {
    group = "verification"
    description = "Verifies the fork-specific Media3 Maven repository and its checksums."

    inputs.dir(media3MavenRoot)
    inputs.file(media3VersionFile)

    doLast {
        val version = media3MavenVersion.get()
        require(
            Regex("""^\d+\.\d+\.\d+-thor\.[0-9a-f]{12}(?:-shared\.[0-9a-f]{12})?$""")
                .matches(version)
        ) {
            "Patched Media3 must use a fork-specific Maven version, not '$version'."
        }

        publishedMedia3ArtifactIds.values.forEach { artifactId ->
            val artifactDirectory = media3MavenRoot.resolve("androidx/media3/$artifactId/$version")
            require(artifactDirectory.isDirectory) {
                "Missing published Media3 module: $artifactDirectory"
            }
            require(artifactDirectory.resolve("$artifactId-$version.pom").isFile) {
                "Missing POM for $artifactId:$version"
            }
            require(artifactDirectory.resolve("$artifactId-$version.module").isFile) {
                "Missing Gradle module metadata for $artifactId:$version"
            }
            require(artifactDirectory.resolve("$artifactId-$version.aar").isFile) {
                "Missing AAR for $artifactId:$version"
            }
        }

        val digestAlgorithms = mapOf(
            "md5" to "MD5",
            "sha1" to "SHA-1",
            "sha256" to "SHA-256",
            "sha512" to "SHA-512",
        )
        fileTree(media3MavenRoot).matching {
            digestAlgorithms.keys.forEach { extension -> include("**/*.$extension") }
        }.files.forEach { checksumFile ->
            val extension = checksumFile.extension
            val target = File(checksumFile.absolutePath.removeSuffix(".$extension"))
            require(target.isFile) { "Checksum target is missing: $target" }
            val digest = java.security.MessageDigest.getInstance(digestAlgorithms.getValue(extension))
            val actual = digest.digest(target.readBytes()).joinToString("") { byte -> "%02x".format(byte) }
            val expected = checksumFile.readText().trim()
            require(actual == expected) {
                "Checksum mismatch for $target: expected $expected, got $actual"
            }
        }
    }
}

buildMedia3Aars.configure {
    finalizedBy(verifyPublishedMedia3Repository)
}
val media3MavenVersion = media3ReleaseVersion.zip(mediaSourceRevision) { releaseVersion, revision ->
    val baseVersion = "$releaseVersion-thor.$revision"
    if (sharedFfmpegEnabled) {
        "$baseVersion-shared.${sharedFfmpegProvider.get().commit.take(12)}"
    } else {
        baseVersion
    }
}
