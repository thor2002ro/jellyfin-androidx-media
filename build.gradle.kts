import com.android.build.gradle.LibraryExtension
import org.gradle.api.provider.Provider

plugins {
    id("io.github.gradle-nexus.publish-plugin") version "2.0.0"
}

buildscript {
    repositories {
        mavenCentral()
        google()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.13.2")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.3.0")
    }
}

val mediaGroup = "org.jellyfin.media3"
val minimumAndroidSdk = 23

allprojects {
    group = mediaGroup
    version = createVersion()

    repositories {
        mavenCentral()
        google()
    }

    afterEvaluate {
        val android = extensions.findByType(LibraryExtension::class.java) ?: return@afterEvaluate

        // aar-output.gradle.kts selects one usable NDK for the entire build.
        // Reuse that value so every Android library is configured consistently.
        @Suppress("UNCHECKED_CAST")
        val selectedNdkVersion = rootProject.extensions.extraProperties
            .get("jellyfinAndroidNdkVersionProvider") as Provider<String>

        android.defaultConfig.minSdk = minimumAndroidSdk
        android.ndkVersion = selectedNdkVersion.get()
    }
}

// Add Sonatype publishing repository
nexusPublishing {
    repositories.sonatype {
        nexusUrl.set(uri("https://ossrh-staging-api.central.sonatype.com/service/local/"))
        snapshotRepositoryUrl.set(uri("https://central.sonatype.com/repository/maven-snapshots/"))

        username.set(getProperty("ossrh.username"))
        password.set(getProperty("ossrh.password"))
    }

    useStaging.set(project.provider { project.version.toString() != SNAPSHOT_VERSION })
}

tasks.wrapper {
    distributionType = Wrapper.DistributionType.ALL
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

apply(from = "gradle/aar-output.gradle.kts")
