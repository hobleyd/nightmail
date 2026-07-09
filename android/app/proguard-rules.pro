# WorkManager uses Room under the hood; R8 strips the generated
# WorkDatabase_Impl no-arg constructor without this rule.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }

# Keep Room @Database implementations generally
-keep @androidx.room.Database class * { *; }
