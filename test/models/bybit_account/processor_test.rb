# frozen_string_literal: true

require "test_helper"

class BybitAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")

    @item = BybitItem.create!(family: @family, name: "Bybit", api_key: "k", api_secret: "s")
    @ba = @item.bybit_accounts.create!(name: "Bybit", account_type: "combined", currency: "USD", current_balance: 1000)
    @account = Account.create!(
      family: @family, name: "Bybit", balance: 0, currency: "USD", accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @ba)

    BybitAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @provider = mock
    @provider.stubs(:get_historical_price).returns(nil)
    @provider.stubs(:get_spot_price).returns(nil)
    @provider.stubs(:get_spot_executions).returns([])
    @provider.stubs(:get_deposit_records).returns([])
    @provider.stubs(:get_withdraw_records).returns([])
    @provider.stubs(:get_internal_deposit_records).returns([])
    BybitItem.any_instance.stubs(:bybit_provider).returns(@provider)
  end

  test "updates the account balance from the combined USD value" do
    BybitAccount::Processor.new(@ba).process

    assert_in_delta 1000, @account.reload.balance.to_f, 0.01
    assert_equal false, @ba.reload.extra.dig("bybit", "stale_rate")
  end

  test "imports a spot buy as a trade with the fee" do
    stub_executions([ execution("e1", side: "Buy", qty: "0.1", price: "60000", value: "6000", fee: "0.0001", fee_currency: "BTC") ])

    BybitAccount::Processor.new(@ba).process

    entry = @account.entries.find_by!(external_id: "bybit_spot_e1")
    trade = entry.entryable
    assert_equal "CRYPTO:BTC", trade.security.ticker
    assert_equal 0.1, trade.qty.to_f
    assert_equal 60_000, trade.price.to_f
    assert_in_delta 6.0, trade.fee.to_f, 0.001 # 0.0001 BTC at 60,000
    assert_equal(-6000, entry.amount.to_f)
    assert_equal "Buy", trade.investment_activity_label
  end

  test "imports a spot sell as a negative quantity" do
    stub_executions([ execution("e2", side: "Sell", qty: "2", price: "3000", value: "6000", fee: "6", fee_currency: "USDT", symbol: "ETHUSDT") ])

    BybitAccount::Processor.new(@ba).process

    entry = @account.entries.find_by!(external_id: "bybit_spot_e2")
    assert_equal(-2, entry.entryable.qty.to_f)
    assert_equal 6000, entry.amount.to_f
    assert_equal 6, entry.entryable.fee.to_f
  end

  test "syncing again does not duplicate entries" do
    stub_executions([ execution("e1") ])

    BybitAccount::Processor.new(@ba).process
    assert_no_difference -> { @account.entries.count } do
      BybitAccount::Processor.new(@ba).process
    end
  end

  test "resumes from the newest execution instead of re-reading history" do
    stub_executions([ execution("e1", time: 1_700_000_000_000) ])
    BybitAccount::Processor.new(@ba).process

    assert_equal 1_700_000_000_000, @ba.reload.raw_transactions_payload["last_exec_time"]
  end

  test "does not advance the cursor when an entry fails" do
    stub_executions([ execution("e1", time: 1_700_000_000_000) ])
    BybitAccount::SecurityResolver.stubs(:resolve).raises(StandardError, "boom")

    assert_raises(StandardError) { BybitAccount::Processor.new(@ba).process }

    assert_nil @ba.reload.raw_transactions_payload
  end

  test "does not record stablecoin-for-stablecoin trades" do
    stub_executions([ execution("e3", symbol: "USDCUSDT") ])

    assert_no_difference -> { @account.entries.count } do
      BybitAccount::Processor.new(@ba).process
    end
  end

  test "skips an execution whose quote currency cannot be priced" do
    stub_executions([ execution("e4", symbol: "BTCETH") ])
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    assert_no_difference -> { @account.entries.count } do
      BybitAccount::Processor.new(@ba).process
    end
  end

  test "an execution that cannot be priced holds the cursor until it can be" do
    held_at = (Time.current - 2.hours).to_i * 1000
    later = (Time.current - 1.hour).to_i * 1000
    executions = [ execution("e4", symbol: "BTCETH", value: "0.1", price: "0.1", time: held_at), execution("e5", time: later) ]
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    stub_executions(executions)
    BybitAccount::Processor.new(@ba).process

    payload = @ba.reload.raw_transactions_payload
    assert_equal held_at, payload["last_exec_time"], "the cursor stops at the execution it could not import"
    assert_equal({ "bybit_spot_e4" => 1 }, payload["unconverted_trades"])
    assert @account.entries.exists?(external_id: "bybit_spot_e5"), "later executions are still imported"
    assert_not @account.entries.exists?(external_id: "bybit_spot_e4")

    @provider.stubs(:get_historical_price).with("ETHUSDT", anything).returns(3000)
    stub_executions(executions)
    BybitAccount::Processor.new(@ba).process

    assert_equal 300, @account.entries.find_by!(external_id: "bybit_spot_e4").entryable.price.to_f
    payload = @ba.reload.raw_transactions_payload
    assert_equal later, payload["last_exec_time"]
    assert_not payload.key?("unconverted_trades")
  end

  test "an execution still unpriced after the last attempt is let go and logged once" do
    held_at = (Time.current - 2.hours).to_i * 1000
    later = (Time.current - 1.hour).to_i * 1000
    attempts = CryptoTransfer::ExchangeMovements::UNCONVERTED_TRADE_ATTEMPTS
    @ba.update!(raw_transactions_payload: { "last_exec_time" => held_at, "unconverted_trades" => { "bybit_spot_e4" => attempts - 1 } })
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)
    stub_executions([ execution("e4", symbol: "BTCETH", time: held_at), execution("e5", time: later) ])

    assert_difference -> { DebugLogEntry.where(provider_key: "bybit", level: "error").count }, 1 do
      BybitAccount::Processor.new(@ba).process
    end

    log = DebugLogEntry.where(provider_key: "bybit", level: "error").order(:created_at).last
    assert_equal "bybit_spot_e4", log.metadata["external_id"]
    assert_equal "no_usd_price", log.metadata["reason"]
    assert_equal @account, log.account
    assert_equal later, @ba.reload.raw_transactions_payload["last_exec_time"], "the cursor moves past it"

    stub_executions([ execution("e4", symbol: "BTCETH", time: held_at) ])
    assert_no_difference -> { DebugLogEntry.where(provider_key: "bybit", level: "error").count } do
      BybitAccount::Processor.new(@ba).process
    end
  end

  test "reads each symbol's quote currency" do
    processor = BybitAccount::Processor.new(@ba)

    assert_equal %w[BTC USDT], processor.send(:split_symbol, "BTCUSDT")
    assert_equal %w[ETH BTC], processor.send(:split_symbol, "ETHBTC")
    assert_equal %w[SOL USDC], processor.send(:split_symbol, "SOLUSDC")
    assert_equal [ nil, nil ], processor.send(:split_symbol, "WEIRD")
  end

  test "imports a successful deposit as a Transfer trade that carries its hash" do
    stub_transfers(deposits: [ deposit("d1", coin: "USDT", amount: "999", tx: "0xabababababababababababababababababababababababababababababababab", chain: "TRX", status: 3) ])

    BybitAccount::Processor.new(@ba).process

    entry = @account.entries.find_by!(external_id: "bybit_deposit_d1")
    trade = entry.entryable
    assert_equal 0, entry.amount
    assert_equal "Transfer", trade.investment_activity_label
    assert_equal 999, trade.qty.to_f
    assert_equal 1, trade.price.to_f, "a stablecoin is priced at a dollar"
    assert_equal "abababababababababababababababababababababababababababababababab", trade.extra.dig("crypto_transfer", "tx_hash")
    assert_equal "in", trade.extra.dig("crypto_transfer", "direction")
    assert_equal "TRX", trade.extra.dig("crypto_transfer", "network")
    assert_equal "d1", trade.extra.dig("bybit", "id")
  end

  test "a withdrawal takes the fee out of the balance too" do
    stub_transfers(withdrawals: [ withdrawal("w1", coin: "USDT", amount: "951", fee: "1", tx: "abababababababababababababababababababababababababababababababab", chain: "SOL") ])

    BybitAccount::Processor.new(@ba).process

    trade = @account.entries.find_by!(external_id: "bybit_withdraw_w1").entryable
    assert_equal(-952, trade.qty.to_f)
    assert_equal "out", trade.extra.dig("crypto_transfer", "direction")
  end

  test "deposits and withdrawals still in flight or failed are not imported" do
    stub_transfers(
      deposits: [ deposit("d2", status: 1) ],
      withdrawals: [ withdrawal("w2", status: "pending"), withdrawal("w3", status: "CancelByUser") ]
    )

    assert_no_difference -> { @account.entries.count } do
      BybitAccount::Processor.new(@ba).process
    end
  end

  test "reading transfers again does not duplicate them" do
    stub_transfers(deposits: [ deposit("d1") ], withdrawals: [ withdrawal("w1") ])

    BybitAccount::Processor.new(@ba).process
    assert_no_difference -> { @account.entries.count } do
      BybitAccount::Processor.new(@ba).process
    end
  end

  test "a key that cannot read transfers keeps its trades and logs the gap" do
    stub_executions([ execution("e1") ])
    @provider.stubs(:get_deposit_records).raises(Provider::Bybit::PermissionError, "permission denied")

    assert_difference -> { DebugLogEntry.where(provider_key: "bybit").count }, 1 do
      BybitAccount::Processor.new(@ba).process
    end
    assert @account.entries.exists?(external_id: "bybit_spot_e1")
    assert_nil @ba.reload.raw_transactions_payload["last_transfer_scan"], "the failed scan is retried"
  end

  test "a withdrawal that completed a week after it was requested is still read" do
    last_scan = (Time.current - 1.hour).to_i * 1000
    @ba.update!(raw_transactions_payload: { "last_transfer_scan" => last_scan })
    @provider.expects(:get_withdraw_records)
      .with(start_time: last_scan - 7.days.in_milliseconds, end_time: kind_of(Integer))
      .returns([ withdrawal("w9") ])

    BybitAccount::Processor.new(@ba).process

    assert @account.entries.exists?(external_id: "bybit_withdraw_w9")
  end

  test "a transfer between two of the owner's Bybit accounts is imported on both sides and paired" do
    other_item = BybitItem.create!(family: @family, name: "Bybit 2", api_key: "k2", api_secret: "s2")
    other_ba = other_item.bybit_accounts.create!(name: "Bybit 2", account_type: "combined", currency: "USD", current_balance: 0)
    other_account = Account.create!(family: @family, name: "Bybit 2", balance: 0, currency: "USD", accountable: Crypto.create!(subtype: "exchange"))
    AccountProvider.create!(account: other_account, provider: other_ba)

    stub_transfers(withdrawals: [ withdrawal("w5", amount: "100", tx: "77c37e5c-d9fa-41e5-bd13-c9b59d95").merge("withdrawType" => 1, "chain" => "") ])
    BybitAccount::Processor.new(@ba).process

    stub_transfers
    @provider.stubs(:get_internal_deposit_records).returns([ internal_deposit("i1", amount: "100", tx: "77c37e5c-d9fa-41e5-bd13-c9b59d95") ])
    BybitAccount::Processor.new(other_ba).process

    deposit = other_account.entries.find_by!(external_id: "bybit_internal_deposit_i1")
    assert_equal 100, deposit.entryable.qty.to_f
    assert_equal "bybit:internal:77c37e5c-d9fa-41e5-bd13-c9b59d95", deposit.entryable.extra.dig("crypto_transfer", "reference")
    assert_equal deposit.date, Time.zone.at(1_705_393_280).to_date, "seconds are read as seconds"

    assert_equal 1, @family.match_crypto_transfers!
    link = CryptoTransferLink.sole
    assert link.confirmed?
    assert_equal "reference", link.basis
  end

  test "internal deposits not yet credited are not imported" do
    @provider.stubs(:get_internal_deposit_records).returns([ internal_deposit("i2", status: 1) ])

    assert_no_difference -> { @account.entries.count } do
      BybitAccount::Processor.new(@ba).process
    end
  end

  test "a key that cannot read internal deposits still imports the other transfers" do
    stub_transfers(deposits: [ deposit("d1") ])
    @provider.stubs(:get_internal_deposit_records).raises(Provider::Bybit::PermissionError, "permission denied")

    BybitAccount::Processor.new(@ba).process

    assert @account.entries.exists?(external_id: "bybit_deposit_d1")
    payload = @ba.reload.raw_transactions_payload
    assert payload["last_transfer_scan"].present?
    assert_nil payload["last_internal_deposit_scan"], "the failed scan is retried"
  end

  test "a deposit written without a price is priced on a later sync" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)
    stub_transfers(deposits: [ deposit("d7", coin: "ETH", amount: "2") ])
    BybitAccount::Processor.new(@ba).process

    trade = @account.entries.find_by!(external_id: "bybit_deposit_d7").entryable
    assert_equal 0, trade.price.to_f
    assert trade.extra.dig("bybit", "price_missing")

    @provider.stubs(:get_historical_price).with("ETHUSDT", anything).returns("3000")
    BybitAccount::Processor.new(@ba).process

    trade.reload
    assert_equal 3000, trade.price.to_f
    assert_nil trade.extra.dig("bybit", "price_missing")
  end

  test "a deposit that still cannot be priced stops being retried" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)
    stub_transfers(deposits: [ deposit("d8", coin: "ETH") ])

    (CryptoTransfer::ExchangeMovements::UNCONVERTED_TRADE_ATTEMPTS + 2).times { BybitAccount::Processor.new(@ba).process }

    trade = @account.entries.find_by!(external_id: "bybit_deposit_d8").entryable
    assert_equal CryptoTransfer::ExchangeMovements::UNCONVERTED_TRADE_ATTEMPTS, trade.extra.dig("bybit", "price_attempts")
  end

  test "the trade and transfer cursors live side by side" do
    stub_executions([ execution("e1", time: 1_700_000_000_000) ])
    stub_transfers(deposits: [ deposit("d1") ])

    BybitAccount::Processor.new(@ba).process

    payload = @ba.reload.raw_transactions_payload
    assert_equal 1_700_000_000_000, payload["last_exec_time"]
    assert payload["last_transfer_scan"].present?
  end

  test "a Bybit withdrawal and an on-chain deposit of the same hash are linked as one movement" do
    stub_transfers(withdrawals: [ withdrawal("w1", coin: "USDT", amount: "99", fee: "1", tx: "abababababababababababababababababababababababababababababababab", chain: "SOL") ])
    BybitAccount::Processor.new(@ba).process

    wallet = Account.create!(family: @family, name: "Wallet", balance: 0, currency: "USD", accountable: Crypto.new)
    security = BybitAccount::SecurityResolver.resolve("USDT")
    wallet.entries.create!(
      name: "Transfer", date: Date.current, amount: 0, currency: "USD", source: "onchain_wallet",
      external_id: "onchain_#{wallet.id}_abababababababababababababababababababababababababababababababab",
      entryable: Trade.new(qty: 99, price: 1, currency: "USD", security: security, investment_activity_label: "Transfer")
    )

    assert_equal 1, @family.match_crypto_transfers!
    link = CryptoTransferLink.sole
    assert link.confirmed?
    assert_equal "tx_hash", link.basis
  end

  private

    def stub_transfers(deposits: [], withdrawals: [])
      @provider.stubs(:get_deposit_records).returns(deposits)
      @provider.stubs(:get_withdraw_records).returns(withdrawals)
    end

    def internal_deposit(id, coin: "USDT", amount: "10", tx: "internal-tx", status: 2)
      { "id" => id, "coin" => coin, "amount" => amount, "type" => 1, "status" => status, "address" => "o***@example.com",
        "createdTime" => "1705393280", "fromMemberId" => "118027304", "txID" => tx }
    end

    def deposit(id, coin: "USDT", amount: "10", tx: nil, chain: "TRX", status: 3)
      { "id" => id, "coin" => coin, "amount" => amount, "txID" => tx, "chain" => chain, "status" => status,
        "toAddress" => "addr", "successAt" => (Time.current.to_i * 1000).to_s }
    end

    def withdrawal(id, coin: "USDT", amount: "10", fee: "0", tx: nil, chain: "TRX", status: "success")
      { "withdrawId" => id, "coin" => coin, "amount" => amount, "withdrawFee" => fee, "txID" => tx, "chain" => chain,
        "status" => status, "toAddress" => "addr", "createTime" => (Time.current.to_i * 1000).to_s, "updateTime" => (Time.current.to_i * 1000).to_s }
    end

    def stub_executions(list)
      @provider.stubs(:get_spot_executions).returns(list).then.returns([])
    end

    def execution(id, side: "Buy", qty: "1", price: "100", value: "100", fee: "0", fee_currency: "USDT",
                  symbol: "BTCUSDT", time: Time.current.to_i * 1000)
      { "execId" => id, "symbol" => symbol, "side" => side, "execQty" => qty, "execPrice" => price,
        "execValue" => value, "execFee" => fee, "feeCurrency" => fee_currency, "execTime" => time.to_s }
    end
end
