plugins {
    id("com.android.application")
}

android {
    namespace = "dev.onlylyan.phonelink"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.onlylyan.phonelink"
        // S23 atualizado roda bem acima disso; 31 e o piso escolhido so pra nao
        // fechar a porta caso ele instale num aparelho mais velho um dia.
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
    }

    // Os tres jars do BouncyCastle trazem o mesmo META-INF/LICENSE.md, e o
    // empacotador para o build por ambiguidade. Sao arquivos de licenca, nao
    // codigo: descartar do APK e o certo.
    packaging {
        resources {
            excludes += setOf("META-INF/LICENSE.md", "META-INF/NOTICE.md",
                              "META-INF/LICENSE", "META-INF/NOTICE",
                              "META-INF/versions/9/OSGI-INF/MANIFEST.MF")
        }
    }

    buildTypes {
        release { isMinifyEnabled = false }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    // Monta o X.509 autoassinado. O Android nao expoe API publica para isso
    // fora do AndroidKeyStore, e o AndroidKeyStore nao serve aqui (ver Crypto.kt).
    implementation("org.bouncycastle:bcpkix-jdk18on:1.85")
}
