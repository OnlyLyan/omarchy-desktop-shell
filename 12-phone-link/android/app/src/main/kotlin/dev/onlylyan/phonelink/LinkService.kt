package dev.onlylyan.phonelink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Segura a conexao viva com a tela apagada.
 *
 * Sem servico em primeiro plano o Android mata o processo em minutos e a
 * conexao morre junto, entao a notificacao do celular so chegaria no PC
 * enquanto o app estivesse aberto na tela, que nao serve para nada.
 *
 * A notificacao permanente e o preco obrigatorio disso, e o proprio leitor
 * ignora notificacoes deste pacote para ela nao ser reenviada ao PC.
 */
class LinkService : Service() {

    override fun onCreate() {
        super.onCreate()
        criaCanal()
        startForeground(ID_NOTIF, constroiNotificacao())
        Link.iniciar(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Link.iniciar(this)
        // START_STICKY: se o sistema matar por pressao de memoria, sobe de novo
        return START_STICKY
    }

    override fun onDestroy() {
        Link.parar()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun criaCanal() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val canal = NotificationChannel(
            CANAL, "Conexão com o PC",
            // IMPORTANCE_MIN: a notificacao precisa existir, mas nao pode
            // aparecer como aviso nem fazer barulho toda vez que o servico sobe
            NotificationManager.IMPORTANCE_MIN
        ).apply { description = "Mantém o Phone Link conectado" }
        getSystemService(NotificationManager::class.java).createNotificationChannel(canal)
    }

    private fun constroiNotificacao(): Notification {
        val abrir = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CANAL) else @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setContentTitle("Phone Link")
            .setContentText("conectado ao PC")
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentIntent(abrir)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CANAL = "phonelink-conexao"
        private const val ID_NOTIF = 1
    }
}
