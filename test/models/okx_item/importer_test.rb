# frozen_string_literal: true

require "test_helper"

class OkxItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = OkxItem.create!(family: @family, name: "O", api_key: "k", api_secret: "s", api_passphrase: "p")
    @provider = mock
    @provider.stubs(:read_only_key!).returns([ "read_only" ])
    @provider.stubs(:get_funding_balances).returns([])
  end

  test "imports trading balances using OKX's USD equity" do
    stub_trading([ { "ccy" => "BTC", "cashBal" => "0.5", "eqUsd" => "30000" } ])

    OkxItem::Importer.new(@item, okx_provider: @provider).import

    account = @item.okx_accounts.sole
    assert_equal "combined", account.account_type
    assert_equal "USD", account.currency
    assert_in_delta 30_000, account.current_balance.to_f, 0.01
    assert_equal({ "symbol" => "BTC", "source" => "trading" }, account.raw_payload["assets"].sole.slice("symbol", "source"))
  end

  test "values USD stablecoins at face value, not OKX's quote" do
    stub_trading([ { "ccy" => "USDT", "cashBal" => "1000", "eqUsd" => "999.2" } ])

    OkxItem::Importer.new(@item, okx_provider: @provider).import

    assert_in_delta 1000, @item.okx_accounts.sole.current_balance.to_f, 0.01
  end

  test "prices funding balances through the public ticker" do
    stub_trading([])
    @provider.stubs(:get_funding_balances).returns([ { "ccy" => "ETH", "bal" => "2" } ])
    @provider.stubs(:get_spot_price).with("ETH-USDT").returns("3000")

    OkxItem::Importer.new(@item, okx_provider: @provider).import

    assert_in_delta 6000, @item.okx_accounts.sole.current_balance.to_f, 0.01
  end

  test "leaves an unpriced asset out of the total instead of valuing it at zero or 1:1" do
    stub_trading([])
    @provider.stubs(:get_funding_balances).returns([ { "ccy" => "OBSCURE", "bal" => "5" } ])
    @provider.stubs(:get_spot_price).returns(nil)

    OkxItem::Importer.new(@item, okx_provider: @provider).import

    account = @item.okx_accounts.sole
    assert_equal 0, account.current_balance
    assert_nil account.raw_payload["assets"].sole["usd_value"]
  end

  test "skips empty and negative balances" do
    stub_trading([
      { "ccy" => "BTC", "cashBal" => "0", "eqUsd" => "0" },
      { "ccy" => "ETH", "cashBal" => "-1", "eqUsd" => "-3000" }
    ])

    OkxItem::Importer.new(@item, okx_provider: @provider).import

    assert_empty @item.okx_accounts
  end

  test "refuses a key that can trade or withdraw before reading anything" do
    @provider.stubs(:read_only_key!).raises(Provider::Okx::WritePermissionError, "trade")
    @provider.expects(:get_trading_balances).never

    assert_raises(Provider::Okx::WritePermissionError) do
      OkxItem::Importer.new(@item, okx_provider: @provider).import
    end
  end

  test "keeps a failed source's last known assets and records the partial failure" do
    stub_trading([ { "ccy" => "BTC", "cashBal" => "1", "eqUsd" => "60000" } ])
    OkxItem::Importer.new(@item, okx_provider: @provider).import

    @provider.stubs(:get_trading_balances).raises(Provider::Okx::ApiError, "temporary")

    assert_difference -> { DebugLogEntry.where(provider_key: "okx").count }, 1 do
      OkxItem::Importer.new(@item, okx_provider: @provider).import
    end

    account = @item.okx_accounts.sole
    assert_equal %w[BTC], account.raw_payload["assets"].map { |a| a["symbol"] }
    assert_in_delta 60_000, account.current_balance.to_f, 0.01
  end

  test "an emptied wallet is written down" do
    stub_trading([ { "ccy" => "BTC", "cashBal" => "1", "eqUsd" => "60000" } ])
    OkxItem::Importer.new(@item, okx_provider: @provider).import

    stub_trading([])
    OkxItem::Importer.new(@item, okx_provider: @provider).import

    assert_equal [], @item.okx_accounts.sole.raw_payload["assets"]
  end

  test "raises when every source failed" do
    @provider.stubs(:get_trading_balances).raises(Provider::Okx::ApiError, "down")
    @provider.stubs(:get_funding_balances).raises(Provider::Okx::RateLimitError, "slow down")

    assert_raises(OkxItem::Importer::AllRequestsFailed) do
      OkxItem::Importer.new(@item, okx_provider: @provider).import
    end
  end

  test "bad credentials are not swallowed as a per-source failure" do
    @provider.stubs(:get_trading_balances).raises(Provider::Okx::AuthenticationError, "invalid")

    assert_raises(Provider::Okx::AuthenticationError) do
      OkxItem::Importer.new(@item, okx_provider: @provider).import
    end
  end

  private

    def stub_trading(details)
      @provider.stubs(:get_trading_balances).returns({ "details" => details })
    end
end
