# frozen_string_literal: true

# Public exchange prices are the same for every connection, but each
# connection syncs with its own client, so several accounts on one exchange ask
# for the same prices again from one server IP and run into its rate limit
# sooner. This shares the answers through Rails.cache, per exchange.
#
# Only prices are cached: a failed or empty lookup is asked again next time.
module Provider::ExchangePriceCache
  SPOT_TTL = 1.minute
  # A day's candle is final once the day has passed in UTC; until then it moves.
  CLOSED_CANDLE_TTL = 7.days
  OPEN_CANDLE_TTL = 5.minutes

  private

    def cached_spot_price(symbol, &block)
      cached_price([ "spot", symbol ], SPOT_TTL, &block)
    end

    def cached_historical_price(symbol, date, &block)
      day = date.to_date
      ttl = day < Time.now.utc.to_date ? CLOSED_CANDLE_TTL : OPEN_CANDLE_TTL

      cached_price([ "candle", symbol, day.iso8601 ], ttl, &block)
    end

    def cached_price(parts, ttl, &block)
      Rails.cache.fetch([ "exchange_price", self.class.name.demodulize.underscore, *parts ], expires_in: ttl, skip_nil: true, &block)
    end
end
