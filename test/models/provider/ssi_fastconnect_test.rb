require "test_helper"

class Provider::SsiFastconnectTest < ActiveSupport::TestCase
  BASE = "https://api.ssi.com.vn/api/v3"
  OHLC = %r{\A#{Regexp.escape(BASE)}/data/ohlc}

  setup do
    @provider = Provider::SsiFastconnect.new("key-1", "secret-1")
    @provider.stubs(:throttle_request)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @token = stub_request(:post, "#{BASE}/auth/token")
      .with(body: { apiKey: "key-1", apiSecret: "secret-1" }.to_json)
      .to_return(json(tokenType: "Bearer", accessToken: "tok-1", expiresAt: 1.hour.from_now.to_i))
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "searches the board lists by ticker prefix and maps boards to ISO 10383 venues" do
    stub_board("HOSE", [ row("VNM", "HOSE", "Công ty Cổ phần Sữa Việt Nam") ])
    stub_board("HNX", [ row("VNMF", "HNX", "Quỹ"), row("VNMFUT", "DERIVATIVES", "Hợp đồng tương lai", "Future") ])
    stub_board("UPCOM", [ row("ABC", "UPCOM", "Khác") ])

    results = @provider.search_securities("vnm").data

    assert_equal [ "VNM", "VNMF" ], results.map(&:symbol)
    assert_equal [ "XSTC", "HSTC" ], results.map(&:exchange_operating_mic)
    assert_equal [ "VND" ], results.map(&:currency).uniq
    assert_equal [ "VN" ], results.map(&:country_code).uniq
  end

  test "a search scoped to one venue only returns that board" do
    stub_board("HOSE", [ row("VNM", "HOSE", "Vinamilk") ])
    stub_board("HNX", [ row("VNMF", "HNX", "Quỹ") ])
    stub_board("UPCOM", [])

    assert_equal [ "VNMF" ], @provider.search_securities("VNM", exchange_operating_mic: "HSTC").data.map(&:symbol)
  end

  test "does not answer a search scoped to another country" do
    assert_equal [], @provider.search_securities("VNM", country_code: "US").data
    assert_not_requested @token
  end

  test "reads daily closes in VND with the time-of-day range the API requires" do
    ohlc = stub_request(:get, OHLC)
      .with(query: hash_including("symbol" => "VNM", "from" => "2026/11/01 00:00:00", "to" => "2026/11/12 23:59:59", "timeFrame" => "1d"))
      .to_return(json(data: [
        { symbol: "VNM", tradingDate: "2026/11/12", close: "54200" },
        { symbol: "VNM", tradingDate: "2026/11/11", close: "0" },
        { symbol: "VNM", tradingDate: "2026/11/10", close: "55398.72" }
      ]))

    prices = @provider.fetch_security_prices(
      symbol: "vnm", exchange_operating_mic: "XSTC", start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 12)
    ).data

    assert_requested ohlc
    assert_equal [ Date.new(2026, 11, 12), Date.new(2026, 11, 10) ], prices.map(&:date)
    assert_equal [ 54_200.0, 55_398.72 ], prices.map(&:price)
    assert_equal [ "VND" ], prices.map(&:currency).uniq
    assert_equal [ "XSTC" ], prices.map(&:exchange_operating_mic).uniq
  end

  test "a range with no trading days is empty rather than an error" do
    stub_request(:get, OHLC).to_return(json(code: 204, msg: "No Content"))

    prices = @provider.fetch_security_prices(
      symbol: "VNM", exchange_operating_mic: "XSTC", start_date: Date.new(2026, 11, 7), end_date: Date.new(2026, 11, 8)
    )

    assert prices.success?
    assert_equal [], prices.data
  end

  test "the price on a non-trading day is the latest earlier close" do
    stub_request(:get, OHLC).to_return(json(data: [ { symbol: "VNM", tradingDate: "2026/11/06", close: "60000" } ]))

    price = @provider.fetch_security_price(symbol: "VNM", exchange_operating_mic: "XSTC", date: Date.new(2026, 11, 8)).data

    assert_equal Date.new(2026, 11, 6), price.date
    assert_equal 60_000.0, price.price
  end

  test "sends the bearer token and reuses it across calls" do
    prices = stub_request(:get, OHLC).with(headers: { "Authorization" => "Bearer tok-1" }).to_return(json(data: []))

    2.times do
      @provider.fetch_security_prices(symbol: "VNM", exchange_operating_mic: "XSTC", start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 2))
    end

    assert_requested @token, times: 1
    assert_requested prices, times: 2
  end

  test "an expired token is replaced once" do
    stub_request(:get, OHLC).to_return({ status: 401, body: "{}" }, json(data: []))

    response = @provider.fetch_security_prices(
      symbol: "VNM", exchange_operating_mic: "XSTC", start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 2)
    )

    assert response.success?
    assert_requested @token, times: 2
  end

  test "rejected credentials are an authentication error" do
    stub_request(:post, "#{BASE}/auth/token").to_return(json(code: 400, msg: "This connection is invalid"))

    response = @provider.healthy?

    assert_not response.success?
    assert_match(/This connection is invalid/, response.error.message)
  end

  test "a rate limited API raises the rate limit error" do
    stub_request(:get, OHLC).to_return(status: 429)

    response = @provider.fetch_security_prices(
      symbol: "VNM", exchange_operating_mic: "XSTC", start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 2)
    )

    assert_match(/rate limit/, response.error.message)
  end

  test "reads security info from the board list" do
    stub_board("HOSE", [ row("E1VFVN30", "HOSE", "Quỹ ETF VN30", "ETF Product", "Quỹ") ])
    stub_board("HNX", [])
    stub_board("UPCOM", [])

    info = @provider.fetch_security_info(symbol: "E1VFVN30", exchange_operating_mic: "XSTC").data

    assert_equal "Quỹ ETF VN30", info.name
    assert_equal "etf", info.kind
    assert_equal "Quỹ", info.description
  end

  test "the registry builds the provider only when both credentials exist" do
    Setting.stubs(:ssi_fastconnect_api_key).returns("id")
    Setting.stubs(:ssi_fastconnect_api_secret).returns(nil)
    assert_nil Provider::Registry.get_provider(:ssi_fastconnect)

    Setting.stubs(:ssi_fastconnect_api_secret).returns("secret")
    assert_instance_of Provider::SsiFastconnect, Provider::Registry.get_provider(:ssi_fastconnect)
  end

  private
    def row(symbol, board, name, type = "Stock", icb = nil)
      { symbol: symbol, board: board, symbolNameVi: name, symbolNameEn: name, stockType: type, icbName: icb }
    end

    def json(body)
      { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
    end

    def stub_board(board, rows)
      stub_request(:get, "#{BASE}/data/securitiesByBoard").with(query: hash_including("board" => board)).to_return(json_array(rows))
    end

    def json_array(rows)
      { status: 200, body: rows.to_json, headers: { "Content-Type" => "application/json" } }
    end
end
