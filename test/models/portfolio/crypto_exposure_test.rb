require "test_helper"

class Portfolio::CryptoExposureTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.update!(currency: "VND")
    @account = accounts(:crypto)
    @account.update_columns(currency: "VND")
    @account.holdings.destroy_all
    ExchangeRate.create!(from_currency: "USD", to_currency: "VND", date: Date.current, rate: 25_000)
  end

  test "totals crypto in VND and splits stablecoins from other tokens" do
    hold("CRYPTO:USDT", qty: 100, price: 25_000)
    hold("CRYPTO:BTC", qty: 1, price: 2_500_000_000)

    exposure = build

    assert_equal 2_502_500_000, exposure.total
    assert_equal 2_500_000, exposure.stablecoin_total
    assert_equal 0.1, exposure.stablecoin_share
    assert_equal %w[BTC USDT], exposure.by_token.map(&:id)
    assert_equal [ "USDT" ], exposure.stablecoins.map(&:id)
  end

  test "a holding quoted in a currency with no rate is left out and reported, not counted 1:1" do
    hold("CRYPTO:USDT", qty: 100, price: 25_000)
    # Provider holdings keep the currency the provider reported them in.
    provider_account = crypto_account("Provider")
    link = AccountProvider.create!(account: provider_account, provider: wallet_record("TNPdqto8HiuMzoG7Vv9wyyYhWzCojLeHAF"))
    hold("CRYPTO:ETH", qty: 2, price: 1_000, currency: "XAF", account: provider_account).update_columns(account_provider_id: link.id)

    exposure = build

    assert_equal 2_500_000, exposure.total
    assert_equal [ "XAF" ], exposure.unconverted
  end

  test "an asset with a quantity but no price is reported as unpriced and adds nothing" do
    hold("CRYPTO:USDT", qty: 100, price: 25_000)
    hold("CRYPTO:JUNK", qty: 5, price: 0)

    exposure = build

    assert_equal 2_500_000, exposure.total
    assert_equal [ "JUNK" ], exposure.unpriced
  end

  test "wallet assets are filed under their chain and exchange balances under none" do
    wallet_account = crypto_account("USDT wallet")
    link = AccountProvider.create!(account: wallet_account, provider: wallet_record("TNPdqto8HiuMzoG7Vv9wyyYhWzCojLeHAF"))
    hold("CRYPTO:USDT", qty: 10, price: 25_000, account: wallet_account).update_columns(account_provider_id: link.id)
    hold("CRYPTO:BTC", qty: 1, price: 1_000_000)

    chains = build.by_chain.to_h { |segment| [ segment.id, segment.amount.amount ] }

    assert_equal 250_000, chains["TRON"]
    assert_equal 1_000_000, chains[""]
  end

  test "is empty without crypto holdings" do
    assert_not build.any?
    assert_equal [], build.by_token
    assert_nil build.stablecoin_share
  end

  test "reports the dated official USD rate used to value stablecoins" do
    rate = build.usd_rate

    assert_equal "VND", rate.currency
    assert_equal 25_000, rate.value
    assert_equal Date.current, rate.date
  end

  test "reports accounts whose connection failed its last sync" do
    provider_account = crypto_account("Failing exchange")
    item = connect_exchange(provider_account)
    item.syncs.create!(status: "failed", failed_at: Time.current, error: "boom")

    assert_equal [ "Failing exchange" ], build.failing_accounts
    assert_equal [], build.out_of_date_accounts
  end

  test "a connection that needs the user to act is failing even before a sync" do
    item = connect_exchange(crypto_account("Revoked key"))
    item.update!(status: :requires_update)

    assert_equal [ "Revoked key" ], build.failing_accounts
  end

  test "reports a connection whose last good sync is more than two days old" do
    item = connect_exchange(crypto_account("Quiet exchange"))
    item.syncs.create!(status: "completed", completed_at: 3.days.ago)

    assert_equal [ "Quiet exchange" ], build.out_of_date_accounts
    assert_equal [], build.failing_accounts
  end

  test "a recently synced or never synced connection is neither failing nor out of date" do
    connect_exchange(crypto_account("Never synced"))
    fresh = connect_exchange(crypto_account("Fresh"), name: "Fresh item")
    fresh.syncs.create!(status: "completed", completed_at: 1.hour.ago)

    assert_equal [], build.failing_accounts
    assert_equal [], build.out_of_date_accounts
  end

  test "counts crypto transfers waiting for confirmation between visible accounts only" do
    exchange = crypto_account("Exchange")
    wallet = crypto_account("Wallet")
    security = Security.create!(ticker: "CRYPTO:USDT#{SecureRandom.hex(2)}", name: "USDT")
    out_leg = transfer_leg(exchange, security, -10)
    in_leg = transfer_leg(wallet, security, 9.9)
    CryptoTransferLink.create!(family: @family, outflow_entry: out_leg, inflow_entry: in_leg, basis: "amount_time")

    assert_equal 1, build.pending_transfers_count

    CryptoTransferLink.sole.confirm!
    assert_equal 0, build.pending_transfers_count, "a confirmed link needs nothing from the user"
  end

  private
    def build
      Portfolio::CryptoExposure.new(@family.investment_statement(user: @user))
    end

    def crypto_account(name)
      Account.create!(family: @family, name: name, balance: 0, currency: "VND", accountable: Crypto.create!(subtype: "wallet"))
    end

    def wallet_record(address)
      @item ||= OnchainWalletItem.create!(family: @family, name: "Wallets")
      @item.onchain_wallet_accounts.create!(
        chain: "tron", wallet_address: address, asset_kind: "trc20",
        contract_address: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", symbol: "USDT", decimals: 6, quantity: 10, currency: "VND"
      )
    end

    def hold(ticker, qty:, price:, currency: "VND", account: @account)
      security = Security.find_or_create_by!(ticker: ticker, exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC) { |s| s.name = ticker; s.offline = true }
      account.holdings.create!(security: security, date: Date.current, qty: qty, price: price, amount: qty * price, currency: currency)
    end

    # A connection record a provider account of the account belongs to, as an
    # exchange sync would leave it.
    def connect_exchange(account, name: "Connection")
      item = BybitItem.create!(family: @family, name: name, api_key: "k#{SecureRandom.hex(3)}", api_secret: "s")
      provider_account = item.bybit_accounts.create!(name: name, account_type: "combined", currency: "USD", current_balance: 0)
      AccountProvider.create!(account: account, provider: provider_account)
      item
    end

    def transfer_leg(account, security, qty)
      account.entries.create!(
        name: "Transfer", date: Date.current, amount: 0, currency: account.currency,
        entryable: Trade.new(qty: qty, price: 1, currency: account.currency, security: security, investment_activity_label: "Transfer")
      )
    end
end
