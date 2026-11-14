require "test_helper"

class Provider::OkxTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Okx.new(api_key: "test_key", api_secret: "test_secret", api_passphrase: "test_pass")
    @provider.stubs(:throttle_request)
  end

  test "signs timestamp, method and the exact request path as base64 HMAC" do
    headers = @provider.send(:auth_headers, "2026-11-13T09:08:57.715Z", "/api/v5/account/balance?ccy=BTC")

    expected = Base64.strict_encode64(
      OpenSSL::HMAC.digest("sha256", "test_secret", "2026-11-13T09:08:57.715ZGET/api/v5/account/balance?ccy=BTC")
    )
    assert_equal expected, headers["OK-ACCESS-SIGN"]
    assert_equal "test_key", headers["OK-ACCESS-KEY"]
    assert_equal "test_pass", headers["OK-ACCESS-PASSPHRASE"]
    assert_equal "2026-11-13T09:08:57.715Z", headers["OK-ACCESS-TIMESTAMP"]
  end

  test "unwraps data when code is 0" do
    result = @provider.send(:handle_response, response(200, { "code" => "0", "data" => [ { "a" => 1 } ] }))

    assert_equal [ { "a" => 1 } ], result
  end

  test "maps credential codes to AuthenticationError" do
    assert_raises(Provider::Okx::AuthenticationError) do
      @provider.send(:handle_response, response(200, { "code" => "50111", "msg" => "Invalid OK-ACCESS-KEY" }))
    end
    assert_raises(Provider::Okx::AuthenticationError) do
      @provider.send(:handle_response, response(200, { "code" => "50105", "msg" => "passphrase incorrect" }))
    end
  end

  test "maps IP whitelist codes to PermissionError" do
    assert_raises(Provider::Okx::PermissionError) do
      @provider.send(:handle_response, response(200, { "code" => "50110", "msg" => "IP not whitelisted" }))
    end
  end

  test "maps rate limiting to RateLimitError" do
    assert_raises(Provider::Okx::RateLimitError) { @provider.send(:handle_response, response(429, {})) }
    assert_raises(Provider::Okx::RateLimitError) do
      @provider.send(:handle_response, response(200, { "code" => "50011", "msg" => "Too many requests" }))
    end
  end

  test "raises ApiError for other failures" do
    assert_raises(Provider::Okx::ApiError) do
      @provider.send(:handle_response, response(200, { "code" => "51000", "msg" => "bad param" }))
    end
  end

  test "read_only_key! accepts a key with read_only alone" do
    @provider.stubs(:get_account_config).returns({ "perm" => "read_only" })

    assert_nothing_raised { @provider.read_only_key! }
  end

  test "read_only_key! rejects trade and withdraw permission" do
    @provider.stubs(:get_account_config).returns({ "perm" => "read_only,trade" })
    error = assert_raises(Provider::Okx::WritePermissionError) { @provider.read_only_key! }
    assert_includes error.message, "trade"

    @provider.stubs(:get_account_config).returns({ "perm" => "read_only,withdraw,trade" })
    assert_raises(Provider::Okx::WritePermissionError) { @provider.read_only_key! }
  end

  test "read_only_key! rejects a key whose permissions are unknown" do
    @provider.stubs(:get_account_config).returns({})

    assert_raises(Provider::Okx::WritePermissionError) { @provider.read_only_key! }
  end

  test "get_spot_fills pages back through billId until a short page" do
    full_page = Array.new(100) { |i| { "billId" => (1000 - i).to_s } }
    @provider.expects(:signed_get).with("/api/v5/trade/fills-history", params: has_entries("instType" => "SPOT")).returns(full_page)
    @provider.expects(:signed_get).with("/api/v5/trade/fills-history", params: has_entries("after" => "901")).returns([ { "billId" => "900" } ])

    fills = @provider.get_spot_fills(begin_time: 1)

    assert_equal 101, fills.size
  end

  test "get_spot_price is nil when the ticker lookup fails" do
    @provider.stubs(:public_get).raises(Provider::Okx::ApiError, "boom")

    assert_nil @provider.get_spot_price("NOPE-USDT")
  end

  test "deposit history pages back from the oldest timestamp seen until a short page" do
    first_page = Array.new(100) { |i| { "depId" => i.to_s, "ts" => (2000 - i).to_s } }
    @provider.expects(:signed_get).with("/api/v5/asset/deposit-history", params: has_entries("before" => "5", "limit" => "100")).returns(first_page)
    @provider.expects(:signed_get).with("/api/v5/asset/deposit-history", params: has_entries("after" => "1901")).returns([ { "depId" => "x", "ts" => "1900" } ])

    assert_equal 101, @provider.get_deposit_history(begin_time: 5).size
  end

  test "withdrawal history uses the withdrawal endpoint" do
    @provider.expects(:signed_get).with("/api/v5/asset/withdrawal-history", params: has_entries("before" => "7")).returns([])

    assert_equal [], @provider.get_withdrawal_history(begin_time: 7)
  end

  private

    def response(code, body)
      stub(code: code, parsed_response: body)
    end
end
