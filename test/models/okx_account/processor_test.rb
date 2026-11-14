# frozen_string_literal: true

require "test_helper"

class OkxAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")

    @item = OkxItem.create!(family: @family, name: "OKX", api_key: "k", api_secret: "s", api_passphrase: "p")
    @ba = @item.okx_accounts.create!(name: "OKX", account_type: "combined", currency: "USD", current_balance: 1000)
    @account = Account.create!(
      family: @family, name: "OKX", balance: 0, currency: "USD", accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @ba)

    OkxAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @provider = mock
    @provider.stubs(:get_historical_price).returns(nil)
    @provider.stubs(:get_spot_price).returns(nil)
    @provider.stubs(:get_spot_fills).returns([])
    @provider.stubs(:get_deposit_history).returns([])
    @provider.stubs(:get_withdrawal_history).returns([])
    OkxItem.any_instance.stubs(:okx_provider).returns(@provider)
  end

  test "updates the account balance from the combined USD value" do
    OkxAccount::Processor.new(@ba).process

    assert_in_delta 1000, @account.reload.balance.to_f, 0.01
    assert_equal false, @ba.reload.extra.dig("okx", "stale_rate")
  end

  test "imports a spot buy as a trade with the fee" do
    stub_fills([ fill("b1", side: "buy", qty: "0.1", price: "60000", fee: "-0.0001", fee_currency: "BTC") ])

    OkxAccount::Processor.new(@ba).process

    entry = @account.entries.find_by!(external_id: "okx_spot_b1")
    trade = entry.entryable
    assert_equal "CRYPTO:BTC", trade.security.ticker
    assert_equal 0.1, trade.qty.to_f
    assert_equal 60_000, trade.price.to_f
    assert_in_delta 6.0, trade.fee.to_f, 0.001 # 0.0001 BTC at 60,000, reported as a negative fee
    assert_equal(-6000, entry.amount.to_f)
    assert_equal "Buy", trade.investment_activity_label
  end

  test "imports a spot sell as a negative quantity" do
    stub_fills([ fill("b2", side: "sell", qty: "2", price: "3000", fee: "-6", fee_currency: "USDT", inst: "ETH-USDT") ])

    OkxAccount::Processor.new(@ba).process

    entry = @account.entries.find_by!(external_id: "okx_spot_b2")
    assert_equal(-2, entry.entryable.qty.to_f)
    assert_equal 6000, entry.amount.to_f
    assert_equal 6, entry.entryable.fee.to_f
  end

  test "syncing again does not duplicate entries" do
    stub_fills([ fill("b1") ])

    OkxAccount::Processor.new(@ba).process
    assert_no_difference -> { @account.entries.count } do
      OkxAccount::Processor.new(@ba).process
    end
  end

  test "resumes from the newest fill instead of re-reading history" do
    stub_fills([ fill("b1", time: 1_700_000_000_000) ])
    OkxAccount::Processor.new(@ba).process

    assert_equal 1_700_000_000_000, @ba.reload.raw_transactions_payload["last_fill_time"]
  end

  test "does not advance the cursor when an entry fails" do
    stub_fills([ fill("b1", time: 1_700_000_000_000) ])
    OkxAccount::SecurityResolver.stubs(:resolve).raises(StandardError, "boom")

    assert_raises(StandardError) { OkxAccount::Processor.new(@ba).process }

    assert_nil @ba.reload.raw_transactions_payload
  end

  test "does not record stablecoin-for-stablecoin trades" do
    stub_fills([ fill("b3", inst: "USDC-USDT") ])

    assert_no_difference -> { @account.entries.count } do
      OkxAccount::Processor.new(@ba).process
    end
  end

  test "skips a fill whose quote currency cannot be priced" do
    stub_fills([ fill("b4", inst: "BTC-ETH") ])
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    assert_no_difference -> { @account.entries.count } do
      OkxAccount::Processor.new(@ba).process
    end
  end

  test "a fill that cannot be priced holds the cursor until it can be" do
    held_at = (Time.current - 2.hours).to_i * 1000
    later = (Time.current - 1.hour).to_i * 1000
    # OKX lists newest first.
    stub_fills([ fill("b5", time: later), fill("b4", inst: "BTC-ETH", price: "0.1", time: held_at) ])
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    OkxAccount::Processor.new(@ba).process

    payload = @ba.reload.raw_transactions_payload
    assert_equal held_at, payload["last_fill_time"]
    assert_equal({ "okx_spot_b4" => 1 }, payload["unconverted_trades"])
    assert @account.entries.exists?(external_id: "okx_spot_b5")

    @provider.stubs(:get_historical_price).with("ETH-USDT", anything).returns(3000)
    OkxAccount::Processor.new(@ba).process

    assert @account.entries.exists?(external_id: "okx_spot_b4")
    assert_equal later, @ba.reload.raw_transactions_payload["last_fill_time"]
    assert_not @ba.raw_transactions_payload.key?("unconverted_trades")
  end

  test "a fill still unpriced after the last attempt is let go and logged" do
    held_at = (Time.current - 2.hours).to_i * 1000
    attempts = CryptoTransfer::ExchangeMovements::UNCONVERTED_TRADE_ATTEMPTS
    @ba.update!(raw_transactions_payload: { "last_fill_time" => held_at, "unconverted_trades" => { "okx_spot_b4" => attempts - 1 } })
    stub_fills([ fill("b4", inst: "BTC-ETH", time: held_at) ])
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    assert_difference -> { DebugLogEntry.where(provider_key: "okx", level: "error").count }, 1 do
      OkxAccount::Processor.new(@ba).process
    end
    assert_equal({ "okx_spot_b4" => attempts }, @ba.reload.raw_transactions_payload["unconverted_trades"])
  end

  test "imports a credited deposit as a Transfer trade that carries its hash" do
    stub_transfers(deposits: [ deposit("d1", ccy: "USDT", amt: "100", tx: "0xabababababababababababababababababababababababababababababababab", chain: "USDT-TRC20") ])

    OkxAccount::Processor.new(@ba).process

    entry = @account.entries.find_by!(external_id: "okx_deposit_d1")
    trade = entry.entryable
    assert_equal 0, entry.amount
    assert_equal "Transfer", trade.investment_activity_label
    assert_equal 100, trade.qty.to_f
    assert_equal "abababababababababababababababababababababababababababababababab", trade.extra.dig("crypto_transfer", "tx_hash")
    assert_equal "USDT-TRC20", trade.extra.dig("crypto_transfer", "network")
  end

  test "a withdrawal in the same currency also loses its fee, and names its id as a reference" do
    stub_transfers(withdrawals: [ withdrawal("w1", ccy: "ETH", amt: "0.5", fee: "0.007", fee_ccy: "ETH", tx: "0xabababababababababababababababababababababababababababababababab") ])
    @provider.stubs(:get_spot_price).with("ETH-USDT").returns("3000")

    OkxAccount::Processor.new(@ba).process

    trade = @account.entries.find_by!(external_id: "okx_withdraw_w1").entryable
    assert_in_delta(-0.507, trade.qty.to_f, 0.0000001)
    assert_equal "okx:wd:w1", trade.extra.dig("crypto_transfer", "reference")
  end

  test "a fee in another currency is not taken from the withdrawn coin" do
    stub_transfers(withdrawals: [ withdrawal("w1", ccy: "USDT", amt: "50", fee: "0.001", fee_ccy: "BTC") ])

    OkxAccount::Processor.new(@ba).process

    assert_equal(-50, @account.entries.find_by!(external_id: "okx_withdraw_w1").entryable.qty.to_f)
  end

  test "an internal transfer deposit shares the reference of the withdrawal that sent it" do
    stub_transfers(deposits: [ deposit("d9", ccy: "USDT", amt: "20", from_wd: "77") ])

    OkxAccount::Processor.new(@ba).process

    assert_equal "okx:wd:77", @account.entries.find_by!(external_id: "okx_deposit_d9").entryable.extra.dig("crypto_transfer", "reference")
  end

  test "deposits and withdrawals not yet completed are not imported" do
    stub_transfers(deposits: [ deposit("d2", state: "0") ], withdrawals: [ withdrawal("w2", state: "1") ])

    assert_no_difference -> { @account.entries.count } do
      OkxAccount::Processor.new(@ba).process
    end
  end

  test "reading transfers again does not duplicate them" do
    stub_transfers(deposits: [ deposit("d1") ], withdrawals: [ withdrawal("w1") ])

    OkxAccount::Processor.new(@ba).process
    assert_no_difference -> { @account.entries.count } do
      OkxAccount::Processor.new(@ba).process
    end
  end

  test "a key that cannot read transfers keeps its trades and logs the gap" do
    stub_fills([ fill("b1") ])
    @provider.stubs(:get_deposit_history).raises(Provider::Okx::PermissionError, "no permission")

    assert_difference -> { DebugLogEntry.where(provider_key: "okx").count }, 1 do
      OkxAccount::Processor.new(@ba).process
    end
    assert @account.entries.exists?(external_id: "okx_spot_b1")
  end

  test "two OKX connections pair an internal transfer by its withdrawal id" do
    stub_transfers(withdrawals: [ withdrawal("w1", ccy: "USDT", amt: "20", fee: "0", fee_ccy: "USDT") ])
    OkxAccount::Processor.new(@ba).process

    other_item = OkxItem.create!(family: @family, name: "Other", api_key: "k2", api_secret: "s2", api_passphrase: "p2")
    other_ba = other_item.okx_accounts.create!(name: "OKX", account_type: "combined", currency: "USD", current_balance: 0)
    other_account = Account.create!(family: @family, name: "OKX 2", balance: 0, currency: "USD", accountable: Crypto.create!(subtype: "exchange"))
    AccountProvider.create!(account: other_account, provider: other_ba)
    OkxItem.any_instance.stubs(:okx_provider).returns(@provider)
    stub_transfers(deposits: [ deposit("d9", ccy: "USDT", amt: "20", from_wd: "w1") ])
    OkxAccount::Processor.new(other_ba).process

    assert_equal 1, @family.match_crypto_transfers!
    assert_equal "reference", CryptoTransferLink.sole.basis
  end

  test "a start date older than OKX keeps is logged as a gap in the trades OKX no longer serves" do
    @item.update!(sync_start_date: 2.years.ago)
    stub_fills([])

    assert_difference -> { DebugLogEntry.where(provider_key: "okx").where("message LIKE ?", "%history gap: trades%").count }, 1 do
      OkxAccount::Processor.new(@ba).process
    end
  end

  test "a start date inside what OKX keeps is not a gap" do
    @item.update!(sync_start_date: 10.days.ago)
    stub_fills([])

    assert_no_difference -> { DebugLogEntry.where(provider_key: "okx").count } do
      OkxAccount::Processor.new(@ba).process
    end
  end

  private

    def stub_transfers(deposits: [], withdrawals: [])
      @provider.stubs(:get_deposit_history).returns(deposits)
      @provider.stubs(:get_withdrawal_history).returns(withdrawals)
    end

    def deposit(id, ccy: "USDT", amt: "10", tx: nil, chain: "USDT-TRC20", state: "2", from_wd: "")
      { "depId" => id, "ccy" => ccy, "amt" => amt, "txId" => tx, "chain" => chain, "state" => state,
        "to" => "addr", "fromWdId" => from_wd, "ts" => (Time.current.to_i * 1000).to_s }
    end

    def withdrawal(id, ccy: "USDT", amt: "10", fee: "0", fee_ccy: "USDT", tx: nil, chain: "USDT-TRC20", state: "2")
      { "wdId" => id, "ccy" => ccy, "amt" => amt, "fee" => fee, "feeCcy" => fee_ccy, "txId" => tx, "chain" => chain,
        "state" => state, "to" => "addr", "ts" => (Time.current.to_i * 1000).to_s }
    end

    def stub_fills(list)
      @provider.stubs(:get_spot_fills).returns(list)
    end

    def fill(id, side: "buy", qty: "1", price: "100", fee: "0", fee_currency: "USDT", inst: "BTC-USDT", time: Time.current.to_i * 1000)
      { "billId" => id, "instId" => inst, "side" => side, "fillSz" => qty, "fillPx" => price,
        "fee" => fee, "feeCcy" => fee_currency, "fillTime" => time.to_s, "ts" => time.to_s }
    end
end
