// Puts the Kotlin Gradle plugin on this script's classpath (without applying
// it here) so the subprojects override below can reference its API types.
plugins {
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

subprojects {
    // sentry_flutter (8.x/9.x) hardcodes Kotlin languageVersion "1.6" in its
    // Android module, which the Kotlin 2.3 compiler this Flutter version uses
    // no longer accepts ("Language version 1.6 is no longer supported").
    // Upgrade the language version of every Kotlin/Android subproject after
    // its own build file has run, so legacy plugin modules still compile.
    plugins.withId("org.jetbrains.kotlin.android") {
        project.afterEvaluate {
            extensions
                .findByType(
                    org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension::class.java,
                )
                ?.compilerOptions
                ?.languageVersion
                ?.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_0)
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
