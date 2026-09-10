import java.util.Properties
import java.util.zip.ZipFile

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.gms.google-services")
}

val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) keystorePropsFile.inputStream().use { load(it) }
}
val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val mapsApiKey = localProps.getProperty("MAPS_API_KEY", "") ?: ""

android {
    namespace = "com.example.taxi"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.taxiandfly.client"
        minSdk = 24
        targetSdk = 36
        versionCode = 33
        versionName = "1.0.31"
        resValue("string", "app_name", "Taxi and Fly")
        buildConfigField("String", "CLIENT_HTML_MARKER", "\"VPS_3_0\"")
        buildConfigField("String", "MAPS_API_KEY", "\"${mapsApiKey.replace("\\", "\\\\").replace("\"", "\\\"")}\"")
    }

    signingConfigs {
        create("release") {
            if (keystorePropsFile.exists()) {
                keyAlias = keystoreProps["keyAlias"] as String
                keyPassword = keystoreProps["keyPassword"] as String
                storeFile = file(keystoreProps["storeFile"] as String)
                storePassword = keystoreProps["storePassword"] as String
            }
        }
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
        }
    }

    sourceSets {
        getByName("main") {
            assets.srcDir("build/generated/vpsAssets")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

val vpsAssetsDir = file("build/generated/vpsAssets")

tasks.register("writeVpsBuildStamp") {
    outputs.dir(vpsAssetsDir)
    doLast {
        vpsAssetsDir.mkdirs()
        file("$vpsAssetsDir/VPS_BUILD_STAMP.txt").writeText(
            "3.0-VPS\n${System.currentTimeMillis()}\nmarker=VPS_3_0\n"
        )
    }
}

tasks.register("verifyClientAssets") {
    dependsOn("writeVpsBuildStamp")
    doLast {
        val html = file("src/main/assets/client.html").readText()
        check(!html.contains("gstatic.com/firebase")) {
            "ΠΑΛΙΟ client.html (Firebase CDN)! Άνοιξε: Desktop\\Νέος φάκελος (2)\\AndroidStudioProjects\\ClientMainActivity"
        }
        check(html.contains("taxi-rtdb-sdk.js")) { "Λείπει taxi-rtdb-sdk.js στο client.html" }
        check(html.contains("3.0 VPS")) { "Λείπει ένδειξη 3.0 VPS — λάθος project folder;" }
        check(html.contains("__CLIENT_BUILD_ID")) { "Λείπει build marker στο client.html" }
        val sdk = file("src/main/assets/taxi-rtdb-sdk.js")
        check(sdk.exists()) { "Λείπει taxi-rtdb-sdk.js στο assets/" }
    }
}

tasks.register("verifyBuiltApk") {
    dependsOn("assembleDebug")
    doLast {
        val apk = file("build/outputs/apk/debug/app-debug.apk")
        check(apk.exists()) { "Δεν βρέθηκε app-debug.apk — κάνε Build πρώτα" }
        val zip = ZipFile(apk)
        val entry = zip.getEntry("assets/client.html")
            ?: error("Το APK δεν έχει assets/client.html")
        zip.getInputStream(entry).bufferedReader(Charsets.UTF_8).use { reader ->
            val html = reader.readText()
            check(!html.contains("gstatic.com/firebase")) {
                "Το built APK έχει ΠΑΛΙΟ Firebase client.html! Κάνε Build > Clean Project > Rebuild."
            }
            check(html.contains("taxi-rtdb-sdk.js")) { "Το APK δεν έχει VPS SDK" }
            check(html.contains("3.0 VPS")) { "Το APK δεν έχει έκδοση 3.0 VPS" }
        }
        zip.close()
        logger.lifecycle("verifyBuiltApk OK: ${apk.absolutePath}")
    }
}

tasks.named("preBuild") { dependsOn("verifyClientAssets") }

afterEvaluate {
    tasks.findByName("installDebug")?.dependsOn("verifyBuiltApk")
}

dependencies {
    testImplementation("junit:junit:4.13.2")

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.google.android.libraries.places:places:3.5.0")

    // Firebase BOM (μόνο FCM push — όχι RTDB/Auth/Functions)
    implementation(platform("com.google.firebase:firebase-bom:33.1.2"))
    implementation("com.google.firebase:firebase-messaging-ktx")
}
