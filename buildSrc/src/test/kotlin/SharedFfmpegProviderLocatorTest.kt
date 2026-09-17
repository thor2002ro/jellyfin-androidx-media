import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class SharedFfmpegProviderLocatorTest {
    @Test
    fun `explicit provider wins over automatic discovery`() {
        val checkout = temporaryCheckout()
        val explicit = checkout.resolve("custom/provider.aar").createFile()
        createProvider(checkout, "8.1.2-thor.newer", modifiedAt = 2_000L)

        val selection = selectSharedFfmpegProvider(checkout, "custom/provider.aar")

        assertEquals(SharedFfmpegProviderSource.EXPLICIT, selection.source)
        assertEquals(explicit.canonicalFile, selection.aar)
    }

    @Test
    fun `automatic discovery selects newest MPV provider`() {
        val checkout = temporaryCheckout()
        createProvider(checkout, "8.1.1-thor.older", modifiedAt = 1_000L)
        val newest = createProvider(checkout, "8.1.2-thor.newest", modifiedAt = 2_000L)

        val selection = selectSharedFfmpegProvider(checkout, null)

        assertEquals(SharedFfmpegProviderSource.DISCOVERED, selection.source)
        assertEquals(newest.canonicalFile, selection.aar)
    }

    @Test
    fun `missing MPV provider selects local FFmpeg`() {
        val checkout = temporaryCheckout()

        val selection = selectSharedFfmpegProvider(checkout, null)

        assertEquals(SharedFfmpegProviderSource.NONE, selection.source)
        assertNull(selection.aar)
    }

    private fun temporaryCheckout(): File {
        val root = kotlin.io.path.createTempDirectory("media3-provider-selection").toFile()
        return root.resolve("jellyfin-androidx-media").apply { mkdirs() }
    }

    private fun createProvider(checkout: File, version: String, modifiedAt: Long): File {
        val provider = checkout.parentFile.resolve(
            "mpv-android-lib/OUTPUT/maven/io/github/abdallahmehiz/" +
                "mpv-ffmpeg-android/$version/mpv-ffmpeg-android-$version.aar"
        ).createFile()
        check(provider.setLastModified(modifiedAt))
        return provider
    }

    private fun File.createFile(): File = apply {
        parentFile.mkdirs()
        writeText("fixture")
    }
}
