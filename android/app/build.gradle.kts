plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

val generatedCoreKotlin = rootProject.layout.projectDirectory
    .dir("../core/dist/android/kotlin")
    .asFile
val generatedCoreJniLibs = rootProject.layout.projectDirectory
    .dir("../core/dist/android/jniLibs")
    .asFile

android {
    namespace = "com.lazarovco.budgetwarden"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.lazarovco.budgetwarden"
        minSdk = 24
        targetSdk = 37
        versionCode = 10
        versionName = "3.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            optimization {
                enable = false
            }
        }
    }
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    buildFeatures {
        compose = true
    }
    sourceSets {
        getByName("main") {
            kotlin.directories.add(
                generatedCoreKotlin.absolutePath,
            )
            jniLibs.directories.add(
                generatedCoreJniLibs.absolutePath,
            )
        }
    }
}

val verifyRustCoreBindings = tasks.register("verifyRustCoreBindings") {
    inputs.files(
        generatedCoreKotlin.resolve("com/lazarovco/budgetwarden/core/BwCore.kt"),
        generatedCoreJniLibs.resolve("arm64-v8a/libbw_core.so"),
    )
    doLast {
        check(inputs.files.files.all { it.isFile }) {
            "Rust core bindings are missing. Run .\\BuildCore.ps1 from the android directory."
        }
    }
}

tasks.named("preBuild") {
    dependsOn(verifyRustCoreBindings)
}

dependencies {
    coreLibraryDesugaring(libs.desugar.jdk.libs)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material3.adaptive.navigation.suite)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    testImplementation(libs.junit)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.junit)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
    debugImplementation(libs.androidx.compose.ui.tooling)
}
