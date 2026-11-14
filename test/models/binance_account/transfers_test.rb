# frozen_string_literal: true

require "test_helper"

class BinanceAccount::TransfersTest < ActiveSupport::TestCase
  HASH = "ab" * 32

  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")
    @item = BinanceItem.create!(family: @family, name: "Binance", api_key: "k", api_secret: "s")
    @ba = @item.binance_accounts.create!(name: "Binance", account_type: "combined", currency: "USD", current_balance: 0)
    @account = Account.create!(family: @family, name: "Binance", balance: 0, currency: "USD", accountable: Crypto.create!(subtype: "exchange"))
    AccountProvider.create!(account: @account, provider: @ba)

    BinanceAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @provider = mock
    @provider.stubs(:get_historical_price).returns(nil)
    @provider.stubs(:get_spot_price).returns(nil)
    @provider.stubs(:get_all_p2p_trades).returns([])
    @provider.stubs(:get_spot_trades).returns([])
    @provider.stubs(:get_futures_trades).returns([])
    @provider.stubs(:get_deposit_history).returns([])
    @provider.stubs(:get_withdraw_history).returns([])
    BinanceItem.any_instance.stubs(:binance_provider).returns(@provider)
  end

  test "imports a successful deposit as a Transfer trade that carries its hash" do
    @provider.stubs(:get_deposit_history).returns([ deposit("d1", coin: "USDT", amount: "250", tx: "0x#{HASH}", network: "BSC") ])

    BinanceAccount::Processor.new(@ba).process

    entry = @account.entries.find_by!(external_id: "binance_deposit_d1")
    trade = entry.entryable
    assert_equal 0, entry.amount
    assert_equal "Transfer", trade.investment_activity_label
    assert_equal 250, trade.qty.to_f
    assert_equal HASH, trade.extra.dig("crypto_transfer", "tx_hash")
    assert_equal "BSC", trade.extra.dig("crypto_transfer", "network")
    assert_equal "CRYPTO:USDT", trade.security.ticker
  end

  test "a withdrawal loses its fee too and reads Binance's UTC apply time" do
    @provider.stubs(:get_withdraw_history).returns([
      withdrawal("w1", coin: "USDT", amount: "99", fee: "1", tx: HASH, apply_time: "2026-11-01 23:30:00")
    ])

    BinanceAccount::Processor.new(@ba).process

    entry = @account.entries.find_by!(external_id: "binance_withdraw_w1")
    assert_equal(-100, entry.entryable.qty.to_f)
    assert_equal Date.new(2026, 11, 1), entry.date
  end

  test "an internal transfer between users has no hash and is flagged as internal" do
    @provider.stubs(:get_deposit_history).returns([ deposit("d2", tx: "Off-chain transfer 123456", transfer_type: 1) ])

    BinanceAccount::Processor.new(@ba).process

    trade = @account.entries.find_by!(external_id: "binance_deposit_d2").entryable
    assert_nil trade.extra.dig("crypto_transfer", "tx_hash")
    assert_equal true, trade.extra.dig("binance", "internal")
  end

  test "pending, rejected and cancelled transfers are not imported" do
    @provider.stubs(:get_deposit_history).returns([ deposit("d3", status: 0), deposit("d4", status: 2) ])
    @provider.stubs(:get_withdraw_history).returns([ withdrawal("w2", status: 4), withdrawal("w3", status: 1) ])

    assert_no_difference -> { @account.entries.count } do
      BinanceAccount::Processor.new(@ba).process
    end
  end

  test "reading transfers again does not duplicate them" do
    @provider.stubs(:get_deposit_history).returns([ deposit("d1") ])

    BinanceAccount::Processor.new(@ba).process
    assert_no_difference -> { @account.entries.count } do
      BinanceAccount::Processor.new(@ba).process
    end
  end

  test "the trade cache and the transfer cursor live side by side" do
    @provider.stubs(:get_deposit_history).returns([ deposit("d1") ])

    BinanceAccount::Processor.new(@ba).process

    payload = @ba.reload.raw_transactions_payload
    assert payload["last_transfer_scan"].present?
    assert payload.key?("spot")
    assert payload.key?("p2p")
  end

  test "a key that cannot read transfers keeps its trades and logs the gap" do
    @provider.stubs(:get_deposit_history).raises(Provider::Binance::AuthenticationError, "permission")

    assert_difference -> { DebugLogEntry.where(provider_key: "binance").count }, 1 do
      BinanceAccount::Processor.new(@ba).process
    end
    assert_nil @ba.reload.raw_transactions_payload["last_transfer_scan"]
  end

  test "a Binance withdrawal and an on-chain deposit of the same hash are linked" do
    @provider.stubs(:get_withdraw_history).returns([ withdrawal("w1", coin: "USDT", amount: "99", fee: "1", tx: HASH) ])
    BinanceAccount::Processor.new(@ba).process

    wallet = Account.create!(family: @family, name: "Wallet", balance: 0, currency: "USD", accountable: Crypto.new)
    wallet.entries.create!(
      name: "Transfer", date: Date.current, amount: 0, currency: "USD", source: "onchain_wallet",
      external_id: "onchain_#{wallet.id}_#{HASH}",
      entryable: Trade.new(qty: 99, price: 1, currency: "USD", security: BinanceAccount::SecurityResolver.resolve("CRYPTO:USDT", "USDT"), investment_activity_label: "Transfer")
    )

    assert_equal 1, @family.match_crypto_transfers!
    assert CryptoTransferLink.sole.confirmed?
  end

  private

    def deposit(id, coin: "USDT", amount: "10", tx: "0x#{HASH}", network: "BSC", status: 1, transfer_type: 0)
      { "id" => id, "coin" => coin, "amount" => amount, "txId" => tx, "network" => network, "status" => status,
        "address" => "addr", "transferType" => transfer_type, "insertTime" => Time.current.to_i * 1000 }
    end

    def withdrawal(id, coin: "USDT", amount: "10", fee: "0", tx: "0x#{HASH}", network: "BSC", status: 6, apply_time: Time.current.utc.strftime("%Y-%m-%d %H:%M:%S"))
      { "id" => id, "coin" => coin, "amount" => amount, "transactionFee" => fee, "txId" => tx, "network" => network,
        "status" => status, "address" => "addr", "transferType" => 0, "applyTime" => apply_time }
    end
end
