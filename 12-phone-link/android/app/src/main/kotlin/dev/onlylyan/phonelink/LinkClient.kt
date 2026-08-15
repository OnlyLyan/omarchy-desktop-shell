package dev.onlylyan.phonelink

import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.cert.X509Certificate
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/**
 * Canal TLS 1.3 com o `phoned`, e a maquina de pareamento.
 *
 * Ordem do pareamento, lida direto de phoned/transport.py e nao suposta:
 *
 *   1. celular conecta e manda `pair.request` com o proprio certificado no CORPO
 *      do pacote. Vai no corpo porque no primeiro contato o servidor ainda nao
 *      confia em ninguem e por isso nao PODE exigir certificado de cliente no
 *      handshake (ssl.CERT_NONE): o corpo e a unica entrega possivel.
 *   2. PC mostra o codigo e espera o dono dele confirmar
 *   3. PC responde `pair.accept` com o certificado dele; so agora este lado
 *      consegue calcular o codigo e mostrar na tela
 *   4. dono do celular confirma, celular manda `pair.accept` com o certificado
 *   5. PC conclui e manda `pair.result`
 *
 * Confirmar antes de ver o codigo e impossivel de proposito: a unica garantia
 * do primeiro pareamento e a comparacao visual, e pular isso a anula.
 */
class LinkClient(
    private val ctx: android.content.Context,
    private val store: Store,
    private val ouvinte: Ouvinte
) {
    interface Ouvinte {
        fun onEstado(estado: String)
        fun onCodigo(codigo: String)
        fun onPareado(nomePc: String)
        fun onErro(msg: String)
    }

    @Volatile private var socket: SSLSocket? = null
    @Volatile private var saida: OutputStream? = null
    @Volatile var conectado = false; private set

    /** setado quando o PC manda pair.accept e o codigo passa a existir */
    @Volatile private var codigoPendente: String? = null
    @Volatile private var certPcPendente: String? = null

    // ------------------------------------------------------------------ TLS
    private var fpServidor: String? = null

    private fun contexto(): SSLContext {
        val kmf = KeyManagerFactory.getInstance("X509").apply {
            init(Crypto.keyStore(ctx), Crypto.senha())
        }
        // TrustManager proprio: a confianca aqui NAO e por cadeia nem por nome
        // de host, e por fingerprint, igual ao lado do PC. Cadeia nao serve
        // porque os dois lados usam certificado autoassinado.
        val tm = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                val cert = chain?.firstOrNull() ?: throw java.security.cert.CertificateException("sem certificado")
                val fp = Crypto.fingerprintDe(cert.encoded)
                fpServidor = fp
                val esperado = store.pcFingerprint
                // Sem pareamento ainda: aceita para poder PAREAR. A protecao
                // nesse momento e o codigo de 6 caracteres, nao o TLS.
                if (esperado != null && esperado != fp) {
                    throw java.security.cert.CertificateException(
                        "fingerprint diferente do PC pareado"
                    )
                }
            }
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        return SSLContext.getInstance("TLSv1.3").apply {
            init(kmf.keyManagers, arrayOf(tm), null)
        }
    }

    fun conectar(host: String, porta: Int): Boolean {
        desconectar()
        return try {
            ouvinte.onEstado("conectando em $host:$porta")
            val bruto = Socket()
            bruto.connect(InetSocketAddress(host, porta), TIMEOUT_MS)
            val s = contexto().socketFactory.createSocket(bruto, host, porta, true) as SSLSocket
            s.enabledProtocols = arrayOf("TLSv1.3")
            s.soTimeout = 0
            s.startHandshake()
            socket = s
            saida = s.outputStream
            conectado = true
            store.pcHost = host
            store.pcPorta = porta
            // OBRIGATORIO e antes de tudo: o daemon derruba qualquer pacote que
            // chegue antes de um `identity` ("pacote X antes de identity").
            // Os seis campos tambem sao obrigatorios, e `capabilities` tem que
            // ser lista mesmo vazia, senao Identity.from_body levanta erro.
            enviarIdentidade()
            ouvinte.onEstado(if (store.pareado) "conectado" else "conectado, falta parear")
            Thread({ laco(s) }, "phonelink-rx").apply { isDaemon = true }.start()
            true
        } catch (e: Exception) {
            conectado = false
            // Tambem no log, e com a classe da excecao: mandar so para a tela
            // escondia a causa sempre que o app estava em segundo plano, que e
            // justamente quando a reconexao acontece. E `message` sozinho e
            // inutil em excecao de TLS, que costuma vir com mensagem nula.
            Log.w(TAG, "falha ao conectar em $host:$porta", e)
            ouvinte.onErro("falha ao conectar: ${e.javaClass.simpleName} ${e.message ?: ""}")
            false
        }
    }

    private fun enviarIdentidade() {
        val body = JSONObject().apply {
            put("device_id", store.deviceId)
            put("name", store.deviceName)
            put("device_type", "phone")
            // 0 porque o celular nao escuta conexao nenhuma: quem aceita e o PC.
            // O campo e obrigatorio no contrato, entao vai zerado em vez de faltar.
            put("port", 0)
            put("protocol_version", 1)
            put("capabilities", org.json.JSONArray().put("notifications"))
        }
        enviar(Protocol.make(Protocol.IDENTITY, body))
    }

    fun desconectar() {
        conectado = false
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        saida = null
    }

    @Synchronized
    fun enviar(packet: JSONObject): Boolean {
        val out = saida ?: return false
        return try {
            out.write(Protocol.encode(packet))
            out.flush()
            true
        } catch (e: Exception) {
            Log.w(TAG, "envio falhou: ${e.message}")
            conectado = false
            false
        }
    }

    private fun laco(s: SSLSocket) {
        try {
            val leitor = BufferedReader(InputStreamReader(s.inputStream, Charsets.UTF_8))
            while (conectado) {
                val linha = leitor.readLine() ?: break
                if (linha.isBlank()) continue
                val packet = try {
                    Protocol.decode(linha)
                } catch (e: Exception) {
                    Log.w(TAG, "pacote invalido: ${e.message}"); continue
                }
                trata(packet)
            }
        } catch (e: Exception) {
            if (conectado) Log.w(TAG, "leitura parou: ${e.message}")
        } finally {
            // So derruba o estado se este laco ainda for o dono do socket atual.
            // Sem esta guarda havia uma CORRIDA real: ao reconectar, conectar()
            // fecha o socket antigo, a thread velha acorda com excecao e o
            // finally dela marcava conectado=false DEPOIS de a conexao nova ja
            // ter marcado true. Resultado: a sessao nova nascia morta, o daemon
            // derrubava por "sem resposta" a cada minuto, e o proximo anuncio
            // repetia o ciclo para sempre.
            if (socket === s) {
                conectado = false
                ouvinte.onEstado("desconectado")
            }
        }
    }

    private fun trata(packet: JSONObject) {
        val body = packet.optJSONObject("body") ?: JSONObject()
        when (packet.getString("type")) {
            Protocol.IDENTITY -> {
                // o PC se identifica primeiro; e daqui que sai o nome mostrado
                val nome = body.optString("name", "")
                if (nome.isNotBlank()) store.pcNome = nome
                ouvinte.onEstado(if (store.pareado) "conectado a $nome" else "conectado a $nome, falta parear")
            }

            // ecoa o echo_id: e assim que o daemon casa o pong com o ping que
            // mandou, e sem isso ele nunca considera a resposta recebida
            Protocol.PING -> enviar(
                Protocol.make(Protocol.PONG, JSONObject().put("echo_id", packet.getString("id")))
            )

            Protocol.PAIR_ACCEPT -> {
                val pem = body.optString("certificate", "")
                if (pem.isBlank()) { ouvinte.onErro("PC aceitou sem mandar certificado"); return }
                certPcPendente = pem
                val fpPc = fingerprintDoPem(pem)
                if (fpPc == null) { ouvinte.onErro("certificado do PC invalido"); return }
                val codigo = Crypto.pairCode(Crypto.meuFingerprint(ctx), fpPc)
                codigoPendente = codigo
                ouvinte.onCodigo(codigo)
            }

            Protocol.PAIR_RESULT -> {
                val ok = body.optBoolean("paired", false)
                if (ok) {
                    val pem = certPcPendente
                    val fp = pem?.let { fingerprintDoPem(it) }
                    if (fp != null) {
                        store.pcFingerprint = fp
                        ouvinte.onPareado(store.pcNome ?: "PC")
                    } else {
                        ouvinte.onErro("pareado, mas sem certificado do PC para guardar")
                    }
                } else {
                    ouvinte.onErro("pareamento recusado: ${body.optString("reason", "sem motivo")}")
                }
                codigoPendente = null
            }

            Protocol.NOTIF_REPLY -> {
                val chave = body.optString("key", "")
                val texto = body.optString("text", "")
                val erro = if (chave.isBlank()) "sem chave"
                           else NotifListener.responder(chave, texto)
                Log.i(TAG, "pedido de resposta para '$chave': ${erro ?: "enviado"}")
                enviar(Protocol.make(Protocol.NOTIF_REPLY_RESULT, JSONObject().apply {
                    put("key", chave)
                    put("ok", erro == null)
                    put("reason", erro ?: "")
                }))
            }

            Protocol.FS_LIST -> {
                val r = Arquivos.listar(body.optString("path", ""))
                r.put("req", packet.getString("id"))
                enviar(Protocol.make(Protocol.FS_LIST_RESULT, r))
            }

            Protocol.FS_READ -> {
                val r = Arquivos.ler(
                    body.optString("path", ""),
                    body.optLong("offset", 0L),
                    body.optInt("size", Arquivos.PEDACO)
                )
                r.put("req", packet.getString("id"))
                enviar(Protocol.make(Protocol.FS_READ_RESULT, r))
            }

            Protocol.PAIR_REJECT ->
                ouvinte.onErro("recusado: ${body.optString("reason", "sem motivo")}")

            Protocol.PAIR_PROMPT -> {
                // o daemon tambem publica o codigo por aqui em alguns caminhos
                val codigo = body.optString("code", "")
                if (codigo.isNotBlank()) { codigoPendente = codigo; ouvinte.onCodigo(codigo) }
            }
        }
    }

    // -------------------------------------------------------------- pareamento
    // Os tres metodos abaixo sao chamados por clique de botao, ou seja, pela
    // thread da INTERFACE. Escrever em socket ali dispara
    // NetworkOnMainThreadException, cuja mensagem e null: no log aparecia so
    // "envio falhou: null", sem nenhuma pista do que era. Dai a thread.
    private fun emThread(nome: String, corpo: () -> Unit) {
        Thread(corpo, nome).apply { isDaemon = true }.start()
    }

    fun pedirPareamento() = emThread("phonelink-pair") {
        val body = JSONObject().put("certificate", Crypto.certificadoPem(ctx))
        if (!enviar(Protocol.make(Protocol.PAIR_REQUEST, body))) {
            ouvinte.onErro("nao consegui enviar o pedido de pareamento")
        } else {
            ouvinte.onEstado("aguardando o PC confirmar")
        }
    }

    /** Chamado quando ELE confere que os dois codigos batem e aceita. */
    fun confirmarCodigo() = emThread("phonelink-confirm") {
        if (codigoPendente == null) {
            // Aceitar sem codigo na tela e aceitar sem ter comparado nada, que e
            // exatamente a unica garantia deste primeiro pareamento.
            ouvinte.onErro("ainda nao ha codigo para comparar")
            return@emThread
        }
        val body = JSONObject().put("certificate", Crypto.certificadoPem(ctx))
        if (!enviar(Protocol.make(Protocol.PAIR_ACCEPT, body))) {
            ouvinte.onErro("nao consegui confirmar")
        }
    }

    fun recusarCodigo() = emThread("phonelink-reject") {
        enviar(Protocol.make(Protocol.PAIR_REJECT, JSONObject().put("reason", "recusado no celular")))
        codigoPendente = null
    }

    private fun fingerprintDoPem(pem: String): String? = try {
        val b64 = pem.replace("-----BEGIN CERTIFICATE-----", "")
            .replace("-----END CERTIFICATE-----", "")
            .replace("\\s".toRegex(), "")
        val der = android.util.Base64.decode(b64, android.util.Base64.DEFAULT)
        Crypto.fingerprintDe(der)
    } catch (e: Exception) {
        null
    }

    companion object {
        private const val TAG = "PhoneLinkClient"
        private const val TIMEOUT_MS = 6000
    }
}
