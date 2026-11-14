# frozen_string_literal: true

# Converts USD amounts to the family's base currency at the dated official rate.
# ExchangeRate.find_or_fetch_rate falls back to the nearest earlier rate; when it
# does (or finds none) the result is flagged stale in account.extra["mexc"].
module MexcAccount::UsdConverter
  private

    # @return [Array(BigDecimal, Boolean, Date|nil)] [amount, stale, rate_date_used]
    def convert_from_usd(amount, date: Date.current)
      return [ amount.to_d, false, nil ] if target_currency == "USD"

      rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: target_currency, date: date)
      return [ amount.to_d, true, nil ] if rate.nil?

      converted = Money.new(amount, "USD").exchange_to(target_currency, custom_rate: rate.rate).amount
      stale = rate.date != date

      [ converted, stale, stale ? rate.date : nil ]
    end

    def build_stale_extra(stale, rate_date, target_date)
      mexc_meta = if stale
        { "stale_rate" => true, "rate_date_used" => rate_date&.to_s, "rate_target_date" => target_date.to_s }
      else
        { "stale_rate" => false }
      end

      { "mexc" => mexc_meta }
    end
end
