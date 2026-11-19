-keepattributes Signature,InnerClasses,EnclosingMethod

# LiteRT-LM 0.18.1 resolves callbacks and configuration getters by JNI name.
# Its AAR has no consumer rules for these Kotlin classes.
-keep class com.google.ai.edge.litertlm.** { *; }

