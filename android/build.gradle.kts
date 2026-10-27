// incall-sdk: the native Android SDK for the Callio platform (calls, chat, location, Telecom ringing).
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

// WebRTC (the on-device media engine in webrtc/) is built in by default, which is what a calling app needs.
// `-PnoWebRtc` builds only the pure-Kotlin core (registration and chat), for the fast JVM unit tests.
val withWebRtc = !providers.gradleProperty("noWebRtc").isPresent

android {
    namespace = "com.ngx.incall"
    compileSdk = 34

    defaultConfig {
        minSdk = 24            // Android 7; ConnectionService self-managed calls need 26+ at runtime
        consumerProguardFiles("consumer-rules.pro")
    }

    if (withWebRtc) sourceSets["main"].java.srcDir("webrtc")
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    testOptions { unitTests.isReturnDefaultValues = true }   // tolerate android.jar stubs in JVM tests
    publishing { singleVariant("release") { withSourcesJar() } }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.json:json:20240303")
    // libwebrtc (the maintained webrtc-sdk build of Google's libwebrtc), for the media layer.
    if (withWebRtc) implementation("io.github.webrtc-sdk:android:125.6422.07")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
    testImplementation("org.json:json:20240303")   // real org.json on the unit-test classpath
}

publishing {
    publications {
        register<MavenPublication>("release") {
            artifactId = "incall-sdk"
            afterEvaluate { from(components["release"]) }
        }
    }
}
