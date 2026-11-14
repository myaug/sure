require "test_helper"

class Provider::MexcTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Mexc.new(api_key: "test_key", api_secret: "test_secret")
    @provider.stubs(:throttle_request)
  end

  test "signs the sorted query string with the secret" do
    captured = nil
    Provider::Mexc.stubs(:get).with { |_path, options| captured = options; true }.returns(response(200, {}))

    @provider.get_account

    query, signature = captured[:query].split("&signature=")
    assert_match(/\ArecvWindow=5000&timestamp=\d+\z/, query)
    assert_equal OpenSSL::HMAC.hexdigest("sha256", "test_secret", query), signature
    assert_equal({ "X-MEXC-APIKEY" => "test_key" }, captured[:headers])
  end

  test "maps credential codes to AuthenticationError" do
    assert_raises(Provider::Mexc::AuthenticationError) do
      @provider.send(:handle_response, response(400, { "code" => 700002, "msg" => "Signature for this request is not valid" }))
    end
    assert_raises(Provider::Mexc::AuthenticationError) { @provider.send(:handle_response, response(401, {})) }
  end

  test "maps IP whitelist and endpoint permission to PermissionError" do
    assert_raises(Provider::Mexc::PermissionError) do
      @provider.send(:handle_response, response(403, { "code" => 700006, "msg" => "IP non white list" }))
    end
  end

  test "maps unknown symbols to InvalidSymbolError" do
    assert_raises(Provider::Mexc::InvalidSymbolError) do
      @provider.send(:handle_response, response(400, { "code" => 30014, "msg" => "invalid symbol" }))
    end
  end

  test "maps rate limiting to RateLimitError" do
    assert_raises(Provider::Mexc::RateLimitError) { @provider.send(:handle_response, response(429, {})) }
  end

  test "treats a coded body on HTTP 200 as a failure" do
    assert_raises(Provider::Mexc::ApiError) do
      @provider.send(:handle_response, response(200, { "code" => 33333, "msg" => "param is error" }))
    end
  end

  test "returns the parsed body on success" do
    assert_equal({ "balances" => [] }, @provider.send(:handle_response, response(200, { "balances" => [] })))
  end

  test "get_my_trades walks the range in windows and continues past a full page" do
    window = Provider::Mexc::TRADES_WINDOW_MS
    full = Array.new(100) { |i| { "id" => i.to_s, "time" => (5 + i).to_s } }
    calls = []
    @provider.stubs(:signed_get).with { |_path, **options| calls << options[:params] }
      .returns(full, [ { "id" => "x", "time" => "200" } ], [])

    trades = @provider.get_my_trades("BTCUSDT", start_time: 1, end_time: 2 * window)

    assert_equal 101, trades.size
    assert_equal "1", calls.first["startTime"]
    assert_equal "105", calls.second["startTime"], "a full page advances past its newest trade inside the window"
    assert_equal (window + 105).to_s, calls.third["startTime"], "a short page moves to the next window"
  end

  test "get_all_prices indexes by symbol and is empty when the request fails" do
    @provider.stubs(:public_get).returns([ { "symbol" => "BTCUSDT", "price" => "60000" } ])
    assert_equal({ "BTCUSDT" => "60000" }, @provider.get_all_prices)

    @provider.stubs(:public_get).raises(Provider::Mexc::ApiError, "down")
    assert_equal({}, @provider.get_all_prices)
  end

  test "deposit and withdrawal history ask for the window with the largest page" do
    @provider.expects(:signed_get).with("/api/v3/capital/deposit/hisrec", params: { "startTime" => "1", "endTime" => "2", "limit" => "1000" }).returns([ { "coin" => "USDT" } ])
    @provider.expects(:signed_get).with("/api/v3/capital/withdraw/history", params: { "startTime" => "1", "endTime" => "2", "limit" => "1000" }).returns([])

    assert_equal 1, @provider.get_deposit_history(start_time: 1, end_time: 2).size
    assert_equal [], @provider.get_withdraw_history(start_time: 1, end_time: 2)
  end

  private

    def response(code, body)
      stub(code: code, parsed_response: body)
    end
end
