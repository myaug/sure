# frozen_string_literal: true

require "test_helper"

class MexcItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @item = MexcItem.create!(family: families(:dylan_family), name: "M", api_key: "k", api_secret: "s")
    @provider = mock
    @provider.stubs(:get_all_prices).returns({ "BTCUSDT" => "60000", "ETHUSDT" => "3000" })
  end

  test "values balances (free plus locked) at the symbol's USDT price" do
    stub_balances([ { "asset" => "BTC", "free" => "0.4", "locked" => "0.1" } ])

    MexcItem::Importer.new(@item, mexc_provider: @provider).import

    account = @item.mexc_accounts.sole
    assert_equal "combined", account.account_type
    assert_equal "USD", account.currency
    assert_in_delta 30_000, account.current_balance.to_f, 0.01
    assert_equal "0.5", account.raw_payload["assets"].sole["total"]
  end

  test "values USD stablecoins at face value without asking for prices" do
    stub_balances([ { "asset" => "USDT", "free" => "1000", "locked" => "0" } ])
    @provider.expects(:get_all_prices).never

    MexcItem::Importer.new(@item, mexc_provider: @provider).import

    assert_in_delta 1000, @item.mexc_accounts.sole.current_balance.to_f, 0.01
  end

  test "leaves an unpriced asset out of the total instead of valuing it at zero or 1:1" do
    stub_balances([ { "asset" => "OBSCURE", "free" => "5", "locked" => "0" } ])

    MexcItem::Importer.new(@item, mexc_provider: @provider).import

    account = @item.mexc_accounts.sole
    assert_equal 0, account.current_balance
    assert_nil account.raw_payload["assets"].sole["usd_value"]
  end

  test "skips zero balances and creates nothing for an empty wallet" do
    stub_balances([ { "asset" => "BTC", "free" => "0", "locked" => "0" } ])

    MexcItem::Importer.new(@item, mexc_provider: @provider).import

    assert_empty @item.mexc_accounts
  end

  test "an emptied wallet is written down" do
    stub_balances([ { "asset" => "BTC", "free" => "1", "locked" => "0" } ])
    MexcItem::Importer.new(@item, mexc_provider: @provider).import

    stub_balances([])
    MexcItem::Importer.new(@item, mexc_provider: @provider).import

    assert_equal [], @item.mexc_accounts.sole.raw_payload["assets"]
  end

  test "a failed read leaves the previous snapshot alone" do
    stub_balances([ { "asset" => "BTC", "free" => "1", "locked" => "0" } ])
    MexcItem::Importer.new(@item, mexc_provider: @provider).import

    @provider.stubs(:get_account).raises(Provider::Mexc::ApiError, "down")

    assert_raises(Provider::Mexc::ApiError) { MexcItem::Importer.new(@item, mexc_provider: @provider).import }
    assert_equal %w[BTC], @item.mexc_accounts.sole.raw_payload["assets"].map { |a| a["symbol"] }
  end

  private

    def stub_balances(balances)
      @provider.stubs(:get_account).returns({ "balances" => balances })
    end
end
