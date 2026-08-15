package dev.onlylyan.phonelink

import android.content.Context
import android.util.Base64
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date

/**
 * Certificado do aparelho, fingerprint e codigo de pareamento.
 *
 * POR QUE A CHAVE NAO MORA NO ANDROIDKEYSTORE
 *
 * A primeira versao usava AndroidKeyStore, que e a opcao mais segura no papel:
 * a chave privada nunca entra na memoria do app e em aparelho com TEE fica no
 * hardware. Na pratica ela NAO funciona como certificado de cliente em TLS 1.3
 * neste caminho. Medido no S23 com Android 16, em 15/08/2026:
 *
 *   - chave RSA:  javax.net.ssl.SSLProtocolException
 *                 "error:04000044:RSA routines: internal error"
 *   - chave EC:   o celular RESETA a conexao no meio do handshake, e o servidor
 *                 registra ConnectionResetError durante o aperto de mao
 *
 * Provado por eliminacao: com `init(null, ...)`, ou seja SEM apresentar
 * certificado nenhum, o handshake fecha sempre, e o servidor entao recusa por
 * outro motivo, "consta pareado mas nao apresentou certificado". Ou seja, o
 * transporte esta certo e o que quebra e a assinatura vinda do keystore.
 *
 * A troca: a chave privada passa a viver num PKCS12 dentro do armazenamento
 * privado do app. Continua inacessivel para outros aplicativos, mas nao e mais
 * protegida por hardware. Para um retransmissor de notificacao em rede local, e
 * um custo aceitavel diante de nao funcionar de jeito nenhum.
 */
object Crypto {
    private const val ARQUIVO = "phonelink-identidade.p12"
    private const val ALIAS = "phonelink"
    // Senha do arquivo, nao segredo de verdade: o PKCS12 exige uma, e o que
    // realmente protege o arquivo e a permissao do armazenamento privado do app.
    private val SENHA = "phonelink".toCharArray()

    private var cache: KeyStore? = null

    private fun arquivo(ctx: Context) = File(ctx.applicationContext.filesDir, ARQUIVO)

    @Synchronized
    fun keyStore(ctx: Context): KeyStore {
        cache?.let { return it }
        val f = arquivo(ctx)
        val ks = KeyStore.getInstance("PKCS12")
        if (f.exists()) {
            f.inputStream().use { ks.load(it, SENHA) }
        } else {
            ks.load(null, SENHA)
            gera(ks)
            f.outputStream().use { ks.store(it, SENHA) }
        }
        cache = ks
        return ks
    }

    private fun gera(ks: KeyStore) {
        val gen = KeyPairGenerator.getInstance("EC")
        gen.initialize(ECGenParameterSpec("secp256r1"), SecureRandom())
        val par = gen.generateKeyPair()

        val nome = X500Name("CN=PhoneLink Android")
        val agora = System.currentTimeMillis()
        val builder = JcaX509v3CertificateBuilder(
            nome,                                  // emissor: ele mesmo
            BigInteger.valueOf(agora),
            Date(agora - 24L * 60 * 60 * 1000),    // um dia atras, folga para
                                                   // relogio adiantado do outro lado
            Date(agora + 3650L * 24 * 60 * 60 * 1000),
            nome,                                  // titular
            par.public
        )
        val assinador = JcaContentSignerBuilder("SHA256withECDSA").build(par.private)
        val cert: X509Certificate = JcaX509CertificateConverter().getCertificate(builder.build(assinador))
        ks.setKeyEntry(ALIAS, par.private, SENHA, arrayOf(cert))
    }

    fun certificado(ctx: Context): X509Certificate =
        keyStore(ctx).getCertificate(ALIAS) as X509Certificate

    fun senha(): CharArray = SENHA

    /** PEM do certificado, formato que o `pair.request` carrega no corpo. */
    fun certificadoPem(ctx: Context): String {
        val b64 = Base64.encodeToString(certificado(ctx).encoded, Base64.NO_WRAP)
        return "-----BEGIN CERTIFICATE-----\n${b64.chunked(64).joinToString("\n")}\n-----END CERTIFICATE-----\n"
    }

    /** SHA-256 do DER em hex MAIUSCULO, igual a pairing.fingerprint_from_der. */
    fun fingerprintDe(der: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(der)
            .joinToString("") { "%02X".format(it) }

    fun meuFingerprint(ctx: Context): String = fingerprintDe(certificado(ctx).encoded)

    /**
     * Codigo de 6 caracteres mostrado nos dois aparelhos.
     *
     * Ordenar os fingerprints garante o MESMO codigo dos dois lados, nao importa
     * quem iniciou. Espelha pairing.pair_code do Python: sha256(menor + maior),
     * hex minusculo, corta em 6, sobe para maiusculo.
     */
    fun pairCode(fpA: String, fpB: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest((minOf(fpA, fpB) + maxOf(fpA, fpB)).toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
            .substring(0, 6)
            .uppercase()
}
