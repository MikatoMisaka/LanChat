# Flutter / Android R8 规则
# 默认 proguard-android-optimize.txt 已处理大部分情况，这里只补插件相关的 keep。

# --- mobile_scanner / ML Kit ---
# R8 full mode 下会剥除未显式引用的类。ML Kit 通过反射初始化 BarcodeRegistrar，
# 被剥除会导致 BarcodeScanning.getClient() 抛 NPE（issue #1017 / #1725）。
# mobile_scanner 7.x 自带 consumer rules，这里再加固一层保险。
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.libraries.barhopper.** { *; }
-keep class com.google.photos.** { *; }
-dontwarn com.google.mlkit.**

# --- 枚举反射（部分插件通过 valueOf 反序列化枚举）---
-keepclassmembers class * extends java.lang.Enum {
    <fields>;
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
