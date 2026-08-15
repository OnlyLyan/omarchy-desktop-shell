package dev.onlylyan.phonelink

import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

/**
 * Tela unica: estado, codigo de pareamento e os dois atalhos de permissao.
 *
 * Sem biblioteca de UI de proposito. A tela tem cinco elementos e vai ser vista
 * uma vez por mes; puxar Compose para isso significaria mais 8 MB de APK e um
 * ciclo de build bem mais lento para o resto do trabalho.
 */
class MainActivity : AppCompatActivity(), Link.Observador {

    private lateinit var lblEstado: TextView
    private lateinit var lblCodigo: TextView
    private lateinit var lblErro: TextView
    private lateinit var btnParear: Button
    private lateinit var btnConfirmar: Button
    private lateinit var btnAcesso: Button
    private lateinit var btnEsquecer: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val raiz = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 64, 48, 48)
            setBackgroundColor(Color.parseColor("#12141f"))
        }

        raiz.addView(TextView(this).apply {
            text = "Phone Link"
            textSize = 26f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor("#e6e8f0"))
        })

        lblEstado = TextView(this).apply {
            textSize = 15f
            setTextColor(Color.parseColor("#7a80a0"))
            setPadding(0, 24, 0, 0)
        }
        raiz.addView(lblEstado)

        lblCodigo = TextView(this).apply {
            textSize = 44f
            setTypeface(Typeface.MONOSPACE, Typeface.BOLD)
            setTextColor(Color.parseColor("#7d82d9"))
            gravity = Gravity.CENTER
            letterSpacing = 0.2f
            setPadding(0, 40, 0, 40)
            visibility = View.GONE
        }
        raiz.addView(lblCodigo)

        lblErro = TextView(this).apply {
            textSize = 14f
            setTextColor(Color.parseColor("#e05c5c"))
            setPadding(0, 16, 0, 0)
            visibility = View.GONE
        }
        raiz.addView(lblErro)

        btnParear = Button(this).apply {
            text = "Parear com o PC"
            setOnClickListener { Link.pedirPareamento() }
        }
        raiz.addView(btnParear)

        btnConfirmar = Button(this).apply {
            text = "Os códigos são iguais, confirmar"
            visibility = View.GONE
            setOnClickListener { Link.confirmarCodigo() }
        }
        raiz.addView(btnConfirmar)

        btnAcesso = Button(this).apply {
            text = "Liberar leitura de notificações"
            setOnClickListener {
                // Nao existe permissao pedivel por dialogo: o unico caminho e
                // esta tela do sistema, e o dono tem que ligar na mao.
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            }
        }
        raiz.addView(btnAcesso)

        // Plano B para rede que bloqueia broadcast, que existe e e comum em
        // wifi de predio e de empresa. O daemon tem `phonectl connect` pelo
        // mesmo motivo.
        val campoIp = EditText(this).apply {
            hint = "IP do PC, ex 192.168.1.18"
            setTextColor(Color.parseColor("#e6e8f0"))
            setHintTextColor(Color.parseColor("#7a80a0"))
        }
        raiz.addView(campoIp)
        raiz.addView(Button(this).apply {
            text = "Conectar por IP"
            setOnClickListener {
                val ip = campoIp.text.toString().trim()
                if (ip.isNotBlank()) Link.conectarManual(ip)
            }
        })

        raiz.addView(Button(this).apply {
            text = "Liberar acesso aos arquivos"
            setOnClickListener {
                // Nao ha dialogo de permissao para esta: o unico caminho e a
                // tela do sistema, e o dono precisa ligar na mao.
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                    startActivity(Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        android.net.Uri.parse("package:$packageName")
                    ))
                }
            }
        })

        btnEsquecer = Button(this).apply {
            text = "Esquecer o PC"
            setOnClickListener { Link.esquecerPc() }
        }
        raiz.addView(btnEsquecer)

        setContentView(raiz)

        // sobe o servico que segura a conexao com a tela apagada
        val svc = Intent(this, LinkService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(svc) else startService(svc)
    }

    override fun onResume() {
        super.onResume()
        Link.observar(this)
    }

    override fun onPause() {
        Link.esquecerObservador(this)
        super.onPause()
    }

    override fun onMudou(estado: Link.Estado) {
        runOnUiThread {
            lblEstado.text = buildString {
                append(estado.texto)
                estado.pcNome?.let { append("\n$it") }
                if (!leituraLiberada()) append("\n\nfalta liberar a leitura de notificações")
            }
            lblCodigo.visibility = if (estado.codigo != null) View.VISIBLE else View.GONE
            lblCodigo.text = estado.codigo.orEmpty()
            btnConfirmar.visibility = if (estado.codigo != null) View.VISIBLE else View.GONE
            btnParear.visibility = if (estado.pareado || estado.codigo != null) View.GONE else View.VISIBLE
            btnEsquecer.visibility = if (estado.pareado) View.VISIBLE else View.GONE
            btnAcesso.visibility = if (leituraLiberada()) View.GONE else View.VISIBLE
            lblErro.visibility = if (estado.erro != null) View.VISIBLE else View.GONE
            lblErro.text = estado.erro.orEmpty()
        }
    }

    private fun leituraLiberada(): Boolean {
        val ativos = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        return ativos != null && ativos.contains(packageName)
    }
}
