require "test_helper"

class Provider::BybitTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Bybit.new(api_key: "test_key", api_secret: "test_secret")
  end

  test "signs timestamp, key, recv window and the exact query string" do
    headers = @provider.send(:auth_headers, "1000", "category=spot&limit=100")

    expected = OpenSSL::HMAC.hexdigest("sha256", "test_secret", "1000test_key5000category=spot&limit=100")
    assert_equal expected, headers["X-BAPI-SIGN"]
    assert_equal "test_key", headers["X-BAPI-API-KEY"]
    assert_equal "1000", headers["X-BAPI-TIMESTAMP"]
    assert_equal "5000", headers["X-BAPI-RECV-WINDOW"]
  end

  test "unwraps result when retCode is zero" do
    result = @provider.send(:handle_response, response(200, { "retCode" => 0, "result" => { "list" => [] } }))

    assert_equal({ "list" => [] }, result)
  end

  test "maps credential retCodes to AuthenticationError" do
    assert_raises(Provider::Bybit::AuthenticationError) do
      @provider.send(:handle_response, response(200, { "retCode" => 10003, "retMsg" => "API key is invalid." }))
    end
  end

  test "maps permission and IP retCodes to PermissionError" do
    assert_raises(Provider::Bybit::PermissionError) do
      @provider.send(:handle_response, response(200, { "retCode" => 10010, "retMsg" => "Unmatched IP" }))
    end
  end

  test "maps rate limiting to RateLimitError" do
    assert_raises(Provider::Bybit::RateLimitError) { @provider.send(:handle_response, response(403, {})) }
    assert_raises(Provider::Bybit::RateLimitError) do
      @provider.send(:handle_response, response(200, { "retCode" => 10006, "retMsg" => "Too many visits" }))
    end
  end

  test "raises ApiError for other failures" do
    assert_raises(Provider::Bybit::ApiError) do
      @provider.send(:handle_response, response(200, { "retCode" => 170130, "retMsg" => "bad" }))
    end
  end

  test "read_only_key! accepts a read-only key" do
    @provider.stubs(:get_api_key_info).returns({ "readOnly" => 1 })

    assert_nothing_raised { @provider.read_only_key! }
  end

  test "read_only_key! rejects a key that can write" do
    @provider.stubs(:get_api_key_info).returns({ "readOnly" => 0 })

    assert_raises(Provider::Bybit::WritePermissionError) { @provider.read_only_key! }
  end

  test "get_spot_executions follows the cursor to the end of the window" do
    @provider.stubs(:signed_get).returns(
      { "list" => [ { "execId" => "1" } ], "nextPageCursor" => "abc" },
      { "list" => [ { "execId" => "2" } ], "nextPageCursor" => "" }
    )

    executions = @provider.get_spot_executions(start_time: 1, end_time: 2)

    assert_equal %w[1 2], executions.map { |e| e["execId"] }
  end

  test "get_spot_price is nil when the ticker lookup fails" do
    @provider.stubs(:public_get).raises(Provider::Bybit::ApiError, "boom")

    assert_nil @provider.get_spot_price("NOPEUSDT")
  end

  test "deposit records follow the cursor and carry the window" do
    calls = []
    @provider.stubs(:signed_get).with { |path, **options| calls << [ path, options[:params] ] }
      .returns({ "rows" => [ { "id" => "1" } ], "nextPageCursor" => "next" }, { "rows" => [ { "id" => "2" } ], "nextPageCursor" => "" })

    rows = @provider.get_deposit_records(start_time: 10, end_time: 20)

    assert_equal %w[1 2], rows.map { |row| row["id"] }
    assert_equal "/v5/asset/deposit/query-record", calls.first.first
    assert_equal({ "startTime" => "10", "endTime" => "20", "limit" => "50" }, calls.first.last)
    assert_equal "next", calls.second.last["cursor"]
  end

  test "withdraw records use the withdraw endpoint" do
    @provider.expects(:signed_get).with("/v5/asset/withdraw/query-record", params: has_entries("startTime" => "1", "withdrawType" => "2")).returns({ "rows" => [], "nextPageCursor" => "" })

    assert_equal [], @provider.get_withdraw_records(start_time: 1, end_time: 2)
  end

  test "internal deposit records use the off-chain endpoint" do
    @provider.expects(:signed_get).with("/v5/asset/deposit/query-internal-record", params: has_entries("startTime" => "1", "endTime" => "2"))
      .returns({ "rows" => [ { "id" => "1103" } ], "nextPageCursor" => "" })

    assert_equal [ "1103" ], @provider.get_internal_deposit_records(start_time: 1, end_time: 2).map { |row| row["id"] }
  end

  test "a 403 is Bybit's IP ban and says so" do
    error = assert_raises(Provider::Bybit::RateLimitError) { @provider.send(:handle_response, response(403, "access too frequent")) }

    assert_match(/10 minutes/, error.message)
  end

  test "prices are shared across clients and a failed lookup is asked again" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    other = Provider::Bybit.new(api_key: "other_key", api_secret: "other_secret")

    @provider.expects(:public_get).once.returns({ "list" => [ { "lastPrice" => "60000" } ] })
    assert_equal "60000", @provider.get_spot_price("BTCUSDT")
    assert_equal "60000", other.get_spot_price("BTCUSDT"), "a second connection reads the cached price"

    other.expects(:public_get).twice.raises(Provider::Bybit::RateLimitError, "slow down")
    assert_nil other.get_spot_price("ETHUSDT")
    assert_nil other.get_spot_price("ETHUSDT")
  end

  test "a closed day's candle is cached, keyed by its date" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    @provider.expects(:public_get).twice.returns({ "list" => [ [ "0", "1", "2", "3", "61000" ] ] }, { "list" => [ [ "0", "1", "2", "3", "62000" ] ] })
    3.times { assert_equal "61000", @provider.get_historical_price("BTCUSDT", Date.new(2026, 11, 1)) }
    assert_equal "62000", @provider.get_historical_price("BTCUSDT", Date.new(2026, 11, 2))
  end

  private

    def response(code, body)
      stub(code: code, parsed_response: body)
    end
end
