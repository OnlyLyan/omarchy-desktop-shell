package dev.onlylyan.phonelink

import android.os.Build
import android.os.Environment
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile

/**
 * Leitura dos arquivos do celular a pedido do PC.
 *
 * PERMISSAO
 * A partir do Android 11 um app comum enxerga muito pouco do armazenamento: so
 * a propria pasta, e o resto atraves do MediaStore, que mostra midia e nao a
 * arvore de diretorios. Para navegar de verdade e preciso MANAGE_EXTERNAL_STORAGE,
 * a "Acesso a todos os arquivos", que NAO se pede por dialogo: o dono tem que
 * ligar na tela de configuracoes do sistema. Sem ela, `listar` devolve o que
 * conseguir e marca `limitado`, para o PC poder explicar em vez de mostrar uma
 * pasta vazia sem motivo aparente.
 *
 * SEGURANCA
 * O caminho vem pela rede. Todo pedido passa por `_dentro()`, que resolve o
 * caminho canonico e recusa qualquer coisa fora da raiz do armazenamento. Sem
 * isso um "../../data/data" leria dados privados de outros aplicativos.
 */
object Arquivos {

    private val RAIZ: File get() = Environment.getExternalStorageDirectory()

    /** Maior pedaco por pacote. O protocolo corta a linha em 1 MiB, e base64
     *  infla 33%, entao 192 KiB de dado bruto tem folga confortavel. */
    const val PEDACO = 192 * 1024

    fun temPermissao(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager()
        else true

    private fun dentro(caminho: String): File? {
        val alvo = if (caminho.isBlank() || caminho == "/") RAIZ else File(caminho)
        return try {
            val c = alvo.canonicalFile
            val raiz = RAIZ.canonicalFile
            if (c.path == raiz.path || c.path.startsWith(raiz.path + File.separator)) c else null
        } catch (e: Exception) {
            null
        }
    }

    fun listar(caminho: String): JSONObject {
        val resp = JSONObject()
        resp.put("path", caminho)
        resp.put("limitado", !temPermissao())
        val dir = dentro(caminho)
        if (dir == null) {
            resp.put("error", "caminho fora do armazenamento")
            return resp
        }
        resp.put("path", dir.path)
        if (!dir.exists()) { resp.put("error", "nao existe"); return resp }
        if (!dir.isDirectory) { resp.put("error", "nao e pasta"); return resp }

        val itens = dir.listFiles()
        if (itens == null) {
            resp.put("error", if (temPermissao()) "sem acesso a essa pasta"
                              else "falta a permissao Acesso a todos os arquivos")
            return resp
        }
        val arr = JSONArray()
        // pastas primeiro e depois por nome: e a ordem que qualquer gerenciador
        // usa, e ler uma listagem fora de ordem no terminal e sofrido
        for (f in itens.sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))) {
            arr.put(JSONObject().apply {
                put("name", f.name)
                put("dir", f.isDirectory)
                put("size", if (f.isDirectory) 0L else f.length())
                put("mtime", f.lastModified() / 1000)
            })
        }
        resp.put("entries", arr)
        return resp
    }

    fun ler(caminho: String, offset: Long, tamanho: Int): JSONObject {
        val resp = JSONObject()
        resp.put("path", caminho)
        resp.put("offset", offset)
        val f = dentro(caminho)
        if (f == null) { resp.put("error", "caminho fora do armazenamento"); return resp }
        if (!f.isFile) { resp.put("error", "nao e arquivo"); return resp }
        val quanto = tamanho.coerceIn(1, PEDACO)
        return try {
            RandomAccessFile(f, "r").use { raf ->
                resp.put("total", raf.length())
                if (offset >= raf.length()) {
                    resp.put("data", "")
                    resp.put("eof", true)
                    return resp
                }
                raf.seek(offset)
                val buf = ByteArray(quanto)
                val lidos = raf.read(buf)
                val uteis = if (lidos <= 0) ByteArray(0) else buf.copyOf(lidos)
                resp.put("data", Base64.encodeToString(uteis, Base64.NO_WRAP))
                resp.put("eof", offset + uteis.size >= raf.length())
            }
            resp
        } catch (e: Exception) {
            resp.put("error", "falha ao ler: ${e.javaClass.simpleName}")
            resp
        }
    }
}
