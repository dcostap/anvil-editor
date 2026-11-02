package io.github.dcostap.anvil

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

// A paired Machine: where to reach it, and this phone's device ID and token there.
data class MachineRecord(val machine: String, val host: String, val port: Int, val device: String, val token: String)

// Keeps the paired Machines in the app's private storage. Each token is encrypted with an AES key in Android
// Keystore, so a copy of the file cannot log in.
class MachineStore(context: Context) {
    private val file = File(context.filesDir, "machines.json")

    fun load(): List<MachineRecord> {
        if (!file.exists()) return emptyList()
        val list = JSONArray(file.readText())
        return (0 until list.length()).map { i ->
            val item = list.getJSONObject(i)
            MachineRecord(item.getString("machine"), item.getString("host"), item.getInt("port"),
                item.getString("device"), decrypt(item.getString("token")))
        }
    }

    fun save(records: List<MachineRecord>) {
        val list = JSONArray()
        for (record in records) {
            list.put(JSONObject().put("machine", record.machine).put("host", record.host).put("port", record.port)
                .put("device", record.device).put("token", encrypt(record.token)))
        }
        val next = File(file.parentFile, file.name + ".new")
        next.writeText(list.toString())
        check(next.renameTo(file)) { "Cannot save the paired Machines" }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as SecretKey?)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    // The 12-byte IV, then the ciphertext with its tag, in Base64.
    private fun encrypt(text: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, key()) }
        return Base64.encodeToString(cipher.iv + cipher.doFinal(text.toByteArray()), Base64.NO_WRAP)
    }

    private fun decrypt(text: String): String {
        val data = Base64.decode(text, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data, 0, IV_LENGTH))
        return String(cipher.doFinal(data, IV_LENGTH, data.size - IV_LENGTH))
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "anvil-machine-tokens"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_LENGTH = 12
    }
}
