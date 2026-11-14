# frozen_string_literal: true

# Read-only client for the MEXC spot V3 REST API.
#
# Only GET endpoints are exposed. Unlike Bybit and OKX, MEXC offers no endpoint
# that reports the permissions of the key making the request, so a key that can
# trade or withdraw cannot be refused here; the setup instructions ask for
# Account Read only and the panel says so.
class Provider::Mexc
  include HTTParty
  include Provider::RateLimitable
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class PermissionError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end
  class InvalidSymbolError < ApiError; end

  # Account endpoints share a budget of 500 weight per 10 seconds and
  # myTrades costs 10, so one call every 0.25s stays well inside it.
  MIN_REQUEST_INTERVAL = 0.25

  # Pipelock false positive: instance variables named after credentials next to a
  # URL constant are read as "user:password@host".
  BASE_URL = "https://api.mexc.com"

  RECV_WINDOW = "5000"

  AUTH_ERROR_CODES = [ 602, 700001, 700002 ].freeze
  PERMISSION_ERROR_CODES = [ 700006, 700007 ].freeze # IP not whitelisted, no permission for the endpoint
  INVALID_SYMBOL_CODES = [ 10007, 30014, 30021 ].freeze

  # myTrades answers at most 100 trades and only covers the past month.
  TRADES_PAGE_LIMIT = 100
  TRADES_HISTORY_MS = 30 * 24 * 60 * 60 * 1000
  # The span of one startTime..endTime request. The docs state no maximum, so
  # stay at a week.
  TRADES_WINDOW_MS = 7 * 24 * 60 * 60 * 1000
  MAX_TRADE_PAGES = 100

  # Deposit and withdrawal history needs the key's withdraw-read permission, goes
  # back 90 days, and answers for a 7 day default span.
  RECORD_WINDOW_MS = 7 * 24 * 60 * 60 * 1000
  RECORD_HISTORY_MS = 90 * 24 * 60 * 60 * 1000

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret

  def initialize(api_key:, api_secret:)
    @api_key = api_key # pipelock:ignore user-supplied MEXC credential kept in memory for signed requests
    @api_secret = api_secret # pipelock:ignore user-supplied MEXC credential kept in memory for signed requests
  end

  # Spot balances: { "balances" => [ { "asset", "free", "locked" } ], ... }
  def get_account
    signed_get("/api/v3/account")
  end

  # Trades for one symbol such as "BTCUSDT" inside [start_time, end_time] (ms),
  # advancing past a full page until the window is exhausted. Raises
  # InvalidSymbolError for a pair MEXC does not list.
  def get_my_trades(symbol, start_time:, end_time:)
    trades = []
    cursor = start_time

    MAX_TRADE_PAGES.times do
      window_end = [ cursor + TRADES_WINDOW_MS - 1, end_time ].min
      page = signed_get("/api/v3/myTrades", params: {
        "symbol" => symbol, "startTime" => cursor.to_s, "endTime" => window_end.to_s, "limit" => TRADES_PAGE_LIMIT.to_s
      })
      trades.concat(page)

      if page.size >= TRADES_PAGE_LIMIT
        # A full page may have more behind it inside the same window.
        cursor = page.map { |trade| trade["time"].to_i }.max + 1
      else
        cursor = window_end + 1
      end

      return trades if cursor > end_time
    end

    raise ApiError, "MEXC trade history for #{symbol} exceeded #{MAX_TRADE_PAGES} requests"
  end

  # Deposits inside one window of at most RECORD_WINDOW_MS. status 5 (success) and
  # 12 (completed) put coins on the account.
  def get_deposit_history(start_time:, end_time:)
    signed_get("/api/v3/capital/deposit/hisrec", params: { "startTime" => start_time.to_i.to_s, "endTime" => end_time.to_i.to_s, "limit" => "1000" })
  end

  # Withdrawals inside one window of at most RECORD_WINDOW_MS. status 7 is a
  # completed withdrawal.
  def get_withdraw_history(start_time:, end_time:)
    signed_get("/api/v3/capital/withdraw/history", params: { "startTime" => start_time.to_i.to_s, "endTime" => end_time.to_i.to_s, "limit" => "1000" })
  end

  # Public endpoint. Every symbol's last price in one request, as { "BTCUSDT" => "60000" }.
  def get_all_prices
    public_get("/api/v3/ticker/price").to_h { |row| [ row["symbol"], row["price"] ] }
  rescue Error => e
    Rails.logger.warn("Provider::Mexc: no prices: #{e.message}")
    {}
  end

  # Public endpoint. Last traded price for a symbol such as "BTCUSDT", or nil.
  def get_spot_price(symbol)
    public_get("/api/v3/ticker/price", params: { "symbol" => symbol })["price"].presence
  rescue Error => e
    Rails.logger.warn("Provider::Mexc: no price for #{symbol}: #{e.message}")
    nil
  end

  # Public endpoint. Close of the daily candle containing `date`, or nil.
  def get_historical_price(symbol, date)
    start_ms = date.to_time.utc.beginning_of_day.to_i * 1000
    candles = public_get("/api/v3/klines", params: {
      "symbol" => symbol, "interval" => "1d", "startTime" => start_ms.to_s, "limit" => "1"
    })
    candles.dig(0, 4).presence # [openTime, open, high, low, close, ...]
  rescue Error => e
    Rails.logger.warn("Provider::Mexc: no historical price for #{symbol} on #{date}: #{e.message}")
    nil
  end

  private

    def signed_get(path, params: {})
      throttle_request

      query = URI.encode_www_form(params.merge("timestamp" => (Time.current.to_f * 1000).to_i.to_s, "recvWindow" => RECV_WINDOW).sort)
      signature = OpenSSL::HMAC.hexdigest("sha256", api_secret, query)

      handle_response(self.class.get(path, query: "#{query}&signature=#{signature}", headers: { "X-MEXC-APIKEY" => api_key }))
    end

    def public_get(path, params: {})
      throttle_request

      handle_response(self.class.get(path, query: URI.encode_www_form(params.sort)))
    end

    def handle_response(response)
      parsed = response.parsed_response

      case response.code
      when 200..299
        # Some failures arrive as 200 with a code in the body.
        raise_for_code(parsed) if parsed.is_a?(Hash) && parsed["code"].to_i != 0 && parsed.key?("msg")
        parsed
      when 401
        raise AuthenticationError, error_message(parsed) || "Unauthorized"
      when 418, 429
        raise RateLimitError, "Rate limit exceeded"
      else
        raise_for_code(parsed, fallback: "API error: #{response.code}")
      end
    end

    def raise_for_code(parsed, fallback: "MEXC error")
      code = parsed.is_a?(Hash) ? parsed["code"].to_i : 0
      message = error_message(parsed) || fallback

      raise AuthenticationError, message if AUTH_ERROR_CODES.include?(code)
      raise PermissionError, message if PERMISSION_ERROR_CODES.include?(code)
      raise InvalidSymbolError, message if INVALID_SYMBOL_CODES.include?(code)

      raise ApiError, message
    end

    def error_message(parsed)
      return parsed if parsed.is_a?(String)
      return nil unless parsed.is_a?(Hash)

      parsed["msg"] || parsed["message"]
    end
end
