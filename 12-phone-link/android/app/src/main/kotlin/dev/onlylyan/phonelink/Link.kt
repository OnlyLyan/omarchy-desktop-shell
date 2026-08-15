package dev.onlylyan.phonelink

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * Ponto unico de estado da conexao.
 *
 * Existe porque tres coisas independentes precisam falar com o mesmo canal: o
 * servico em primeiro plano (que mantem vivo), o leitor de notificacoes (que
 * dispara a qualquer momento) e a tela (que mostra e pareia). Passar a conexao
 * de um para o outro por Intent ou binder daria muito mais codigo para o mesmo
 * resultado, e o leitor de notificacoes nao pode esperar bind nenhum: ele e
 * chamado pelo sistema e tem que despachar na hora.
 */
object Link {

    interface Observador {
        fun onMudou(estado: Estado)
    }

    data class Estado(
        val texto: String = "parado",
        val conectado: Boolean = false,
        val pareado: Boolean = false,
        val codigo: String? = null,
        val pcNome: String? = null,
        val erro: String? = null
    )

    @Volatile var estado = Estado(); private set
    private val observadores = mutableSetOf<Observador>()

    private lateinit var store: Store
    private var cliente: LinkClient? = null
    private var descoberta: Discovery? = null
    @Volatile private var iniciado = false

    // Fila de envio com UMA thread. Duas razoes:
    //  1. onNotificationPosted roda na thread da INTERFACE, e escrever em socket
    //     ali dispara NetworkOnMainThreadException com mensagem nula. Era isso
    //     que fazia a notificacao ser lida, logada como "repassando" e sumir
    //     sem chegar no PC.
    //  2. uma thread so preserva a ORDEM. Com um Thread por notificacao, uma
    //     rajada chegaria embaralhada do outro lado.
    private val fila = Executors.newSingleThreadExecutor { r ->
        Thread(r, "phonelink-envio").apply { isDaemon = true }
    }

    fun observar(o: Observador) { synchronized(observadores) { observadores.add(o) }; o.onMudou(estado) }
    fun esquecerObservador(o: Observador) { synchronized(observadores) { observadores.remove(o) } }

    private fun publica(novo: Estado) {
        estado = novo
        val copia = synchronized(observadores) { observadores.toList() }
        copia.forEach { it.onMudou(novo) }
    }

    private val ouvinte = object : LinkClient.Ouvinte {
        override fun onEstado(e: String) =
            publica(estado.copy(texto = e, conectado = cliente?.conectado == true, erro = null))
        override fun onCodigo(c: String) =
            publica(estado.copy(codigo = c, texto = "confira o código nos dois aparelhos"))
        override fun onPareado(nome: String) =
            publica(estado.copy(pareado = true, codigo = null, pcNome = nome, texto = "pareado"))
        override fun onErro(m: String) =
            publica(estado.copy(erro = m, texto = "erro"))
    }

    fun iniciar(ctx: Context) {
        if (iniciado) return
        iniciado = true
        store = Store(ctx.applicationContext)
        cliente = LinkClient(ctx.applicationContext, store, ouvinte)
        publica(estado.copy(pareado = store.pareado, pcNome = store.pcNome, texto = "procurando o PC"))

        descoberta = Discovery(ctx.applicationContext) { pc ->
            // ja conectado nao troca de PC no meio do caminho: o broadcast chega
            // a cada 60s e reconectar a cada anuncio derrubaria a sessao viva
            if (cliente?.conectado == true) return@Discovery
            store.pcNome = pc.nome
            cliente?.conectar(pc.host, pc.porta)
        }.also { it.iniciar() }

        // tenta o ultimo endereco conhecido antes de esperar o proximo anuncio,
        // que pode demorar ate um minuto
        val host = store.pcHost
        val porta = store.pcPorta
        if (host != null && porta > 0) {
            Thread({ cliente?.conectar(host, porta) }, "phonelink-reconectar").apply { isDaemon = true }.start()
        }

        Thread({ vigia() }, "phonelink-vigia").apply { isDaemon = true }.start()
    }

    fun parar() {
        iniciado = false
        descoberta?.parar(); descoberta = null
        cliente?.desconectar(); cliente = null
        publica(Estado())
    }

    /** reconecta sozinho quando a sessao cai, com o ultimo endereco conhecido. */
    private fun vigia() {
        while (iniciado) {
            Thread.sleep(15_000)
            if (!iniciado) return
            if (cliente?.conectado == true) continue
            val host = store.pcHost ?: continue
            val porta = store.pcPorta
            if (porta > 0) cliente?.conectar(host, porta)
        }
    }

    /** Conexao manual por IP. O daemon tem `phonectl connect` pelo mesmo motivo:
     *  rede que bloqueia broadcast existe, e sem isto nao ha como nem comecar. */
    fun conectarManual(host: String, porta: Int = 1739) {
        Thread({ cliente?.conectar(host, porta) }, "phonelink-manual").apply { isDaemon = true }.start()
    }

    fun pedirPareamento() = cliente?.pedirPareamento()
    fun confirmarCodigo() = cliente?.confirmarCodigo()
    fun recusarCodigo() = cliente?.recusarCodigo()
    fun esquecerPc() { store.esquecer(); cliente?.desconectar(); publica(Estado(texto = "esquecido")) }

    /** Chamado pelo leitor de notificacoes. Silencioso se nao houver canal. */
    fun enviarNotificacao(body: JSONObject) = fila.execute {
        val c = cliente
        if (c == null) { Log.w("PhoneLink", "sem cliente, descartando notificacao"); return@execute }
        if (!c.conectado) { Log.w("PhoneLink", "desconectado, descartando notificacao"); return@execute }
        if (!::store.isInitialized || !store.pareado) { Log.w("PhoneLink", "nao pareado, descartando"); return@execute }
        if (c.enviar(Protocol.make(Protocol.NOTIF_POST, body))) {
            Log.i("PhoneLink", "notificacao enviada ao PC")
        }
    }

    fun removerNotificacao(chave: String) = fila.execute {
        val c = cliente ?: return@execute
        if (!c.conectado || !::store.isInitialized || !store.pareado) return@execute
        c.enviar(Protocol.make(Protocol.NOTIF_REMOVE, JSONObject().put("key", chave)))
    }
}
