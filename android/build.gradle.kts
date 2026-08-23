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

// 修复旧版插件用低 compileSdk 导致的 AAR metadata 校验失败：
//
// 例：desktop_drop 0.6.1 的 android/build.gradle 硬编码 `compileSdk 33`，但它引入的
// AndroidX 依赖（fragment/window/activity/core-ktx 等）要求编译目标至少 SDK 34+，
// 从而在 `:desktop_drop:checkReleaseAarMetadata` 报「requires libraries and applications
// that depend on it to compile against version 34 or later」。
//
// 统一把「应用/插件」全部 Android 库子项目的 compileSdk 提平为 Flutter 默认值
// （当前 SDK 为 36，满足 ≥34），与 app 通过 `flutter.compileSdkVersion` 使用的版本一致。
// 注：`:app` 会因 `evaluationDependsOn` / Flutter 插件被提前求值，故用
// `!project.state.executed` 只对尚未求值的子项目注册 afterEvaluate。
subprojects {
    if (!project.state.executed) {
        afterEvaluate {
            plugins.withId("com.android.library") {
                extensions.findByType(com.android.build.gradle.BaseExtension::class.java)
                    ?.apply { compileSdkVersion(36) }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
