plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
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
        versionCode = 1
        versionName = "0.3.0"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
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
