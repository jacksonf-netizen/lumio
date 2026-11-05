package com.jackson.lumio.core

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Saved provider logins, the Android counterpart of the Mac's Keychain.
 *
 * Each login is encrypted (AES-GCM) with a key that lives in the Android Keystore and never leaves
 * it, and stored in a small file in the app's no-backup folder, so Google's backup never copies it
 * (the manifest also turns backup off). File names are a hash of the provider ID. Values are
 * never logged.
 */
class LoginVault(context: Context) {
    private val folder = File(context.noBackupFilesDir, "logins").apply { mkdirs() }

    fun save(providerID: String, value: ByteArray): Boolean = runCatching {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(value)
        val target = file(providerID)
        val temporary = File(folder, target.name + ".tmp")
        temporary.writeBytes(sealed)
        temporary.renameTo(target)
    }.getOrDefault(false)

    fun load(providerID: String): ByteArray? = runCatching {
        val file = file(providerID)
        if (!file.exists()) return null
        val sealed = file.readBytes()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, IV_LENGTH))
        cipher.doFinal(sealed, IV_LENGTH, sealed.size - IV_LENGTH)
    }.getOrNull()

    fun delete(providerID: String): Boolean {
        val file = file(providerID)
        return !file.exists() || file.delete()
    }

    private fun file(providerID: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(providerID.toByteArray())
        return File(folder, digest.joinToString("") { "%02x".format(it) })
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    private companion object {
        const val KEY_ALIAS = "lumio.logins"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_LENGTH = 12
    }
}
