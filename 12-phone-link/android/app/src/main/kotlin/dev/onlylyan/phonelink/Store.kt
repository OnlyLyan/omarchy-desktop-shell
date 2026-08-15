package dev.onlylyan.phonelink

import android.content.Context
import java.util.UUID

/**
 * Estado que precisa sobreviver ao app fechar: identidade deste aparelho e o PC
 * confiavel.
 *
 * Um PC so, de proposito nesta fatia. Guardar uma lista traria decisoes que
 * ainda nao existem (qual conectar primeiro, o que fazer com dois na mesma
 * rede) sem resolver nada do que ele pediu.
 */
class Store(ctx: Context) {
    private val p = ctx.getSharedPreferences("phonelink", Context.MODE_PRIVATE)

    /** id estavel deste celular, gerado uma vez. */
    val deviceId: String
        get() {
            p.getString("device_id", null)?.let { return it }
            val novo = UUID.randomUUID().toString()
            p.edit().putString("device_id", novo).apply()
            return novo
        }

    var deviceName: String
        get() = p.getString("device_name", android.os.Build.MODEL) ?: "Android"
        set(v) = p.edit().putString("device_name", v).apply()

    /** fingerprint do PC ja pareado, ou null se ainda nao pareou. */
    var pcFingerprint: String?
        get() = p.getString("pc_fp", null)
        set(v) = p.edit().putString("pc_fp", v).apply()

    var pcNome: String?
        get() = p.getString("pc_nome", null)
        set(v) = p.edit().putString("pc_nome", v).apply()

    /** ultimo endereco visto, para reconectar sem esperar o proximo broadcast. */
    var pcHost: String?
        get() = p.getString("pc_host", null)
        set(v) = p.edit().putString("pc_host", v).apply()

    var pcPorta: Int
        get() = p.getInt("pc_porta", 0)
        set(v) = p.edit().putInt("pc_porta", v).apply()

    val pareado: Boolean get() = pcFingerprint != null

    fun esquecer() {
        p.edit().remove("pc_fp").remove("pc_nome").remove("pc_host").remove("pc_porta").apply()
    }
}
