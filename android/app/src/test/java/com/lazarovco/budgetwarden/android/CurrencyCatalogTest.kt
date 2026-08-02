package com.lazarovco.budgetwarden.android

import com.google.common.truth.Truth.assertThat
import java.util.Locale
import org.junit.Test

internal class CurrencyCatalogTest {
    @Test
    fun optionsIncludeCodeAndLocalizedName() {
        val usd = currencyOptions(Locale.US).first { it.code == "USD" }

        assertThat(usd.displayName).isEqualTo("USD — US Dollar")
    }
}
