# ProGuard/R8 rules consumed by apps that depend on incall-sdk. None needed yet; keep the SDK's
# public API intact if the consuming app minifies.
-keep public class com.ngx.incall.** { public *; }
