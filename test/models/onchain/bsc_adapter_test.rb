# frozen_string_literal: true

require "test_helper"

class Onchain::BscAdapterTest < ActiveSupport::TestCase
  ADDRESS = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
  USDT = "0x55d398326f99059ff775485246999027b3197955"
  RPC = "https://bsc-dataseed.binance.org"

  setup do
    @adapter = Onchain::Chains.adapter_for("bsc")
  end

  test "BSC is an EVM chain that shares the 0x address format" do
    assert_includes Onchain::Chains.matching(ADDRESS).map(&:key), "bsc"
    assert_equal "BNB", Onchain::Chains.find!("bsc").native.symbol
    assert_equal "erc20", Onchain::Chains.find!("bsc").token_kind
  end

  test "detection is a single batched request covering the coin and every shipped token" do
    stub = stub_rpc(native: "0x0", tokens: { USDT => "0x" + "f4240".rjust(64, "0") })

    assert @adapter.has_activity?(ADDRESS)
    assert_requested stub, times: 1
  end

  test "an empty address is not detected" do
    stub_rpc(native: "0x0", tokens: {})

    assert_equal false, @adapter.has_activity?(ADDRESS)
  end

  test "an unreachable node means could not tell" do
    stub_request(:post, RPC).to_return(status: 500)

    assert_nil @adapter.has_activity?(ADDRESS)
  end

  test "snapshot reads BNB and BEP-20 USDT scaled by 18 decimals, with history reported incomplete" do
    stub_rpc(native: "0x" + (2 * 10**18).to_s(16), tokens: { USDT => "0x" + (1500 * 10**18).to_s(16) })

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_equal BigDecimal("2"), snapshot.assets.find(&:native?).quantity
    usdt = snapshot.find_asset(kind: "erc20", contract: USDT)
    assert_equal "USDT", usdt.symbol
    assert_equal BigDecimal("1500"), usdt.quantity
    assert_empty snapshot.movements
    assert snapshot.history_truncated?
  end

  test "zero-balance tokens are not surfaced" do
    stub_rpc(native: "0x1", tokens: { USDT => "0x0" })

    assert_nil @adapter.fetch_snapshot(ADDRESS).find_asset(kind: "erc20", contract: USDT)
  end

  private
    def stub_rpc(native:, tokens:)
      stub_request(:post, RPC).to_return do |request|
        calls = JSON.parse(request.body)
        results = calls.map do |call|
          result = if call["method"] == "eth_getBalance"
            native
          else
            tokens.fetch(call["params"][0]["to"].downcase, "0x" + "0" * 64)
          end
          { "jsonrpc" => "2.0", "id" => call["id"], "result" => result }
        end
        { status: 200, body: results.to_json, headers: { "Content-Type" => "application/json" } }
      end
    end
end
