package dev.onlylyan.phonelink

import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.app.RemoteInput
import android.os.Bundle
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * Le as notificacoes do celular e manda para o PC.
 *
 * O Android exige que o proprio dono ligue este servico em Configuracoes ->
 * Acesso a notificacoes. Nao existe permissao que o app possa pedir por conta
 * propria, e nem deveria existir: quem tem isto le TUDO que chega no aparelho.
 */
class NotifListener : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val n = sbn.notification ?: return
        Log.i(TAG, "chegou de ${sbn.packageName} flags=${n.flags}")

        // Notificacao de servico em primeiro plano e ruido puro: e a barrinha
        // permanente de app rodando em segundo plano, inclusive a DESTE app.
        if (n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return
        if (n.flags and Notification.FLAG_ONGOING_EVENT != 0) return
        if (sbn.packageName == packageName) return

        val extras = n.extras ?: return
        val titulo = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val texto = (extras.getCharSequence(Notification.EXTRA_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT))?.toString().orEmpty()

        // sem titulo E sem texto nao ha o que mostrar do outro lado
        if (titulo.isBlank() && texto.isBlank()) return

        val body = JSONObject().apply {
            put("key", sbn.key)
            put("package", sbn.packageName)
            put("app", nomeDoApp(sbn.packageName))
            put("title", titulo)
            put("text", texto)
            put("time", sbn.postTime / 1000)
            // agrupavel do lado do PC sem depender do texto, que muda a cada
            // mensagem nova do mesmo contato
            put("group", n.group ?: "")
            // O icone do APLICATIVO, nao o da notificacao. O da notificacao e
            // quase sempre um simbolo monocromatico de 24px que fica ilegivel
            // no PC; o do aplicativo e colorido e reconhecivel de relance, que
            // e todo o ponto de ter icone.
            iconeBase64(sbn.packageName)?.let { put("icon", it) }
            // Diz ao PC se DA para responder. Sem isso ele mostraria caixa de
            // texto em notificacao que nunca vai aceitar resposta, e o erro so
            // apareceria depois de o Lucas digitar.
            put("can_reply", guardaResposta(sbn.key, n))
        }
        Log.i(TAG, "repassando: $titulo | $texto")
        Link.enviarNotificacao(body)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        Link.removerNotificacao(sbn.key)
        // NAO apaga a acao de resposta aqui de proposito.
        //
        // Ele quer responder tambem pelo HISTORICO do PC, muito depois de a
        // notificacao ter sumido do celular. O PendingIntent continua valido
        // enquanto o aplicativo de origem nao o cancelar, entao guardar da
        // chance de funcionar. Quando nao der, o envio falha e o PC recebe o
        // motivo, que e melhor que nem oferecer.
    }

    /**
     * Guarda a acao de resposta rapida da notificacao, se existir, e diz se ha.
     *
     * `RemoteInput` e o campo de resposta que o proprio Android mostra na
     * notificacao. Quem tem acesso de leitura pode preenche-lo e disparar o
     * PendingIntent, que e exatamente o que o app de mensagem faria.
     */
    private fun guardaResposta(chave: String, n: Notification): Boolean {
        val acoes = n.actions ?: return false
        for (a in acoes) {
            val entradas = a.remoteInputs ?: continue
            val alvo = entradas.firstOrNull { it.allowFreeFormInput } ?: continue
            respostas[chave] = Resposta(a.actionIntent, alvo, entradas)
            return true
        }
        return false
    }

    class Resposta(
        val intent: PendingIntent,
        val campo: RemoteInput,
        val todos: Array<RemoteInput>
    )

    companion object {
        private const val TAG = "PhoneLinkNotif"
        private const val LADO = 96          // suficiente para a pilula do PC
        // Cache por pacote: rasterizar o drawable a cada notificacao gastaria
        // CPU e bateria a toa, e numa rajada de mensagens do mesmo app seria o
        // mesmo trabalho repetido dezenas de vezes.
        private val cache = HashMap<String, String?>()

        // Compartilhado com o Link, que recebe o pedido vindo do PC.
        val respostas = HashMap<String, Resposta>()

        /** Envia a resposta. Devolve null se deu certo, ou o motivo da falha. */
        fun responder(chave: String, texto: String): String? {
            val r = respostas[chave] ?: return "essa notificacao nao aceita resposta"
            return try {
                val dados = Bundle().apply { putCharSequence(r.campo.resultKey, texto) }
                val intent = Intent()
                RemoteInput.addResultsToIntent(r.todos, intent, dados)
                // Alguns apps exigem a marcacao de origem para aceitar o texto
                RemoteInput.setResultsSource(intent, RemoteInput.SOURCE_FREE_FORM_INPUT)
                r.intent.send(null, 0, intent)
                null
            } catch (e: PendingIntent.CanceledException) {
                // Caminho tipico de notificacao velha: o app ja cancelou o
                // intent, entao responder pelo historico deixou de ser possivel.
                respostas.remove(chave)
                "o aplicativo cancelou essa conversa, responda pelo celular"
            } catch (e: Exception) {
                "falhou: ${e.javaClass.simpleName} ${e.message ?: ""}"
            }
        }
    }

    /** PNG do icone do app em base64, ou null se nao der para obter. */
    private fun iconeBase64(pkg: String): String? {
        cache[pkg]?.let { return it }
        if (cache.containsKey(pkg)) return null      // ja tentou e falhou

        val b64 = try {
            val d: Drawable = packageManager.getApplicationIcon(pkg)
            val bmp = if (d is BitmapDrawable && d.bitmap != null) {
                Bitmap.createScaledBitmap(d.bitmap, LADO, LADO, true)
            } else {
                // Icone adaptativo (o padrao no Android moderno) nao e um
                // BitmapDrawable: precisa ser desenhado num canvas.
                Bitmap.createBitmap(LADO, LADO, Bitmap.Config.ARGB_8888).also { bm ->
                    val c = Canvas(bm)
                    d.setBounds(0, 0, LADO, LADO)
                    d.draw(c)
                }
            }
            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
            Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        } catch (e: Exception) {
            Log.w(TAG, "sem icone para $pkg: ${e.message}")
            null
        }
        cache[pkg] = b64
        return b64
    }

    private fun nomeDoApp(pkg: String): String = try {
        val pm = packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (e: Exception) {
        // app desinstalado entre a notificacao e a leitura, ou pacote de sistema
        // sem label: o nome do pacote ainda diz mais que uma string vazia
        pkg
    }
}
