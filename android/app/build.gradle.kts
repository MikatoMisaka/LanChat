import java.io.FileInputStream
import java.util.Properties

val signingPropertiesFile = rootProject.file("key.properties")
val signingProperties = Properties()
if (signingPropertiesFile.exists()) {
    FileInputStream(signingPropertiesFile).use(signingProperties::load)
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.lanchat"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.lanchat"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (signingPropertiesFile.exists()) {
                storeFile = rootProject.file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (signingPropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            // R8 代码裁剪 + 资源压缩。
            // 关键：移除 jniLibs.keepDebugSymbols，让 AGP 用 NDK 裁剪原生库符号表
            // （libflutter.so 从 157MB 未裁剪 -> ~10MB），APK 体积从 ~174MB 降到 ~30MB。
            // 不用 unbundled ML Kit：国内无 GMS 的设备扫码会直接挂。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

tasks.matching { it.name == "validateSigningRelease" }.configureEach {
    doFirst {
        if (!signingPropertiesFile.exists()) {
            throw GradleException(
                "android/key.properties is required for a release build. " +
                    "Copy android/key.properties.example and fill it locally."
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // mobile_scanner 的 ML Kit 在部分设备上 MlKitInitProvider 未完成初始化，
    // 导致 BarcodeScanning.getClient() 抛 NPE。显式引入 common 以便在
    // MainActivity 中手动调用 MlKit.initialize() 兜底（幂等）。
    implementation("com.google.mlkit:common:18.9.0")
}
