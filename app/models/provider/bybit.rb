# frozen_string_literal: true

# Read-only client for the Bybit V5 REST API.
#
# Only GET endpoints are exposed and the key is verified to carry no write
# permission before anything is imported (see #read_only_key!), so a leaked
# credential here can neither trade nor withdraw.
class Provider::Bybit
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class PermissionError < Error; end
  class WritePermissionError < PermissionError; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  # Pipelock false positive: instance variables named after credentials next to a
  # URL constant are read as "user:password@host".
  BASE_URL = "https://api.bybit.com"

  RECV_WINDOW = "5000"

  # retCode values Bybit answers with HTTP 200.
  AUTH_ERROR_CODES = [ 10003, 10004, 10007, 33004 ].freeze # invalid key, bad signature, auth failed, key expired
  PERMISSION_ERROR_CODES = [ 10005, 10010 ].freeze         # permission denied, IP not whitelisted
  RATE_LIMIT_ERROR_CODES = [ 10006, 10018 ].freeze

  # /v5/execution/list answers for at most 7 days per request and keeps two
  # years of spot history.
  EXECUTION_WINDOW_MS = 7 * 24 * 60 * 60 * 1000
  EXECUTION_HISTORY_MS = 2 * 365 * 24 * 60 * 60 * 1000
  EXECUTION_PAGE_LIMIT = 100
  MAX_EXECUTION_PAGES = 200

  # Deposit and withdrawal records: at most 30 days per request, two years kept.
  RECORD_WINDOW_MS = 30 * 24 * 60 * 60 * 1000
  RECORD_HISTORY_MS = 2 * 365 * 24 * 60 * 60 * 1000
  RECORD_PAGE_LIMIT = 50
  MAX_RECORD_PAGES = 100

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret

  def initialize(api_key:, api_secret:)
    @api_key = api_key # pipelock:ignore user-supplied Bybit credential kept in memory for signed requests
    @api_secret = api_secret # pipelock:ignore user-supplied Bybit credential kept in memory for signed requests
  end

  # Permissions of the key being used. `readOnly` is 1 for a read-only key.
  def get_api_key_info
    signed_get("/v5/user/query-api")
  end

  # Raises WritePermissionError unless the key is strictly read-only.
  def read_only_key!
    info = get_api_key_info
    return info if info.is_a?(Hash) && info["readOnly"].to_i == 1

    raise WritePermissionError, "Bybit API key has write permissions; create a read-only key"
  end

  # Unified trading account. Each coin carries `walletBalance` and `usdValue`.
  def get_unified_balances
    signed_get("/v5/account/wallet-balance", params: { "accountType" => "UNIFIED" })
  end

  # Funding account. Balances carry no USD value.
  def get_fund_balances
    signed_get("/v5/asset/transfer/query-account-coins-balance", params: { "accountType" => "FUND" })
  end

  # Spot executions inside one window of at most EXECUTION_WINDOW_MS, following
  # the cursor to the end of it.
  def get_spot_executions(start_time:, end_time:)
    executions = []
    cursor = nil

    MAX_EXECUTION_PAGES.times do
      params = {
        "category" => "spot",
        "startTime" => start_time.to_i.to_s,
        "endTime" => end_time.to_i.to_s,
        "limit" => EXECUTION_PAGE_LIMIT.to_s
      }
      params["cursor"] = cursor if cursor.present?

      result = signed_get("/v5/execution/list", params: params)
      executions.concat(Array(result["list"]))

      cursor = result["nextPageCursor"].presence
      return executions if cursor.nil?
    end

    raise ApiError, "Bybit execution history exceeded #{MAX_EXECUTION_PAGES} pages for one window"
  end

  # Deposits credited inside one window of at most RECORD_WINDOW_MS. status 3 is
  # a successful deposit.
  def get_deposit_records(start_time:, end_time:)
    records("/v5/asset/deposit/query-record", start_time, end_time)
  end

  # Withdrawals requested inside one window of at most RECORD_WINDOW_MS. status
  # "success" is a completed withdrawal.
  def get_withdraw_records(start_time:, end_time:)
    records("/v5/asset/withdraw/query-record", start_time, end_time)
  end

  # Public endpoint. Last traded price for a spot symbol such as "BTCUSDT", or nil.
  def get_spot_price(symbol)
    result = public_get("/v5/market/tickers", params: { "category" => "spot", "symbol" => symbol })
    result.dig("list", 0, "lastPrice").presence
  rescue Error => e
    Rails.logger.warn("Provider::Bybit: no price for #{symbol}: #{e.message}")
    nil
  end

  # Public endpoint. Close of the daily candle containing `date`, or nil.
  def get_historical_price(symbol, date)
    start_ms = date.to_time.utc.beginning_of_day.to_i * 1000
    result = public_get("/v5/market/kline", params: {
      "category" => "spot", "symbol" => symbol, "interval" => "D",
      "start" => start_ms.to_s, "end" => (start_ms + 24 * 60 * 60 * 1000 - 1).to_s, "limit" => "1"
    })
    # [startTime, open, high, low, close, volume, turnover]
    result.dig("list", 0, 4).presence
  rescue Error => e
    Rails.logger.warn("Provider::Bybit: no historical price for #{symbol} on #{date}: #{e.message}")
    nil
  end

  private

    def records(path, start_time, end_time)
      rows = []
      cursor = nil

      MAX_RECORD_PAGES.times do
        params = { "startTime" => start_time.to_i.to_s, "endTime" => end_time.to_i.to_s, "limit" => RECORD_PAGE_LIMIT.to_s }
        params["cursor"] = cursor if cursor.present?

        result = signed_get(path, params: params)
        rows.concat(Array(result["rows"]))

        cursor = result["nextPageCursor"].presence
        return rows if cursor.nil?
      end

      raise ApiError, "Bybit #{path} exceeded #{MAX_RECORD_PAGES} pages for one window"
    end

    def signed_get(path, params: {})
      query = URI.encode_www_form(params.sort)
      timestamp = (Time.current.to_f * 1000).to_i.to_s

      response = self.class.get(path, query: query, headers: auth_headers(timestamp, query))
      handle_response(response)
    end

    def public_get(path, params: {})
      handle_response(self.class.get(path, query: URI.encode_www_form(params.sort)))
    end

    # V5 signs timestamp + apiKey + recvWindow + the exact query string sent.
    def auth_headers(timestamp, query)
      payload = "#{timestamp}#{api_key}#{RECV_WINDOW}#{query}"

      {
        "X-BAPI-API-KEY" => api_key,
        "X-BAPI-TIMESTAMP" => timestamp,
        "X-BAPI-RECV-WINDOW" => RECV_WINDOW,
        "X-BAPI-SIGN" => OpenSSL::HMAC.hexdigest("sha256", api_secret, payload)
      }
    end

    # Bybit reports most failures as HTTP 200 with a non-zero retCode.
    def handle_response(response)
      parsed = response.parsed_response

      case response.code
      when 200..299
        unwrap(parsed)
      when 401
        raise AuthenticationError, error_message(parsed) || "Unauthorized"
      when 403, 429
        raise RateLimitError, "Rate limit exceeded"
      else
        raise ApiError, error_message(parsed) || "API error: #{response.code}"
      end
    end

    def unwrap(parsed)
      raise ApiError, "Unexpected Bybit response" unless parsed.is_a?(Hash)

      code = parsed["retCode"].to_i
      return parsed["result"] || {} if code.zero?

      message = parsed["retMsg"].presence || "Bybit error #{code}"
      raise AuthenticationError, message if AUTH_ERROR_CODES.include?(code)
      raise PermissionError, message if PERMISSION_ERROR_CODES.include?(code)
      raise RateLimitError, message if RATE_LIMIT_ERROR_CODES.include?(code)

      raise ApiError, message
    end

    def error_message(parsed)
      return parsed if parsed.is_a?(String)
      return nil unless parsed.is_a?(Hash)

      parsed["retMsg"] || parsed["message"] || parsed["error"]
    end
end
