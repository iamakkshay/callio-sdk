plugins {
    id("com.android.library") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}

allprojects {
    group = "com.github.iamakkshay.callio-sdk"
    version = file("${rootDir}/VERSION").readText().trim()
}
