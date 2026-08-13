import javax.inject.Inject
import org.gradle.process.ExecOperations

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.edgelink.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.edgelink.app"
        minSdk = 26
        targetSdk = 36
        versionCode = 4
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
        aidl = true
    }
}

abstract class BuildLyraSeedDexTask : DefaultTask() {
    @get:InputDirectory
    abstract val sourceDir: DirectoryProperty

    @get:Input
    abstract val sdkDir: Property<String>

    @get:Input
    abstract val compileSdk: Property<Int>

    @get:OutputDirectory
    abstract val assetsDir: DirectoryProperty

    @get:Inject
    abstract val execOps: ExecOperations

    @TaskAction
    fun build() {
        val work = temporaryDir
        work.deleteRecursively()
        val classes = File(work, "classes").apply { mkdirs() }
        val dexOut = File(work, "dex").apply { mkdirs() }
        val sdk = File(sdkDir.get())
        val androidJar = File(sdk, "platforms/android-${compileSdk.get()}/android.jar")
        val sources = sourceDir.get().asFile.walkTopDown()
            .filter { it.extension == "java" }
            .map { it.absolutePath }
            .toList()
        require(sources.isNotEmpty()) { "no lyra seed sources" }
        val javac = File(System.getProperty("java.home"), "bin/javac")
        execOps.exec {
            executable = javac.absolutePath
            args = listOf(
                "--release", "8", "-Xlint:-options", "-nowarn",
                "-cp", androidJar.absolutePath,
                "-d", classes.absolutePath
            ) + sources
        }
        val d8 = File(sdk, "build-tools").listFiles().orEmpty()
            .filter { File(it, "d8").exists() }
            .maxByOrNull { it.name }
            ?.let { File(it, "d8") }
            ?: error("d8 not found under $sdk/build-tools")
        execOps.exec {
            executable = d8.absolutePath
            args = listOf("--min-api", "26", "--output", dexOut.absolutePath) +
                classes.walkTopDown().filter { it.extension == "class" }.map { it.absolutePath }.toList()
        }
        val assets = assetsDir.get().asFile
        assets.deleteRecursively()
        assets.mkdirs()
        check(File(dexOut, "classes.dex").renameTo(File(assets, "lyra-seed.dex"))) {
            "failed to stage lyra-seed.dex"
        }
    }
}

val androidComponents =
    extensions.getByType<com.android.build.api.variant.ApplicationAndroidComponentsExtension>()
val sdkRootDir = androidComponents.sdkComponents.sdkDirectory.get().asFile.absolutePath
val appCompileSdk = extensions.getByType<com.android.build.api.dsl.ApplicationExtension>().compileSdk

val buildLyraSeedDex = tasks.register<BuildLyraSeedDexTask>("buildLyraSeedDex") {
    sourceDir.set(rootProject.file("lyraseed/src"))
    sdkDir.set(sdkRootDir)
    compileSdk.set(appCompileSdk)
    assetsDir.set(layout.buildDirectory.dir("lyraSeedAssets"))
}

androidComponents.onVariants { variant ->
    variant.sources.assets?.addGeneratedSourceDirectory(buildLyraSeedDex, BuildLyraSeedDexTask::assetsDir)
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core:1.17.0")
    implementation("androidx.security:security-crypto:1.1.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("com.goterl:lazysodium-android:5.2.0@aar")
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    implementation("io.github.webrtc-sdk:android:144.7559.09")
    implementation("net.java.dev.jna:jna:5.17.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    compileOnly("io.github.libxposed:api:102.0.0")

    debugImplementation("androidx.compose.ui:ui-tooling")

    testImplementation("junit:junit:4.13.2")
}
