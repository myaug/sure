# frozen_string_literal: true

require "test_helper"

class BybitItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = BybitItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
    @provider = mock
    @provider.stubs(:read_only_key!).returns({ "readOnly" => 1 })
    @provider.stubs(:get_fund_balances).returns({ "balance" => [] })
  end

  test "imports unified balances using Bybit's USD value" do
    stub_unified([ { "coin" => "BTC", "walletBalance" => "0.5", "usdValue" => "30000" } ])

    BybitItem::Importer.new(@item, bybit_provider: @provider).import

    account = @item.bybit_accounts.sole
    assert_equal "combined", account.account_type
    assert_equal "USD", account.currency
    assert_in_delta 30_000, account.current_balance.to_f, 0.01
    asset = account.raw_payload["assets"].sole
    assert_equal({ "symbol" => "BTC", "source" => "unified" }, asset.slice("symbol", "source"))
  end

  test "values USD stablecoins at face value, not Bybit's quote" do
    stub_unified([ { "coin" => "USDT", "walletBalance" => "1000", "usdValue" => "999.2" } ])

    BybitItem::Importer.new(@item, bybit_provider: @provider).import

    assert_in_delta 1000, @item.bybit_accounts.sole.current_balance.to_f, 0.01
  end

  test "prices funding balances through the public ticker" do
    stub_unified([])
    @provider.stubs(:get_fund_balances).returns({ "balance" => [ { "coin" => "ETH", "walletBalance" => "2" } ] })
    @provider.stubs(:get_spot_price).with("ETHUSDT").returns("3000")

    BybitItem::Importer.new(@item, bybit_provider: @provider).import

    assert_in_delta 6000, @item.bybit_accounts.sole.current_balance.to_f, 0.01
  end

  test "leaves an unpriced asset out of the total instead of valuing it at zero or 1:1" do
    stub_unified([])
    @provider.stubs(:get_fund_balances).returns({ "balance" => [ { "coin" => "OBSCURE", "walletBalance" => "5" } ] })
    @provider.stubs(:get_spot_price).returns(nil)

    BybitItem::Importer.new(@item, bybit_provider: @provider).import

    account = @item.bybit_accounts.sole
    assert_equal 0, account.current_balance
    assert_nil account.raw_payload["assets"].sole["usd_value"]
  end

  test "skips zero and negative balances" do
    stub_unified([
      { "coin" => "BTC", "walletBalance" => "0", "usdValue" => "0" },
      { "coin" => "ETH", "walletBalance" => "-1", "usdValue" => "-3000" }
    ])

    BybitItem::Importer.new(@item, bybit_provider: @provider).import

    assert_empty @item.bybit_accounts
  end

  test "refuses a key that can write before reading anything" do
    @provider.stubs(:read_only_key!).raises(Provider::Bybit::WritePermissionError, "write")
    @provider.expects(:get_unified_balances).never

    assert_raises(Provider::Bybit::WritePermissionError) do
      BybitItem::Importer.new(@item, bybit_provider: @provider).import
    end
  end

  test "keeps a failed source's last known assets and records the partial failure" do
    stub_unified([ { "coin" => "BTC", "walletBalance" => "1", "usdValue" => "60000" } ])
    BybitItem::Importer.new(@item, bybit_provider: @provider).import

    @provider.stubs(:get_unified_balances).raises(Provider::Bybit::ApiError, "temporary")
    @provider.stubs(:get_fund_balances).returns({ "balance" => [] })

    assert_difference -> { DebugLogEntry.where(provider_key: "bybit").count }, 1 do
      BybitItem::Importer.new(@item, bybit_provider: @provider).import
    end

    account = @item.bybit_accounts.sole
    assert_equal %w[BTC], account.raw_payload["assets"].map { |a| a["symbol"] }
    assert_in_delta 60_000, account.current_balance.to_f, 0.01
  end

  test "an emptied wallet is written down" do
    stub_unified([ { "coin" => "BTC", "walletBalance" => "1", "usdValue" => "60000" } ])
    BybitItem::Importer.new(@item, bybit_provider: @provider).import

    stub_unified([])
    BybitItem::Importer.new(@item, bybit_provider: @provider).import

    assert_equal [], @item.bybit_accounts.sole.raw_payload["assets"]
  end

  test "raises when every source failed" do
    @provider.stubs(:get_unified_balances).raises(Provider::Bybit::ApiError, "down")
    @provider.stubs(:get_fund_balances).raises(Provider::Bybit::RateLimitError, "slow down")

    assert_raises(BybitItem::Importer::AllRequestsFailed) do
      BybitItem::Importer.new(@item, bybit_provider: @provider).import
    end
  end

  test "bad credentials are not swallowed as a per-source failure" do
    @provider.stubs(:get_unified_balances).raises(Provider::Bybit::AuthenticationError, "invalid")

    assert_raises(Provider::Bybit::AuthenticationError) do
      BybitItem::Importer.new(@item, bybit_provider: @provider).import
    end
  end

  private

    def stub_unified(coins)
      @provider.stubs(:get_unified_balances).returns({ "list" => [ { "coin" => coins } ] })
    end
end
