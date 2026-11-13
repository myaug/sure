require "test_helper"

class Provider::FmarketTest < ActiveSupport::TestCase
  BASE = "https://api.fmarket.vn"

  setup do
    @provider = Provider::Fmarket.new
    @provider.stubs(:throttle_request)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "searches funds by code and prices them in VND under the Fmarket venue" do
    stub_products([ product(id: 28, short_name: "DCDS", name: "QUỸ ĐẦU TƯ CHỨNG KHOÁN NĂNG ĐỘNG DC") ])

    result = @provider.search_securities("DCDS").data.sole

    assert_equal "DCDS", result.symbol
    assert_equal "QUỸ ĐẦU TƯ CHỨNG KHOÁN NĂNG ĐỘNG DC", result.name
    assert_equal Provider::Fmarket::FMARKET_MIC, result.exchange_operating_mic
    assert_equal "VN", result.country_code
    assert_equal "VND", result.currency
  end

  test "does not answer a search scoped to another country" do
    assert_equal [], @provider.search_securities("DCDS", country_code: "US").data
  end

  test "fetches the NAV history by the fund's numeric product id" do
    stub_products([ product(id: 28, short_name: "DCDS") ])
    history = stub_request(:post, "#{BASE}/res/product/get-nav-history")
      .with { |req| JSON.parse(req.body).values_at("productId", "fromDate", "toDate") == [ 28, "20261101", "20261112" ] }
      .to_return(json_response(data: [
        { nav: 92_561.04, navDate: "2026-11-06", productId: 28 },
        { nav: 92_700.5, navDate: "2026-11-10", productId: 28 },
        { nav: 0, navDate: "2026-11-11", productId: 28 }
      ]))

    prices = @provider.fetch_security_prices(
      symbol: "dcds", exchange_operating_mic: "FMKT", start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 12)
    ).data

    assert_requested history
    assert_equal [ Date.new(2026, 11, 6), Date.new(2026, 11, 10) ], prices.map(&:date)
    assert_equal [ 92_561.04, 92_700.5 ], prices.map(&:price)
    assert_equal [ "VND" ], prices.map(&:currency).uniq
    assert_equal [ "DCDS" ], prices.map(&:symbol).uniq
  end

  test "between two NAV publications the latest earlier NAV applies" do
    stub_products([ product(id: 28, short_name: "DCDS") ])
    stub_request(:post, "#{BASE}/res/product/get-nav-history")
      .to_return(json_response(data: [ { nav: 92_700.5, navDate: "2026-11-10", productId: 28 } ]))

    price = @provider.fetch_security_price(symbol: "DCDS", exchange_operating_mic: "FMKT", date: Date.new(2026, 11, 12)).data

    assert_equal Date.new(2026, 11, 10), price.date
    assert_equal 92_700.5, price.price
  end

  test "reports an error when no NAV exists in the lookback window" do
    stub_products([ product(id: 28, short_name: "DCDS") ])
    stub_request(:post, "#{BASE}/res/product/get-nav-history").to_return(json_response(data: []))

    response = @provider.fetch_security_price(symbol: "DCDS", exchange_operating_mic: "FMKT", date: Date.new(2026, 11, 12))

    assert_not response.success?
    assert_match(/No NAV found/, response.error.message)
  end

  test "an unknown fund code is an error rather than an empty price list" do
    stub_products([])

    response = @provider.fetch_security_prices(
      symbol: "NOPE", exchange_operating_mic: "FMKT", start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 12)
    )

    assert_not response.success?
  end

  test "a changed response shape raises instead of producing prices" do
    stub_products([ product(id: 28, short_name: "DCDS") ])
    stub_request(:post, "#{BASE}/res/product/get-nav-history").to_return(json_response(data: { unexpected: true }))

    response = @provider.fetch_security_prices(
      symbol: "DCDS", exchange_operating_mic: "FMKT", start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 12)
    )

    assert_not response.success?
  end

  test "reads fund info from the product list" do
    stub_products([ product(id: 28, short_name: "DCDS", name: "Quỹ DC", owner: "Dragon Capital", asset_type: "Quỹ cổ phiếu") ])

    info = @provider.fetch_security_info(symbol: "DCDS", exchange_operating_mic: "FMKT").data

    assert_equal "Quỹ DC", info.name
    assert_equal "mutual fund", info.kind
    assert_equal "Dragon Capital - Quỹ cổ phiếu", info.description
  end

  test "a throttled API raises the rate limit error" do
    stub_request(:post, "#{BASE}/res/products/filter").to_return(status: 429)

    response = @provider.search_securities("DCDS")

    assert_not response.success?
    assert_match(/rate limit/, response.error.message)
  end

  private
    def product(id:, short_name:, name: "Fund", owner: "Manager", asset_type: "Quỹ cổ phiếu")
      { id: id, shortName: short_name, name: name, nav: 1, owner: { name: owner }, dataFundAssetType: { name: asset_type } }
    end

    def stub_products(rows)
      stub_request(:post, "#{BASE}/res/products/filter").to_return(json_response(data: { rows: rows, total: rows.size }))
    end

    def json_response(body)
      { status: 200, body: { status: 200, code: 200, message: "OK" }.merge(body).to_json, headers: { "Content-Type" => "application/json" } }
    end
end
