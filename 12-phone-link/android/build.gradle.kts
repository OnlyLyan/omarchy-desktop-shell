plugins {
    // AGP 9 ja traz suporte a Kotlin embutido. Declarar
    // org.jetbrains.kotlin.android junto vira ERRO de build, nao aviso.
    id("com.android.application") version "9.3.1" apply false
}
