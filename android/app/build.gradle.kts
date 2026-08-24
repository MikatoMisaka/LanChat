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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
