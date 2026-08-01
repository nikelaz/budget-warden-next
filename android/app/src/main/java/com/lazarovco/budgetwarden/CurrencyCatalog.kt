package com.lazarovco.budgetwarden

import java.util.Currency
import java.util.Locale

internal data class CurrencyOption(
    val code: String,
    val name: String,
) {
    val displayName: String = "$code — $name"
}

internal fun currencyOptions(locale: Locale = Locale.getDefault()): List<CurrencyOption> =
    Currency.getAvailableCurrencies()
        .map { currency ->
            CurrencyOption(
                code = currency.currencyCode,
                name = currency.getDisplayName(locale),
            )
        }
        .sortedBy(CurrencyOption::code)
