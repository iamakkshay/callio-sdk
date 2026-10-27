// Callio Android demo: sign in, see your contacts, call, chat and share location, using the published SDK.
// Inside this repo it builds against the SDK source; in your app use the JitPack artifacts instead:
//   implementation("com.github.iamakkshay.callio-sdk:incall-sdk:<version>")
//   implementation("com.github.iamakkshay.callio-sdk:incall-ui:<version>")
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.clarigo.callio.demo"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.clarigo.callio.demo"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = file("${rootDir}/VERSION").readText().trim()
    }
    buildFeatures { compose = true }
    composeOptions { kotlinCompilerExtensionVersion = "1.5.14" }   // matches Kotlin 1.9.24
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation(project(":incall-ui"))   // brings incall-sdk with it
    val bom = platform("androidx.compose:compose-bom:2024.06.00")
    implementation(bom)
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.3")
}
