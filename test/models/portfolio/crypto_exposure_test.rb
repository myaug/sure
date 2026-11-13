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
end
