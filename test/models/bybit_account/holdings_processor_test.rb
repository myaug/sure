# frozen_string_literal: true

require "test_helper"

class BybitAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "EUR")

    @item = BybitItem.create!(family: @family, name: "Bybit", api_key: "k", api_secret: "s")
    @ba = @item.bybit_accounts.create!(
      name: "Bybit", account_type: "combined", currency: "USD", current_balance: 30_000,
      raw_payload: { "assets" => [ btc_asset ] }
    )
    @account = Account.create!(
      family: @family, name: "Bybit", balance: 0, currency: "EUR", accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @ba)
  end

  test "values a holding at Bybit's USD value converted at the dated official rate" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.92)

    BybitAccount::HoldingsProcessor.new(@ba).process

    holding = @account.reload.current_holdings.sole
    assert_equal "CRYPTO:BTC", holding.security.ticker
    assert_equal 0.5, holding.qty.to_f
    assert_in_delta 27_600, holding.amount.to_f, 0.01
    assert_equal "EUR", holding.currency
  end

  test "leaves the USD amount unconverted and unflagged here when no rate exists" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    import_adapter = mock
    import_adapter.expects(:import_holding).with(has_entries(currency: "EUR", amount: 30_000.0))
    Account::ProviderImportAdapter.stubs(:new).returns(import_adapter)

    BybitAccount::HoldingsProcessor.new(@ba).process
  end

  test "skips an asset without a USD value instead of valuing it at zero" do
    write_payload([ btc_asset.merge("usd_value" => nil) ])
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 1.0)

    BybitAccount::HoldingsProcessor.new(@ba).process

    assert_empty held_tickers
  end

  test "does not create a security for a spam symbol" do
    write_payload([ btc_asset.merge("symbol" => "Visit site to claim") ])
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 1.0)

    assert_no_difference -> { Security.count } do
      BybitAccount::HoldingsProcessor.new(@ba).process
    end
  end

  test "an asset that has left the wallet stops being held" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 1.0)

    write_payload([ btc_asset, eth_asset ])
    BybitAccount::HoldingsProcessor.new(@ba).process
    assert_equal [ "CRYPTO:BTC", "CRYPTO:ETH" ], held_tickers

    write_payload([ btc_asset ])
    BybitAccount::HoldingsProcessor.new(@ba).process

    assert_equal [ "CRYPTO:BTC" ], held_tickers
  end

  test "emptying the wallet empties the portfolio" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 1.0)

    BybitAccount::HoldingsProcessor.new(@ba).process
    assert_equal [ "CRYPTO:BTC" ], held_tickers

    write_payload([])
    BybitAccount::HoldingsProcessor.new(@ba).process

    assert_empty held_tickers
  end

  test "a payload that never carried an asset list removes nothing" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 1.0)
    BybitAccount::HoldingsProcessor.new(@ba).process

    @ba.update!(raw_payload: {})
    BybitAccount::HoldingsProcessor.new(@ba).process

    assert_equal [ "CRYPTO:BTC" ], held_tickers
  end

  private

    def btc_asset = { "symbol" => "BTC", "total" => "0.5", "usd_value" => "30000", "source" => "unified" }
    def eth_asset = { "symbol" => "ETH", "total" => "2", "usd_value" => "6000", "source" => "fund" }

    def write_payload(assets)
      @ba.update!(raw_payload: { "assets" => assets })
    end

    def held_tickers
      @account.reload.current_holdings.filter_map { |h| h.security&.ticker }.sort
    end
end
