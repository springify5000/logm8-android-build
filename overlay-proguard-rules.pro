# LogM8 Android release keep rules (R8). build.sh copies this file to android/app/proguard-rules.pro.
# Most libraries ship their own consumer rules (Capacitor core, RevenueCat, Billing, Firebase, WorkManager);
# the rules below are a safety net for the parts that are reached by reflection or by name.

# Readable stack traces in Play crash reports (the AAB carries the mapping file)
-keepattributes SourceFile,LineNumberTable,*Annotation*,Signature,InnerClasses,EnclosingMethod
-renamesourcefileattribute SourceFile

# Capacitor bridge: plugins and their methods are looked up by annotation/name from JavaScript
-keep @com.getcapacitor.annotation.CapacitorPlugin public class * {
    @com.getcapacitor.annotation.PermissionCallback <methods>;
    @com.getcapacitor.annotation.ActivityCallback <methods>;
    @com.getcapacitor.annotation.Permission <methods>;
    @com.getcapacitor.PluginMethod public <methods>;
}
-keep public class * extends com.getcapacitor.Plugin { *; }
-keepclassmembers class * { @android.webkit.JavascriptInterface <methods>; }

# Native Google Sign-In (Credential Manager loads the Play Services provider by class name)
-if class androidx.credentials.CredentialManager
-keep class androidx.credentials.playservices.** { *; }
-keep class com.google.android.libraries.identity.googleid.** { *; }
-dontwarn com.google.android.libraries.identity.googleid.**

# RevenueCat + Play Billing (extra safety on top of their consumer rules)
-keep class com.revenuecat.purchases.** { *; }
-keep class com.android.billingclient.** { *; }
-dontwarn com.android.billingclient.**

# LogM8's own native code (owner widget + its WorkManager worker): WorkManager stores the worker
# class name in its database, so these names must not change between releases
-keep class au.com.logm8.app.** { *; }
-keep public class * extends android.appwidget.AppWidgetProvider { *; }
