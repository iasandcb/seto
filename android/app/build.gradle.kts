import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

fun configured(name: String): String? {
    // Environment wins so a checked-in gradle.properties cannot override CI secrets.
    // With a warm Gradle daemon, stop it before changing these variables.
    System.getenv(name)?.takeIf { it.isNotBlank() }?.let { return it }
    return findProperty(name)?.toString()?.takeIf { it.isNotBlank() }
}

val setoVersionName = configured("SETO_VERSION_NAME") ?: "0.3.0"
val setoVersionCode = configured("SETO_VERSION_CODE")?.let { raw ->
    raw.toIntOrNull() ?: throw GradleException("SETO_VERSION_CODE is not an integer")
} ?: 1
if (setoVersionCode < 1) {
    throw GradleException("SETO_VERSION_CODE must be a positive integer")
}

val releaseKeystorePath = configured("ANDROID_KEYSTORE_PATH")
val releaseKeystorePassword = configured("ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = configured("ANDROID_KEY_ALIAS")
val releaseKeyPassword = configured("ANDROID_KEY_PASSWORD")
val releaseKeystoreType = configured("ANDROID_KEYSTORE_TYPE") ?: "PKCS12"
val releaseKeystoreFile = if (releaseKeystorePath == null) {
    null
} else {
    val missing = listOf(
        "ANDROID_KEYSTORE_PASSWORD" to releaseKeystorePassword,
        "ANDROID_KEY_ALIAS" to releaseKeyAlias,
        "ANDROID_KEY_PASSWORD" to releaseKeyPassword,
    ).filter { it.second.isNullOrBlank() }.map { it.first }
    if (missing.isNotEmpty()) {
        throw GradleException(
            "Release signing is incomplete. Missing: ${missing.joinToString(", ")}",
        )
    }
    file(releaseKeystorePath).also { store ->
        if (!store.isFile) {
            throw GradleException("ANDROID_KEYSTORE_PATH is not a file: $releaseKeystorePath")
        }
    }
}

val generated = layout.buildDirectory.dir("generated/seto")
val buildRust by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir)
    commandLine("bash", "scripts/build-rust.sh", generated.get().asFile.absolutePath)
    inputs.dir("../../core-rs/seto-core/src")
    inputs.dir("../../core-rs/seto-ffi")
    inputs.file("../../core-rs/Cargo.toml")
    inputs.file("../../core-rs/Cargo.lock")
    outputs.dirs(generated.map { it.dir("jniLibs") }, generated.map { it.dir("kotlin") })
}
val stageLexicon by tasks.registering(Sync::class) {
    into(generated.map { it.dir("assets/lexicon") })
    from("../../iOS/Keyboard/Resources") {
        include("keyboard-english.txt", "keyboard-korean-valid.txt")
    }
    from("../../Resources") { include("korean-words.txt", "korean-valid.LICENSE") }
}
android {
    namespace = "com.ias.seto"
    compileSdk = 35
    ndkVersion = "28.2.13676358"
    defaultConfig {
        applicationId = "com.ias.seto"
        minSdk = 34
        targetSdk = 35
        versionCode = setoVersionCode
        versionName = setoVersionName
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    signingConfigs {
        if (releaseKeystoreFile != null) {
            create("release") {
                storeFile = releaseKeystoreFile
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                storeType = releaseKeystoreType
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }
    buildTypes {
        release {
            // UniFFI loads libseto_ffi through JNA. R8 strips that JNI glue, so
            // the release APK stays unminified.
            isMinifyEnabled = false
            isShrinkResources = false
            if (releaseKeystoreFile != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
    sourceSets["main"].apply {
        java.srcDir(generated.map { it.dir("kotlin") })
        jniLibs.srcDir(generated.map { it.dir("jniLibs") })
        assets.srcDir(generated.map { it.dir("assets") })
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    packaging { jniLibs.useLegacyPackaging = false }
    testOptions { unitTests.isReturnDefaultValues = true }
}
tasks.named("preBuild") { dependsOn(buildRust, stageLexicon) }
dependencies {
    implementation("androidx.annotation:annotation:1.9.1")
    implementation("net.java.dev.jna:jna:5.17.0@aar")
    testImplementation("junit:junit:4.13.2")
}
