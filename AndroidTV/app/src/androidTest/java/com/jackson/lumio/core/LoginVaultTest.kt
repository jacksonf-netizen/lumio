package com.jackson.lumio.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LoginVaultTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun savesLoadsAndDeletesWithoutKeepingThePasswordReadable() {
        val vault = LoginVault(context)
        val login = """{"username":"viewer","password":"s3cret-pass"}""".toByteArray()
        assertTrue(vault.save("vault-test", login))
        assertArrayEquals(login, vault.load("vault-test"))

        val stored = File(context.noBackupFilesDir, "logins").listFiles().orEmpty().map { it.readBytes() }
        assertTrue(stored.isNotEmpty())
        assertFalse(stored.any { String(it, Charsets.ISO_8859_1).contains("s3cret-pass") })

        assertTrue(vault.delete("vault-test"))
        assertNull(vault.load("vault-test"))
        assertTrue(vault.delete("vault-test"))
    }
}
