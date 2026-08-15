package dev.onlylyan.phonelink

import org.json.JSONObject
import java.util.UUID

/**
 * Serializacao dos pacotes, espelho exato de phoned/protocol.py.
 *
 * Um pacote e sempre uma linha JSON UTF-8 com os quatro campos id, type, ts e
 * body, terminada em \n. Qualquer divergencia aqui derruba a conexao do outro
 * lado com ProtocolError, entao os nomes e tipos seguem o Python ao pe da letra.
 */
object Protocol {
    const val MAX_LINE_BYTES = 1024 * 1024

    // tipos que o daemon ja conhece (phoned/transport.py)
    const val IDENTITY = "identity"
    const val PAIR_REQUEST = "pair.request"
    const val PAIR_ACCEPT = "pair.accept"
    const val PAIR_REJECT = "pair.reject"
    const val PAIR_RESULT = "pair.result"
    const val PAIR_PROMPT = "pair.prompt"
    // "phone.ping", nao "ping". Descoberto no teste com o daemon real: ele manda
    // phone.ping como batimento e DERRUBA a sessao de quem nao responde
    // phone.pong. Um cliente que responde "pong" cai a cada ciclo de heartbeat
    // sem nenhum erro visivel, so a conexao morrendo sozinha.
    const val PING = "phone.ping"
    const val PONG = "phone.pong"

    // tipo novo desta fatia, precisa existir dos DOIS lados
    const val NOTIF_POST = "notif.post"
    const val NOTIF_REMOVE = "notif.remove"
    const val NOTIF_REPLY = "notif.reply"                // PC -> celular
    const val NOTIF_REPLY_RESULT = "notif.reply.result"  // celular -> PC

    // arquivos: o PC pergunta, o celular responde ecoando `req` com o id do
    // pedido. Sem o eco o PC nao consegue casar resposta com pergunta quando
    // ha mais de uma em voo.
    const val FS_LIST = "fs.list"
    const val FS_LIST_RESULT = "fs.list.result"
    const val FS_READ = "fs.read"
    const val FS_READ_RESULT = "fs.read.result"

    class ProtocolError(msg: String) : Exception(msg)

    fun make(type: String, body: JSONObject = JSONObject()): JSONObject =
        JSONObject().apply {
            put("id", UUID.randomUUID().toString())
            put("type", type)
            // segundos, nao milissegundos: o Python valida `ts` como int e o
            // resto da stack trata como epoch em segundos
            put("ts", System.currentTimeMillis() / 1000)
            put("body", body)
        }

    fun encode(packet: JSONObject): ByteArray {
        val raw = packet.toString().toByteArray(Charsets.UTF_8)
        if (raw.size + 1 > MAX_LINE_BYTES) {
            throw ProtocolError("pacote com ${raw.size} bytes excede o limite de linha")
        }
        return raw + '\n'.code.toByte()
    }

    fun decode(line: String): JSONObject {
        val parsed = try {
            JSONObject(line)
        } catch (e: Exception) {
            throw ProtocolError("linha nao e JSON valido: ${e.message}")
        }
        for (campo in listOf("id", "type", "ts", "body")) {
            if (!parsed.has(campo)) throw ProtocolError("campo obrigatorio ausente: $campo")
        }
        if (parsed.optJSONObject("body") == null) throw ProtocolError("campo body deveria ser objeto")
        return parsed
    }
}
