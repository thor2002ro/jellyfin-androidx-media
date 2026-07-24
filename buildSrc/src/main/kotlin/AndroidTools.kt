import org.gradle.api.GradleException
import org.gradle.api.Project
import java.io.File
import java.util.Properties

/** An Android NDK installation and the package revision reported by it. */
data class AndroidNdkInstallation(
    val version: String,
    val directory: File,
)

private const val ANDROID_NDK_CACHE_KEY = "jellyfin.androidNdkInstallation"

private fun Project.configuredValue(propertyName: String, vararg environmentNames: String): String? {
    val propertyValue = findProperty(propertyName)?.toString()
    if (!propertyValue.isNullOrBlank()) {
        return propertyValue
    }
    return environmentNames.asSequence()
        .mapNotNull { environmentName -> System.getenv(environmentName) }
        .firstOrNull { value -> value.isNotBlank() }
}

private fun Project.localProperty(name: String): String? {
    val localProperties = rootProject.file("local.properties")
    if (!localProperties.isFile) {
        return null
    }

    val properties = Properties()
    localProperties.inputStream().use { input -> properties.load(input) }
    return properties.getProperty(name)?.takeIf { value -> value.isNotBlank() }
}

private fun Project.requireDirectory(path: String, description: String): File {
    val directory = rootProject.file(path)
    if (!directory.isDirectory) {
        throw GradleException("$description does not exist: ${directory.absolutePath}")
    }
    return directory.canonicalFile
}

/** Resolves the Android SDK from Gradle properties, environment variables, local.properties, or OS defaults. */
fun Project.detectAndroidSdkRoot(): File? {
    val configuredPath = configuredValue("androidSdkPath", "ANDROID_SDK_ROOT", "ANDROID_HOME")
    if (configuredPath != null) {
        return requireDirectory(configuredPath, "Configured Android SDK directory")
    }

    val localSdkPath = localProperty("sdk.dir")
    if (localSdkPath != null) {
        return requireDirectory(localSdkPath, "Android SDK directory from local.properties")
    }

    val userHome = System.getProperty("user.home")?.let { path -> File(path) }
    val candidates = buildList {
        System.getenv("LOCALAPPDATA")?.let { localAppData -> add(File(localAppData, "Android/Sdk")) }
        userHome?.let { home ->
            add(File(home, "Library/Android/sdk"))
            add(File(home, "Android/Sdk"))
        }
    }
    return candidates.firstOrNull(File::isDirectory)?.canonicalFile
}

private fun readNdkVersion(directory: File): String? {
    val sourceProperties = directory.resolve("source.properties")
    if (!sourceProperties.isFile) {
        return null
    }

    val properties = Properties()
    sourceProperties.inputStream().use { input -> properties.load(input) }
    return properties.getProperty("Pkg.Revision")?.trim()?.takeIf(String::isNotEmpty)
}

private fun ndkInstallation(directory: File, fallbackVersion: String? = null): AndroidNdkInstallation? {
    if (!directory.isDirectory) {
        return null
    }
    val version = readNdkVersion(directory) ?: fallbackVersion
    return version?.takeIf(String::isNotBlank)?.let { detectedVersion ->
        AndroidNdkInstallation(detectedVersion, directory.canonicalFile)
    }
}

private fun compareRevisionStrings(left: String, right: String): Int {
    val numberPattern = Regex("""\d+""")
    val leftNumbers = numberPattern.findAll(left).map { match -> match.value.toLong() }.toList()
    val rightNumbers = numberPattern.findAll(right).map { match -> match.value.toLong() }.toList()
    val count = maxOf(leftNumbers.size, rightNumbers.size)
    for (index in 0 until count) {
        val comparison = (leftNumbers.getOrElse(index) { 0L })
            .compareTo(rightNumbers.getOrElse(index) { 0L })
        if (comparison != 0) {
            return comparison
        }
    }

    val leftQualifier = left.dropWhile { character -> character.isDigit() || character == '.' }
    val rightQualifier = right.dropWhile { character -> character.isDigit() || character == '.' }
    if (leftQualifier.isEmpty() != rightQualifier.isEmpty()) {
        return if (leftQualifier.isEmpty()) 1 else -1
    }
    return left.compareTo(right)
}

private fun Project.findAndroidNdk(): AndroidNdkInstallation {
    val configuredVersion = configuredValue(
        "androidNdkVersion",
        "ANDROID_NDK_VERSION",
        "NDK_VERSION",
        "NDK_VER",
    )
    val explicitNdkPath = configuredValue(
        "androidNdkPath",
        "ANDROID_NDK_PATH",
        "ANDROID_NDK_ROOT",
        "ANDROID_NDK_HOME",
        "ANDROID_NDK",
    ) ?: localProperty("ndk.dir")

    if (explicitNdkPath != null) {
        val directory = requireDirectory(explicitNdkPath, "Configured Android NDK directory")
        val installation = ndkInstallation(directory, configuredVersion)
            ?: throw GradleException(
                "Could not detect the Android NDK version from ${directory.resolve("source.properties").absolutePath}. " +
                    "Set -PandroidNdkVersion=<version> when using an NDK without source.properties."
            )
        if (configuredVersion != null && installation.version != configuredVersion) {
            throw GradleException(
                "Configured Android NDK version $configuredVersion does not match " +
                    "${installation.version} at ${directory.absolutePath}."
            )
        }
        return installation
    }

    val sdkRoot = detectAndroidSdkRoot()
        ?: throw GradleException(
            "Android SDK was not found. Set ANDROID_SDK_ROOT/ANDROID_HOME, sdk.dir in local.properties, " +
                "or -PandroidNdkPath=<path>."
        )
    val sideBySideRoot = sdkRoot.resolve("ndk")
    val installed = sideBySideRoot.listFiles(File::isDirectory)
        .orEmpty()
        .mapNotNull { directory -> ndkInstallation(directory, directory.name) }

    if (configuredVersion != null) {
        return installed.firstOrNull { installation -> installation.version == configuredVersion }
            ?: throw GradleException(
                "Android NDK $configuredVersion was not found under ${sideBySideRoot.absolutePath}."
            )
    }

    val latest = installed.maxWithOrNull(
        Comparator { left, right -> compareRevisionStrings(left.version, right.version) }
    )
    if (latest != null) {
        return latest
    }

    val legacyInstallation = ndkInstallation(sdkRoot.resolve("ndk-bundle"))
    if (legacyInstallation != null) {
        return legacyInstallation
    }

    throw GradleException(
        "No Android NDK installation was found under ${sideBySideRoot.absolutePath}. " +
            "Install an NDK or set -PandroidNdkPath=<path>."
    )
}

/** Detects and caches the NDK installation shared by all Android and native build tasks. */
fun Project.detectAndroidNdk(): AndroidNdkInstallation {
    val root = rootProject
    return synchronized(root) {
        val extraProperties = root.extensions.extraProperties
        if (extraProperties.has(ANDROID_NDK_CACHE_KEY)) {
            return@synchronized extraProperties.get(ANDROID_NDK_CACHE_KEY) as AndroidNdkInstallation
        }

        val installation = root.findAndroidNdk()
        extraProperties.set(ANDROID_NDK_CACHE_KEY, installation)
        installation
    }
}
