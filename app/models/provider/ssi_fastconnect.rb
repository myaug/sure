# Vietnamese listed-security prices from SSI FastConnect V3's market data API
# (https://developers.ssi.com.vn/en/docs/api-reference).
#
# Needs the API key and secret SSI issues for the application; no OTP, because
# data queries do not need trading permission. Prices come from end-of-day OHLC
# and are VND. SSI serves them adjusted for corporate actions, so an older close
# can differ from the figure printed on the day.
#
# Boards map to ISO 10383: HOSE -> XSTC, HNX -> HSTC, UPCOM -> XHNX. SSI limits
# a key to 20 requests per period, so the security list is cached and search
# filters it locally.
class Provider::SsiFastconnect < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  AuthenticationError = Class.new(Error)
  RateLimitError = Class.new(Error)

  MIN_REQUEST_INTERVAL = 0.5

  BOARD_TO_MIC = { "HOSE" => "XSTC", "HNX" => "HSTC", "UPCOM" => "XHNX" }.freeze
  MIC_TO_BOARD = BOARD_TO_MIC.invert.freeze
  BOARDS = BOARD_TO_MIC.keys.freeze

  CURRENCY = "VND".freeze
  COUNTRY = "VN".freeze

  # stockType values the securities list reports; futures and covered warrants
  # are not holdings this app prices.
  KINDS = { "Stock" => "common stock", "ETF Product" => "etf", "Investment Fund" => "mutual fund", "Bond" => "bond" }.freeze

  PAGE_SIZE = 1000
  MAX_PAGES = 5
  SEARCH_LIMIT = 25
  SECURITIES_CACHE_TTL = 12.hours
  TOKEN_EXPIRY_MARGIN = 60

  def initialize(api_key, api_secret)
    @api_key = api_key # pipelock:ignore
    @api_secret = api_secret # pipelock:ignore
  end

  def healthy?
    with_provider_response do
      access_token.present?
    end
  end

  def usage
    with_provider_response do
      UsageData.new(used: nil, limit: 20, utilization: nil, plan: "SSI FastConnect (20 requests per period)")
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      next [] if country_code.present? && country_code.to_s.upcase != COUNTRY

      query = symbol.to_s.strip.upcase
      next [] if query.empty?

      boards = boards_for(exchange_operating_mic)

      matches = securities_list.select do |row|
        boards.include?(row["board"]) &&
          (row["symbol"].to_s.upcase.start_with?(query) ||
            row["symbolNameVi"].to_s.upcase.include?(query) ||
            row["symbolNameEn"].to_s.upcase.include?(query))
      end

      ranked = matches.sort_by { |row| [ row["symbol"].to_s.upcase == query ? 0 : 1, row["symbol"].to_s ] }

      ranked.first(SEARCH_LIMIT).map do |row|
        Security.new(
          symbol: row["symbol"].to_s.upcase,
          name: row["symbolNameVi"].presence || row["symbolNameEn"],
          logo_url: nil,
          exchange_operating_mic: BOARD_TO_MIC.fetch(row["board"]),
          country_code: COUNTRY,
          currency: CURRENCY
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      code = symbol.to_s.upcase
      boards = boards_for(exchange_operating_mic)
      row = securities_list.find { |r| r["symbol"].to_s.upcase == code && boards.include?(r["board"]) }
      raise Error, "#{symbol} was not found on SSI FastConnect" if row.nil?

      SecurityInfo.new(
        symbol: code,
        name: row["symbolNameVi"].presence || row["symbolNameEn"],
        links: nil,
        logo_url: nil,
        description: row["icbName"].presence,
        kind: KINDS[row["stockType"].to_s],
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      history = fetch_security_prices(
        symbol: symbol, exchange_operating_mic: exchange_operating_mic, start_date: date - 10.days, end_date: date
      )
      raise history.error if history.error.present?

      price = history.data.select { |p| p.date <= date }.max_by(&:date)
      raise InvalidSecurityPriceError, "No close found for #{symbol} on or before #{date}" if price.nil?

      price
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      rows = []

      (1..MAX_PAGES).each do |page|
        body = get(
          "data/ohlc",
          symbol: symbol.to_s.upcase, from: format_time(start_date, "00:00:00"), to: format_time(end_date, "23:59:59"),
          timeFrame: "1d", pageIndex: page, pageSize: PAGE_SIZE
        )
        batch = body.is_a?(Hash) ? body["data"] : nil
        break if batch.nil? && body.is_a?(Hash) && body["code"].to_i == 204 # no rows in range
        raise Error, "Unexpected OHLC response for #{symbol}" unless batch.is_a?(Array)

        rows.concat(batch)
        break if batch.size < PAGE_SIZE
      end

      rows.filter_map do |row|
        close = row["close"].to_f
        next if close <= 0

        Price.new(
          symbol: symbol.to_s.upcase,
          date: Date.strptime(row["tradingDate"].to_s, "%Y/%m/%d"),
          price: close,
          currency: CURRENCY,
          exchange_operating_mic: exchange_operating_mic
        )
      rescue Date::Error
        nil
      end
    end
  end

  private
    def base_url
      ENV["SSI_FASTCONNECT_URL"].presence || "https://api.ssi.com.vn/api/v3"
    end

    def client
      @client ||= Faraday.new(ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.options.open_timeout = 5
        faraday.options.timeout = 30

        faraday.request(:retry, {
          max: 2,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })
      end
    end

    def boards_for(exchange_operating_mic)
      board = MIC_TO_BOARD[exchange_operating_mic.to_s.upcase]
      board ? [ board ] : BOARDS
    end

    # One call per board returns every instrument, so search never hits the API
    # per keystroke.
    def securities_list
      Rails.cache.fetch("ssi_fastconnect:securities", expires_in: SECURITIES_CACHE_TTL) do
        BOARDS.flat_map { |board| paged_securities(board) }.select { |row| BOARDS.include?(row["board"]) && KINDS.key?(row["stockType"]) }
      end
    end

    def paged_securities(board)
      (1..MAX_PAGES).each_with_object([]) do |page, rows|
        batch = get("data/securitiesByBoard", board: board, pageIndex: page, pageSize: PAGE_SIZE)
        raise Error, "Unexpected securities response for #{board}" unless batch.is_a?(Array)

        rows.concat(batch)
        break rows if batch.size < PAGE_SIZE
      end
    end

    def access_token
      cached = Rails.cache.read(token_cache_key)
      return cached if cached

      response = client.post("#{base_url}/auth/token") do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = { apiKey: @api_key, apiSecret: @api_secret }.to_json
      end
      body = parse(response, label: "auth/token")
      token = body["accessToken"]
      raise AuthenticationError, "SSI FastConnect rejected the credentials: #{body["msg"]}" if token.blank?

      ttl = body["expiresAt"].to_i - Time.current.to_i - TOKEN_EXPIRY_MARGIN
      Rails.cache.write(token_cache_key, token, expires_in: ttl.positive? ? ttl.seconds : 5.minutes)
      token
    end

    # Distinguishes credentials without keeping the secret in a cache key.
    def token_cache_key
      "ssi_fastconnect:token:#{Digest::SHA256.hexdigest("#{@api_key}:#{@api_secret}").first(16)}"
    end

    def get(path, params)
      retried = false

      begin
        throttle_request
        response = client.get("#{base_url}/#{path}") do |req|
          req.headers["Authorization"] = "Bearer #{access_token}"
          req.params.update(params.compact)
        end
        parse(response, label: path)
      rescue AuthenticationError
        # A token that expired early is replaced once; a second rejection is real.
        raise if retried

        retried = true
        Rails.cache.delete(token_cache_key)
        retry
      end
    end

    # Success bodies are an object (auth, OHLC) or a bare array (securities list);
    # failures are { code, msg }.
    def parse(response, label:)
      raise RateLimitError, "#{label}: rate limit exceeded" if response.status == 429
      raise AuthenticationError, "#{label}: not authorized" if response.status == 401
      raise Error, "#{label}: HTTP #{response.status}" unless response.status.between?(200, 299)

      body = JSON.parse(response.body)
      return body if body.is_a?(Array)
      raise Error, "#{label}: unexpected response" unless body.is_a?(Hash)

      code = body["code"].to_i
      raise AuthenticationError, "#{label}: #{body["msg"]}" if code == 401
      raise Error, "#{label}: #{body["msg"]} (#{code})" if code >= 400

      body
    rescue JSON::ParserError
      raise Error, "#{label}: response is not JSON"
    end

    def format_time(date, time)
      "#{date.strftime("%Y/%m/%d")} #{time}"
    end
end
