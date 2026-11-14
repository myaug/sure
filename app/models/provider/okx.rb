# frozen_string_literal: true

# Read-only client for the OKX V5 REST API.
#
# Only GET endpoints are exposed and the key is verified to carry neither trade
# nor withdraw permission before anything is imported (see #read_only_key!).
class Provider::Okx
  include HTTParty
  include Provider::RateLimitable
  include Provider::ExchangePriceCache
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class PermissionError < Error; end
  class WritePermissionError < PermissionError; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  # fills-history allows 10 requests per 2 seconds.
  MIN_REQUEST_INTERVAL = 0.25

  # Pipelock false positive: instance variables named after credentials next to a
  # URL constant are read as "user:password@host".
  BASE_URL = "https://www.okx.com"

  # `code` values OKX answers with HTTP 200.
  AUTH_ERROR_CODES = %w[50100 50101 50103 50104 50105 50106 50107 50111 50112 50113 50114].freeze
  PERMISSION_ERROR_CODES = %w[50110 50120].freeze # IP not whitelisted, key lacks permission
  RATE_LIMIT_ERROR_CODES = %w[50011 50061].freeze

  # fills-history keeps three months of history.
  FILLS_HISTORY_MS = 90 * 24 * 60 * 60 * 1000
  FILLS_PAGE_LIMIT = 100
  MAX_FILL_PAGES = 200

  # Deposit and withdrawal history, newest first, 100 a page.
  RECORD_PAGE_LIMIT = 100
  MAX_RECORD_PAGES = 100
  # OKX documents no retention for these two endpoints; ask for what the caller
  # needs and no more than two years back.
  RECORD_HISTORY_MS = 2 * 365 * 24 * 60 * 60 * 1000

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret, :api_passphrase

  def initialize(api_key:, api_secret:, api_passphrase:)
    @api_key = api_key # pipelock:ignore user-supplied OKX credential kept in memory for signed requests
    @api_secret = api_secret # pipelock:ignore user-supplied OKX credential kept in memory for signed requests
    @api_passphrase = api_passphrase # pipelock:ignore user-supplied OKX credential kept in memory for signed requests
  end

  # Permissions of the key being used, e.g. "read_only" or "read_only,trade".
  def get_account_config
    signed_get("/api/v5/account/config").first || {}
  end

  # Raises WritePermissionError unless the key carries read-only and nothing else.
  def read_only_key!
    perms = get_account_config["perm"].to_s.split(",").map(&:strip)
    return perms if perms == [ "read_only" ]

    raise WritePermissionError, "OKX API key has #{(perms - [ "read_only" ]).join(", ").presence || "unknown"} permission; create a read-only key"
  end

  # Trading account. details[] carries ccy, cashBal and eqUsd per coin.
  def get_trading_balances
    signed_get("/api/v5/account/balance").first || {}
  end

  # Funding account. Each entry carries ccy and bal, no USD value.
  def get_funding_balances
    signed_get("/api/v5/asset/balances")
  end

  # Spot fills from `begin_time` (ms) on, newest first, following billId
  # pagination to the end.
  def get_spot_fills(begin_time:)
    fills = []
    after = nil

    MAX_FILL_PAGES.times do
      params = { "instType" => "SPOT", "begin" => begin_time.to_i.to_s, "limit" => FILLS_PAGE_LIMIT.to_s }
      params["after"] = after if after

      page = signed_get("/api/v5/trade/fills-history", params: params)
      fills.concat(page)
      return fills if page.size < FILLS_PAGE_LIMIT

      after = page.last["billId"]
    end

    raise ApiError, "OKX fill history exceeded #{MAX_FILL_PAGES} pages"
  end

  # Deposits newer than `begin_time` (ms). state 1 (credited) and 2 (successful)
  # are the ones that moved coins.
  def get_deposit_history(begin_time:)
    records("/api/v5/asset/deposit-history", begin_time)
  end

  # Withdrawals newer than `begin_time` (ms). state "2" is a completed withdrawal.
  def get_withdrawal_history(begin_time:)
    records("/api/v5/asset/withdrawal-history", begin_time)
  end

  # Public endpoint. Last traded price for e.g. "BTC-USDT", or nil.
  def get_spot_price(inst_id)
    cached_spot_price(inst_id) do
      public_get("/api/v5/market/ticker", params: { "instId" => inst_id }).dig(0, "last").presence
    end
  rescue Error => e
    Rails.logger.warn("Provider::Okx: no price for #{inst_id}: #{e.message}")
    nil
  end

  # Public endpoint. Close of the daily candle containing `date`, or nil.
  def get_historical_price(inst_id, date)
    cached_historical_price(inst_id, date) do
      # history-candles returns candles older than `after`, so ask for the one
      # that closes at the end of the requested day.
      day_end = date.to_time.utc.beginning_of_day.to_i * 1000 + 24 * 60 * 60 * 1000
      public_get("/api/v5/market/history-candles", params: {
        "instId" => inst_id, "bar" => "1Dutc", "after" => day_end.to_s, "limit" => "1"
      }).dig(0, 4).presence # [ts, open, high, low, close, ...]
    end
  rescue Error => e
    Rails.logger.warn("Provider::Okx: no historical price for #{inst_id} on #{date}: #{e.message}")
    nil
  end

  private

    # Newest first: `before` bounds the oldest record wanted, `after` carries the
    # timestamp of the oldest one seen so far to the next page.
    def records(path, begin_time)
      rows = []
      after = nil

      MAX_RECORD_PAGES.times do
        params = { "before" => begin_time.to_i.to_s, "limit" => RECORD_PAGE_LIMIT.to_s }
        params["after"] = after if after

        page = signed_get(path, params: params)
        rows.concat(page)
        return rows if page.size < RECORD_PAGE_LIMIT

        after = page.last["ts"]
      end

      raise ApiError, "OKX #{path} exceeded #{MAX_RECORD_PAGES} pages"
    end

    def signed_get(path, params: {})
      throttle_request

      request_path = params.empty? ? path : "#{path}?#{URI.encode_www_form(params.sort)}"
      timestamp = Time.current.utc.iso8601(3)

      handle_response(self.class.get(request_path, headers: auth_headers(timestamp, request_path)))
    end

    def public_get(path, params: {})
      throttle_request

      handle_response(self.class.get("#{path}?#{URI.encode_www_form(params.sort)}"))
    end

    # The prehash is timestamp + method + requestPath (query included) + body.
    def auth_headers(timestamp, request_path)
      prehash = "#{timestamp}GET#{request_path}"

      {
        "OK-ACCESS-KEY" => api_key,
        "OK-ACCESS-SIGN" => Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", api_secret, prehash)),
        "OK-ACCESS-TIMESTAMP" => timestamp,
        "OK-ACCESS-PASSPHRASE" => api_passphrase,
        "Content-Type" => "application/json"
      }
    end

    # OKX reports most failures as HTTP 200 with a non-zero `code`.
    def handle_response(response)
      parsed = response.parsed_response

      case response.code
      when 200..299
        unwrap(parsed)
      when 401
        raise AuthenticationError, error_message(parsed) || "Unauthorized"
      when 429
        raise RateLimitError, "Rate limit exceeded"
      else
        raise ApiError, error_message(parsed) || "API error: #{response.code}"
      end
    end

    def unwrap(parsed)
      raise ApiError, "Unexpected OKX response" unless parsed.is_a?(Hash)

      code = parsed["code"].to_s
      return Array(parsed["data"]) if code == "0"

      message = parsed["msg"].presence || "OKX error #{code}"
      raise AuthenticationError, message if AUTH_ERROR_CODES.include?(code)
      raise PermissionError, message if PERMISSION_ERROR_CODES.include?(code)
      raise RateLimitError, message if RATE_LIMIT_ERROR_CODES.include?(code)

      raise ApiError, message
    end

    def error_message(parsed)
      return parsed if parsed.is_a?(String)
      return nil unless parsed.is_a?(Hash)

      parsed["msg"] || parsed["message"]
    end
end
