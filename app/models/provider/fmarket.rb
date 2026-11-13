# Vietnamese open-end fund NAV, from Fmarket's public web API (api.fmarket.vn).
#
# This is the endpoint Fmarket's own website calls; there is no published
# contract, so every response is read defensively and a changed shape raises an
# Error instead of producing a wrong price. It needs no key. Funds are not
# exchange-listed: they have a share-class code (DCDS, VFF...) and a NAV that is
# published per dealing day (daily or weekly depending on the fund), so between
# two publications the latest earlier NAV applies and carries its own date.
class Provider::Fmarket < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  MIN_REQUEST_INTERVAL = 0.5

  # Funds are not on an ISO 10383 venue, so this is a project-local code (see
  # config/exchanges.yml), like the legacy non-ISO values Security already knows.
  FMARKET_MIC = "FMKT".freeze

  CURRENCY = "VND".freeze
  COUNTRY = "VN".freeze
  SEARCH_LIMIT = 25

  # How far back a single-date lookup may reach for the latest published NAV;
  # covers weekly-NAV funds across a long holiday.
  LATEST_NAV_LOOKBACK_DAYS = 14

  PRODUCT_ID_CACHE_TTL = 24.hours

  def initialize
    # No API key required.
  end

  def healthy?
    with_provider_response do
      filter_products(search: nil, page_size: 1).any?
    end
  end

  def usage
    with_provider_response do
      UsageData.new(used: nil, limit: nil, utilization: nil, plan: "Free (no key required)")
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      next [] if country_code.present? && country_code.to_s.upcase != COUNTRY

      filter_products(search: symbol.to_s.strip, page_size: SEARCH_LIMIT).map do |row|
        remember_product_id(row)

        Security.new(
          symbol: row["shortName"].to_s.upcase,
          name: row["name"],
          logo_url: nil,
          exchange_operating_mic: FMARKET_MIC,
          country_code: COUNTRY,
          currency: CURRENCY
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      row = find_product(symbol)
      raise Error, "Fund #{symbol} was not found on Fmarket" if row.nil?

      SecurityInfo.new(
        symbol: symbol.to_s.upcase,
        name: row["name"],
        links: nil,
        logo_url: nil,
        description: [ row.dig("owner", "name"), row.dig("dataFundAssetType", "name") ].compact.join(" - ").presence,
        kind: "mutual fund",
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      history = fetch_security_prices(
        symbol: symbol, exchange_operating_mic: exchange_operating_mic,
        start_date: date - LATEST_NAV_LOOKBACK_DAYS.days, end_date: date
      )
      raise history.error if history.error.present?

      price = history.data.select { |p| p.date <= date }.max_by(&:date)
      raise InvalidSecurityPriceError, "No NAV found for fund #{symbol} on or before #{date}" if price.nil?

      price
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      product_id = product_id_for(symbol)
      raise Error, "Fund #{symbol} was not found on Fmarket" if product_id.nil?

      body = post_json("/res/product/get-nav-history", {
        productId: product_id,
        fromDate: start_date.strftime("%Y%m%d"),
        toDate: end_date.strftime("%Y%m%d"),
        isAllData: 0
      })

      rows = body["data"]
      raise Error, "Unexpected NAV history response for fund #{symbol}" unless rows.is_a?(Array)

      rows.filter_map do |entry|
        nav = entry["nav"].to_f
        next if nav <= 0 || entry["navDate"].blank?

        Price.new(
          symbol: symbol.to_s.upcase,
          date: Date.iso8601(entry["navDate"]),
          price: nav,
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
      ENV["FMARKET_URL"].presence || "https://api.fmarket.vn"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.options.open_timeout = 5
        faraday.options.timeout = 20

        faraday.request(:retry, {
          max: 3,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })

        faraday.headers["Content-Type"] = "application/json"
        faraday.headers["Accept"] = "application/json"
      end
    end

    def post_json(path, payload)
      throttle_request
      response = client.post(path, payload.to_json)

      raise RateLimitError, "Fmarket rate limit exceeded" if response.status == 429
      raise Error, "Fmarket API error: #{response.status}" unless response.status.between?(200, 299)

      parsed = JSON.parse(response.body)
      raise Error, "Unexpected Fmarket response" unless parsed.is_a?(Hash)
      raise Error, "Fmarket error: #{parsed["message"]}" if parsed["status"].present? && parsed["status"].to_i != 200

      parsed
    rescue JSON::ParserError
      raise Error, "Fmarket returned a response that is not JSON"
    end

    def filter_products(search:, page_size:)
      body = post_json("/res/products/filter", {
        types: %w[NEW_FUND TRADING_FUND],
        page: 1,
        pageSize: page_size,
        searchField: search.to_s,
        isIpo: false,
        sortOrder: "DESC",
        sortField: "navTo6Months",
        fundAssetTypes: [],
        bondRemainTerm: [],
        issuerIds: [],
        isBuyByReward: false,
        thirdAppIds: []
      })

      rows = body.dig("data", "rows")
      raise Error, "Unexpected Fmarket product list" unless rows.is_a?(Array)

      rows
    end

    # The NAV history endpoint is keyed by Fmarket's numeric product id, not the
    # fund code, so the code is resolved once and remembered.
    def product_id_for(symbol)
      code = symbol.to_s.upcase
      cached = Rails.cache.read(product_id_cache_key(code))
      return cached if cached

      row = find_product(code)
      row && row["id"]
    end

    def find_product(symbol)
      code = symbol.to_s.upcase
      row = filter_products(search: code, page_size: SEARCH_LIMIT).find { |r| r["shortName"].to_s.upcase == code }
      remember_product_id(row) if row
      row
    end

    def remember_product_id(row)
      return unless row["id"] && row["shortName"].present?

      Rails.cache.write(product_id_cache_key(row["shortName"].to_s.upcase), row["id"], expires_in: PRODUCT_ID_CACHE_TTL)
    end

    def product_id_cache_key(code)
      "fmarket:product_id:#{code}"
    end
end
