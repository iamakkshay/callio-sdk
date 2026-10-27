// Callio Android SDK: the core library (incall-sdk) and the ready-made Compose screens (incall-ui).
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "callio-sdk"
include(":incall-sdk", ":incall-ui")
project(":incall-sdk").projectDir = file("android")
project(":incall-ui").projectDir = file("android-ui")
