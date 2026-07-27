allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// The transitive `jni` package (pulled in by path_provider_android) assumes that
// on AGP 9 the built-in Kotlin support is enabled, so it only applies the
// `kotlin-android` plugin when the AGP major version is < 9. This project opts out
// of built-in Kotlin (`android.builtInKotlin=false` in gradle.properties), which
// leaves `:jni`'s bare `kotlin { }` block with no Kotlin DSL and the build fails
// with "Could not find method kotlin()". Apply the standalone Kotlin plugin to that
// module ourselves — mirroring what the Flutter tooling already does for `:app`.
subprojects {
    if (name == "jni") {
        apply(plugin = "org.jetbrains.kotlin.android")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
