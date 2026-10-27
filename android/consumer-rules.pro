# ProGuard/R8 rules consumed by apps that depend on incall-sdk. None needed yet; keep the SDK's
# public API intact if the consuming app minifies.
-keep public class com.ngx.incall.** { public *; }
# InCallClient loads the WebRTC transport by name, so keep it and its constructor.
-keep class com.ngx.incall.WebRtcSignallingSipTransport { <init>(android.content.Context); }
