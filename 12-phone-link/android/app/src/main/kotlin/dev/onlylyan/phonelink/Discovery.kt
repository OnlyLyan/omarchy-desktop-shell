package dev.onlylyan.phonelink

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress

/**
 * Escuta o broadcast de identidade que o `phoned` manda na porta 1739.
 *
 * O daemon anuncia a cada 60s. Este lado so ESCUTA nesta fatia: anunciar de
 * volta exigiria decidir o que o PC faz ao ver um celular desconhecido, e a
 * fatia 1 do daemon ja resolve descoberta pelo lado dele.
 */
class Discovery(
    private val ctx: Context,
    private val onAchou: (Pc) -> Unit
) {

    data class Pc(
        val deviceId: String,
        val nome: String,
        val host: String,
        val porta: Int,
        val versao: Int
    )

    @Volatile private var rodando = false
    private var socket: DatagramSocket? = null
    private var trava: WifiManager.MulticastLock? = null

    fun iniciar() {
        if (rodando) return
        rodando = true
        // SEM ISTO A DESCOBERTA NAO FUNCIONA. O driver de Wi-Fi do Android
        // descarta pacote de broadcast e multicast que nao seja endereçado ao
        // aparelho, para economizar bateria, e o socket simplesmente nunca
        // recebe nada. Nao ha erro, nao ha excecao: fica mudo para sempre.
        // Medido em 15/08/2026 com o S23: o daemon anunciava a cada 60s e o
        // app nao via um pacote sequer ate a trava existir.
        try {
            val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            trava = wm.createMulticastLock("phonelink").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "sem MulticastLock: ${e.message}")
        }
        Thread({ laco() }, "phonelink-discovery").apply { isDaemon = true }.start()
    }

    fun parar() {
        rodando = false
        socket?.close()
        socket = null
        try { trava?.release() } catch (_: Exception) {}
        trava = null
    }

    private fun laco() {
        try {
            // reuseAddress: sem isto, o proprio sistema ou outra instancia com a
            // porta aberta faz o bind falhar e a descoberta morre calada.
            val s = DatagramSocket(null).apply {
                reuseAddress = true
                broadcast = true
                bind(InetSocketAddress(PORTA))
            }
            socket = s
            val buf = ByteArray(64 * 1024)
            while (rodando) {
                val pkt = DatagramPacket(buf, buf.size)
                s.receive(pkt)
                val linha = String(pkt.data, 0, pkt.length, Charsets.UTF_8).trim()
                Log.i(TAG, "datagrama de ${pkt.address.hostAddress}")
                trata(linha, pkt.address.hostAddress ?: continue)
            }
        } catch (e: Exception) {
            if (rodando) Log.w(TAG, "descoberta parou: ${e.message}")
        }
    }

    private fun trata(linha: String, origem: String) {
        val packet = try {
            Protocol.decode(linha)
        } catch (e: Exception) {
            return
        }
        if (packet.getString("type") != Protocol.IDENTITY) return
        val body: JSONObject = packet.getJSONObject("body")
        val porta = body.optInt("port", 0)
        if (porta <= 0) return
        onAchou(
            Pc(
                deviceId = body.optString("device_id", ""),
                nome = body.optString("name", origem),
                // o endereco vem do datagrama, nao do corpo: o corpo poderia
                // trazer um IP de outra interface do PC e a conexao falharia
                host = origem,
                porta = porta,
                versao = body.optInt("protocol_version", 1)
            )
        )
    }

    companion object {
        const val PORTA = 1739
        private const val TAG = "PhoneLinkDiscovery"
    }
}
