# frozen_string_literal: true

require "test_helper"

class MexcAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")

    @item = MexcItem.create!(family: @family, name: "MEXC", api_key: "k", api_secret: "s")
    @ba = @item.mexc_accounts.create!(
      name: "MEXC", account_type: "combined", currency: "USD", current_balance: 1000,
      raw_payload: { "assets" => [ { "symbol" => "BTC", "total" => "0.1", "usd_value" => "6000", "source" => "spot" } ] }
    )
    @account = Account.create!(
      family: @family, name: "MEXC", balance: 0, currency: "USD", accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @ba)

    MexcAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @provider = mock
    @provider.stubs(:get_historical_price).returns(nil)
    @provider.stubs(:get_spot_price).returns(nil)
    @provider.stubs(:get_my_trades).returns([])
    @provider.stubs(:get_deposit_history).returns([])
    @provider.stubs(:get_withdraw_history).returns([])
    MexcItem.any_instance.stubs(:mexc_provider).returns(@provider)
  end

  test "updates the account balance from the combined USD value" do
    MexcAccount::Processor.new(@ba).process

    assert_in_delta 1000, @account.reload.balance.to_f, 0.01
    assert_equal false, @ba.reload.extra.dig("mexc", "stale_rate")
  end

  test "scans each held asset against the usual quotes" do
    @provider.expects(:get_my_trades).with("BTCUSDT", has_keys(:start_time, :end_time)).returns([])
    @provider.expects(:get_my_trades).with("BTCUSDC", has_keys(:start_time, :end_time)).returns([])

    MexcAccount::Processor.new(@ba).process
  end

  test "imports a buy as a trade with the fee" do
    stub_trades("BTCUSDT", [ trade("t1", buyer: true, qty: "0.1", price: "60000", quote_qty: "6000", fee: "0.0001", fee_asset: "BTC") ])

    MexcAccount::Processor.new(@ba).process

    entry = @account.entries.find_by!(external_id: "mexc_spot_BTCUSDT_t1")
    trade = entry.entryable
    assert_equal "CRYPTO:BTC", trade.security.ticker
    assert_equal 0.1, trade.qty.to_f
    assert_in_delta 6.0, trade.fee.to_f, 0.001
    assert_equal(-6000, entry.amount.to_f)
  end

  test "imports a sell as a negative quantity" do
    stub_trades("BTCUSDT", [ trade("t2", buyer: false, qty: "0.1", price: "60000", quote_qty: "6000", fee: "6", fee_asset: "USDT") ])

    MexcAccount::Processor.new(@ba).process

    entry = @account.entries.find_by!(external_id: "mexc_spot_BTCUSDT_t2")
    assert_equal(-0.1, entry.entryable.qty.to_f)
    assert_equal 6000, entry.amount.to_f
  end

  test "syncing again does not duplicate entries" do
    stub_trades("BTCUSDT", [ trade("t1") ])

    MexcAccount::Processor.new(@ba).process
    assert_no_difference -> { @account.entries.count } do
      MexcAccount::Processor.new(@ba).process
    end
  end

  test "a pair MEXC does not list is skipped, not fatal" do
    @provider.stubs(:get_my_trades).with("BTCUSDC", anything).raises(Provider::Mexc::InvalidSymbolError, "invalid symbol")
    stub_trades("BTCUSDT", [ trade("t1") ])

    assert_difference -> { @account.entries.count }, 1 do
      MexcAccount::Processor.new(@ba).process
    end
    scanned = @ba.reload.raw_transactions_payload["scanned_until"]
    assert_equal %w[BTCUSDT], scanned.keys
  end

  test "keeps scanning a pair after the asset is sold out" do
    @ba.update!(raw_transactions_payload: { "scanned_until" => { "ETHUSDT" => 1_700_000_000_000 } })
    @provider.expects(:get_my_trades).with("ETHUSDT", has_keys(:start_time, :end_time)).returns([])

    MexcAccount::Processor.new(@ba).process
  end

  test "rescans a known pair from just before where the last scan ended" do
    last = (Time.current.to_i - 600) * 1000
    @ba.update!(raw_transactions_payload: { "scanned_until" => { "BTCUSDT" => last } })
    @provider.expects(:get_my_trades).with("BTCUSDT", start_time: last - MexcAccount::Processor::SCAN_OVERLAP_MS, end_time: kind_of(Integer)).returns([])
    @provider.stubs(:get_my_trades).with("BTCUSDC", anything).returns([])

    MexcAccount::Processor.new(@ba).process
  end

  test "does not advance the cursors when an entry fails" do
    stub_trades("BTCUSDT", [ trade("t1") ])
    MexcAccount::SecurityResolver.stubs(:resolve).raises(StandardError, "boom")

    assert_raises(StandardError) { MexcAccount::Processor.new(@ba).process }

    assert_nil @ba.reload.raw_transactions_payload
  end

  test "a trade with no security holds only its own pair's cursor until it resolves" do
    held_at = (Time.current - 2.hours).to_i * 1000
    stub_trades("BTCUSDT", [ trade("t1", time: held_at) ])
    stub_trades("BTCUSDC", [ trade("t2", symbol: "BTCUSDC") ])
    MexcAccount::SecurityResolver.stubs(:resolve).returns(nil)

    MexcAccount::Processor.new(@ba).process

    payload = @ba.reload.raw_transactions_payload
    assert_equal held_at, payload.dig("scanned_until", "BTCUSDT")
    assert_operator payload.dig("scanned_until", "BTCUSDC"), :>, held_at, "the other pair is not held"
    assert_equal({ "mexc_spot_BTCUSDT_t1" => 1, "mexc_spot_BTCUSDC_t2" => 1 }, payload["unconverted_trades"])

    MexcAccount::SecurityResolver.unstub(:resolve)
    MexcAccount::Processor.new(@ba).process

    assert @account.entries.exists?(external_id: "mexc_spot_BTCUSDT_t1")
    assert_operator @ba.reload.raw_transactions_payload.dig("scanned_until", "BTCUSDT"), :>, held_at
    assert_not @ba.raw_transactions_payload.key?("unconverted_trades")
  end

  test "reads each symbol's quote currency" do
    processor = MexcAccount::Processor.new(@ba)

    assert_equal %w[BTC USDT], processor.send(:split_symbol, "BTCUSDT")
    assert_equal %w[ETH BTC], processor.send(:split_symbol, "ETHBTC")
    assert_equal [ nil, nil ], processor.send(:split_symbol, "WEIRD")
  end

  test "imports a successful deposit as a Transfer trade that carries its hash" do
    stub_transfers(deposits: [ deposit(coin: "USDT", amount: "100", tx: "0xabababababababababababababababababababababababababababababababab", network: "TRC20") ])

    MexcAccount::Processor.new(@ba).process

    trade = @account.entries.find_by!(external_id: "mexc_deposit_USDT_0xabababababababababababababababababababababababababababababababab").entryable
    assert_equal "Transfer", trade.investment_activity_label
    assert_equal 100, trade.qty.to_f
    assert_equal "abababababababababababababababababababababababababababababababab", trade.extra.dig("crypto_transfer", "tx_hash")
    assert_equal "TRC20", trade.extra.dig("crypto_transfer", "network")
  end

  test "a withdrawal takes the fee out too, and falls back to transHash when txId is empty" do
    stub_transfers(withdrawals: [ withdrawal("w1", coin: "USDT", amount: "49", fee: "1", tx: nil, trans_hash: "0xabababababababababababababababababababababababababababababababab") ])

    MexcAccount::Processor.new(@ba).process

    trade = @account.entries.find_by!(external_id: "mexc_withdraw_w1").entryable
    assert_equal(-50, trade.qty.to_f)
    assert_equal "abababababababababababababababababababababababababababababababab", trade.extra.dig("crypto_transfer", "tx_hash")
  end

  test "transfers that did not complete are not imported" do
    stub_transfers(deposits: [ deposit(status: 4) ], withdrawals: [ withdrawal("w2", status: 3), withdrawal("w3", status: 8) ])

    assert_no_difference -> { @account.entries.count } do
      MexcAccount::Processor.new(@ba).process
    end
  end

  test "a window that returns the same record twice imports it once" do
    stub_transfers(deposits: [ deposit(tx: "t1") ])

    assert_difference -> { @account.entries.count }, 1 do
      MexcAccount::Processor.new(@ba).process
    end
  end

  test "a key without the withdraw-read permission keeps its trades and logs the gap" do
    stub_trades("BTCUSDT", [ trade("t1") ])
    @provider.stubs(:get_deposit_history).raises(Provider::Mexc::PermissionError, "No permission to access the endpoint")

    assert_difference -> { DebugLogEntry.where(provider_key: "mexc").count }, 1 do
      MexcAccount::Processor.new(@ba).process
    end
    assert @account.entries.exists?(external_id: "mexc_spot_BTCUSDT_t1")
  end

  test "the trade and transfer cursors live side by side" do
    stub_trades("BTCUSDT", [ trade("t1") ])
    stub_transfers(deposits: [ deposit ])

    MexcAccount::Processor.new(@ba).process

    payload = @ba.reload.raw_transactions_payload
    assert payload["scanned_until"].key?("BTCUSDT")
    assert payload["last_transfer_scan"].present?
  end

  private

    def stub_transfers(deposits: [], withdrawals: [])
      @provider.stubs(:get_deposit_history).returns(deposits)
      @provider.stubs(:get_withdraw_history).returns(withdrawals)
    end

    def deposit(coin: "USDT", amount: "10", tx: "0xtx", network: "TRC20", status: 5)
      { "coin" => coin, "amount" => amount, "txId" => tx, "network" => network, "status" => status,
        "address" => "addr", "insertTime" => (Time.current.to_i * 1000).to_s }
    end

    def withdrawal(id, coin: "USDT", amount: "10", fee: "0", tx: "0xtx", trans_hash: nil, network: "TRC20", status: 7)
      { "id" => id, "coin" => coin, "amount" => amount, "transactionFee" => fee, "txId" => tx, "transHash" => trans_hash,
        "network" => network, "status" => status, "address" => "addr", "applyTime" => (Time.current.to_i * 1000).to_s }
    end

    def stub_trades(pair, list)
      @provider.stubs(:get_my_trades).with(pair, anything).returns(list)
    end

    def trade(id, buyer: true, qty: "1", price: "100", quote_qty: "100", fee: "0", fee_asset: "USDT", symbol: "BTCUSDT", time: Time.current.to_i * 1000)
      { "id" => id, "symbol" => symbol, "isBuyer" => buyer, "qty" => qty, "price" => price, "quoteQty" => quote_qty,
        "commission" => fee, "commissionAsset" => fee_asset, "time" => time.to_s }
    end
end
