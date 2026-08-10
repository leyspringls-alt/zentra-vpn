package com.v2ray.ang.handler

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.v2ray.ang.AppConfig
import com.v2ray.ang.util.LogUtil

/**
 * Хранилище доступов к серверу.
 *
 * Пароль root и закрытый SSH-ключ — это полный контроль над сервером,
 * поэтому они не попадают в обычные настройки: используется
 * EncryptedSharedPreferences поверх Android Keystore.
 */
object ServerCredentialsStore {

    private const val FILE_NAME = "zentra_server_credentials"

    private const val KEY_HOST = "host"
    private const val KEY_PORT = "port"
    private const val KEY_USER = "user"
    private const val KEY_SECRET = "secret"
    private const val KEY_IS_PRIVATE_KEY = "is_private_key"

    @Volatile
    private var prefs: SharedPreferences? = null

    private fun prefs(context: Context): SharedPreferences? {
        prefs?.let { return it }
        return synchronized(this) {
            prefs ?: runCatching {
                val masterKey = MasterKey.Builder(context.applicationContext)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
                EncryptedSharedPreferences.create(
                    context.applicationContext,
                    FILE_NAME,
                    masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                )
            }.onFailure {
                LogUtil.e(AppConfig.TAG, "не удалось открыть защищённое хранилище", it)
            }.getOrNull()?.also { prefs = it }
        }
    }

    fun save(context: Context, credentials: ServerCredentials) {
        prefs(context)?.edit()
            ?.putString(KEY_HOST, credentials.host)
            ?.putInt(KEY_PORT, credentials.port)
            ?.putString(KEY_USER, credentials.user)
            ?.putString(KEY_SECRET, credentials.secret)
            ?.putBoolean(KEY_IS_PRIVATE_KEY, credentials.isPrivateKey)
            ?.apply()
    }

    fun load(context: Context): ServerCredentials? {
        val p = prefs(context) ?: return null
        val host = p.getString(KEY_HOST, null) ?: return null
        val secret = p.getString(KEY_SECRET, null) ?: return null
        return ServerCredentials(
            host = host,
            port = p.getInt(KEY_PORT, 22),
            user = p.getString(KEY_USER, "root").orEmpty(),
            secret = secret,
            isPrivateKey = p.getBoolean(KEY_IS_PRIVATE_KEY, false)
        )
    }

    fun clear(context: Context) {
        prefs(context)?.edit()?.clear()?.apply()
    }
}

/**
 * Доступ к серверу по SSH.
 *
 * @param secret пароль либо закрытый ключ целиком, в зависимости от [isPrivateKey].
 */
data class ServerCredentials(
    val host: String,
    val port: Int = 22,
    val user: String = "root",
    val secret: String,
    val isPrivateKey: Boolean,
)
