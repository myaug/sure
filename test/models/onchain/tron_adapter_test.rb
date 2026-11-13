# frozen_string_literal: true

require "test_helper"

class Onchain::TronAdapterTest < ActiveSupport::TestCase
  ADDRESS = "TNPdqto8HiuMzoG7Vv9wyyYhWzCojLeHAF"
  OTHER = "TUVNtEKX5Qn4vEHus9xd6ghc5JjAnUVNXU"
  USDT = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  SPAM = "TYteXtNLyZb9D6vZatpwvkq52YrdSMP4Y1"
  LOOKALIKE = "TAFjULxiVgT4qWk6UZwjqwZXTSaGaqnVp4"
  BASE = Provider::TronGrid::DEFAULT_BASE_URL

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::TRON)
  end

  test "TRON is registered with its own token kind and case-sensitive contracts" do
    definition = Onchain::Chains.find!(Onchain::Chains::TRON)

    assert_equal "trc20", definition.token_kind
    assert Onchain::Chains.contract_case_sensitive?("trc20")
    # Solana's Base58 shape also fits, which is why detection probes each chain.
    assert_equal [ "solana", "tron" ], Onchain::Chains.matching(ADDRESS).map(&:key).sort
  end

  test "a TRON address is not mistaken for a wallet on another chain" do
    assert_not_includes Onchain::Chains.matching(ADDRESS).map(&:key), Onchain::Chains::BITCOIN
    assert_empty Onchain::Chains.matching("not-an-address")
  end

  test "activity is one request and an unactivated address is not detected" do
    stub = stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}")
      .to_return(status: 200, body: { data: [ { balance: 1_000_000 } ], success: true }.to_json, headers: json_headers)

    assert @adapter.has_activity?(ADDRESS)
    assert_requested stub, times: 1

    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}")
      .to_return(status: 200, body: { data: [], success: true }.to_json, headers: json_headers)
    assert_equal false, Onchain::Chains.adapter_for(Onchain::Chains::TRON).has_activity?(ADDRESS)
  end

  test "a failing source means could not tell, not empty" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_return(status: 500)

    assert_nil @adapter.has_activity?(ADDRESS)
  end

  test "snapshot values TRX and USDT and leaves out tokens whose identity is unknown" do
    stub_account(
      balance: 72_776_438,
      trc20: [ { USDT => "22947200" }, { SPAM => "500000000000000000000" }, { LOOKALIKE => "1000000000000000000" } ]
    )
    stub_trc20_transfers([
      transfer(USDT, "USDT", 6, "911000", from: OTHER, to: ADDRESS, id: "tx1", at: 1_786_338_030_000),
      transfer(LOOKALIKE, "BTT", 18, "5000000000000000000", from: OTHER, to: ADDRESS, id: "tx2", at: 1_789_175_094_000)
    ])
    stub_native_transfers([])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    trx = snapshot.assets.find(&:native?)
    assert_equal BigDecimal("72.776438"), trx.quantity
    usdt = snapshot.find_asset(kind: "trc20", contract: USDT)
    assert_equal "USDT", usdt.symbol
    assert_equal BigDecimal("22.9472"), usdt.quantity
    assert usdt.notable?
    assert_equal "BTT", snapshot.find_asset(kind: "trc20", contract: LOOKALIKE).symbol
    assert_not snapshot.find_asset(kind: "trc20", contract: LOOKALIKE).notable?
    assert_nil snapshot.find_asset(kind: "trc20", contract: SPAM), "a token with no known identity is not guessed"
    assert_not snapshot.history_truncated?
  end

  test "a shipped token cannot be renamed by a lookalike transfer" do
    stub_account(balance: 0, trc20: [ { USDT => "1000000" } ])
    stub_trc20_transfers([ transfer(USDT, "FAKE", 2, "1000000", from: OTHER, to: ADDRESS, id: "tx1", at: 1_786_338_030_000) ])
    stub_native_transfers([])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_equal "USDT", snapshot.find_asset(kind: "trc20", contract: USDT).symbol
    assert_equal BigDecimal("1"), snapshot.find_asset(kind: "trc20", contract: USDT).quantity
    assert_equal BigDecimal("1"), snapshot.movements.sole.amount
  end

  test "movements are signed by direction and keep one per token transfer" do
    stub_account(balance: 0, trc20: [])
    stub_trc20_transfers([
      transfer(USDT, "USDT", 6, "2500000", from: OTHER, to: ADDRESS, id: "in", at: 1_786_338_030_000),
      transfer(USDT, "USDT", 6, "1000000", from: ADDRESS, to: OTHER, id: "out", at: 1_786_338_040_000)
    ])
    stub_native_transfers([ native_transfer("ntx", ADDRESS_HEX_OWNER, 3_000_000) ])

    snapshot = @adapter.fetch_snapshot(ADDRESS)
    amounts = snapshot.movements.map { |m| [ m.symbol, m.amount ] }

    assert_includes amounts, [ "USDT", BigDecimal("2.5") ]
    assert_includes amounts, [ "USDT", BigDecimal("-1") ]
    assert_includes amounts, [ "TRX", BigDecimal("-3") ]
  end

  test "throttled history still yields balances and reports the history as incomplete" do
    stub_account(balance: 1_000_000, trc20: [ { USDT => "1000000" } ])
    stub_request(:get, %r{#{Regexp.escape(BASE)}/v1/accounts/#{ADDRESS}/transactions}).to_return(status: 429)
    @adapter.stubs(:sleep)
    Provider::TronGrid.any_instance.stubs(:sleep)

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert snapshot.history_truncated?
    assert_equal BigDecimal("1"), snapshot.find_asset(kind: "trc20", contract: USDT).quantity
  end

  test "an unreachable source raises the chain-agnostic error" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_return(status: 503)

    assert_raises(Onchain::Chains::UnreachableError) { @adapter.fetch_snapshot(ADDRESS) }
  end

  test "fetch_snapshot refuses a malformed address before any request" do
    assert_raises(Onchain::Chains::Error) { @adapter.fetch_snapshot("nope") }
  end

  private
    # ADDRESS in TRON's 41-prefixed hex form, as TronGrid reports it in transactions.
    ADDRESS_HEX_OWNER = "4188403ac26730e33164eeac403291b48f300b782f"
    OTHER_HEX = "41" + "11" * 20

    def json_headers
      { "Content-Type" => "application/json" }
    end

    def stub_account(balance:, trc20:)
      stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}")
        .to_return(status: 200, body: { data: [ { balance: balance, trc20: trc20 } ], success: true }.to_json, headers: json_headers)
    end

    def stub_trc20_transfers(data)
      stub_request(:get, %r{#{Regexp.escape(BASE)}/v1/accounts/#{ADDRESS}/transactions/trc20})
        .to_return(status: 200, body: { data: data, success: true, meta: {} }.to_json, headers: json_headers)
    end

    def stub_native_transfers(data)
      stub_request(:get, %r{#{Regexp.escape(BASE)}/v1/accounts/#{ADDRESS}/transactions\?})
        .to_return(status: 200, body: { data: data, success: true, meta: {} }.to_json, headers: json_headers)
    end

    def transfer(contract, symbol, decimals, value, from:, to:, id:, at:)
      {
        transaction_id: id,
        token_info: { symbol: symbol, address: contract, decimals: decimals, name: symbol },
        block_timestamp: at, from: from, to: to, type: "Transfer", value: value
      }
    end

    def native_transfer(id, owner_hex, amount)
      {
        txID: id, block_timestamp: 1_791_436_788_000, ret: [ { contractRet: "SUCCESS" } ],
        raw_data: { contract: [ { type: "TransferContract", parameter: { value: { owner_address: owner_hex, to_address: OTHER_HEX, amount: amount } } } ] }
      }
    end
end
