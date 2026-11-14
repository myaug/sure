require "test_helper"

class CryptoTransfer::MatcherTest < ActiveSupport::TestCase
  include PortfolioFlowTestHelper

  HASH = "cd" * 32

  setup do
    @family = families(:empty)
    @exchange = create_portfolio_account(@family, name: "Exchange", accountable: Crypto.new)
    @wallet = create_portfolio_account(@family, name: "Wallet", accountable: Crypto.new)
    @other = create_portfolio_account(@family, name: "Other wallet", accountable: Crypto.new)
    @usdt = create_portfolio_security(ticker: "CRYPTO:USDT#{SecureRandom.hex(2)}")
  end

  test "pairs two legs carrying the same transaction hash and confirms them" do
    out_leg = leg(@exchange, -100, tx_hash: "0x#{HASH}")
    in_leg = leg(@wallet, 99, tx_hash: HASH, date: Date.current + 3)

    assert_difference -> { CryptoTransferLink.count }, 1 do
      assert_equal 1, match
    end

    link = CryptoTransferLink.sole
    assert link.confirmed?
    assert_equal "tx_hash", link.basis
    assert_equal [ out_leg.id, in_leg.id ], [ link.outflow_entry_id, link.inflow_entry_id ]
  end

  test "the hash decides even when quantity and date are far apart" do
    leg(@exchange, -100, tx_hash: HASH)
    leg(@wallet, 60, tx_hash: HASH, date: Date.current + 20)

    assert_equal 1, match
    assert_equal "tx_hash", CryptoTransferLink.sole.basis
  end

  test "reads an on-chain wallet's hash from its external id" do
    leg(@exchange, -100, tx_hash: HASH)
    onchain = leg(@wallet, 99, source: "onchain_wallet", external_id: "onchain_#{@wallet.id}_#{HASH}")

    assert_equal 1, match
    assert_equal onchain.id, CryptoTransferLink.sole.inflow_entry_id
  end

  test "pairs on a shared exchange reference" do
    leg(@exchange, -50, reference: "okx:wd:77")
    leg(@wallet, 50, reference: "okx:wd:77", date: Date.current + 9)

    assert_equal 1, match
    link = CryptoTransferLink.sole
    assert_equal "reference", link.basis
    assert link.confirmed?
  end

  test "suggests, but does not confirm, a pair matched only by amount and date" do
    leg(@exchange, -100)
    leg(@wallet, 99.2, date: Date.current + 1)

    assert_equal 1, match
    link = CryptoTransferLink.sole
    assert link.pending?
    assert_equal "amount_time", link.basis
  end

  test "does not pair when more than a fee is missing or the day is too far" do
    leg(@exchange, -100)
    leg(@wallet, 80)
    assert_equal 0, match

    CryptoTransferLink.delete_all
    Entry.where(account: [ @exchange, @wallet ]).destroy_all
    leg(@exchange, -100)
    leg(@wallet, 99, date: Date.current + 2)
    assert_equal 0, match
  end

  test "does not pair a larger received quantity than was sent" do
    leg(@exchange, -100)
    leg(@wallet, 101)

    assert_equal 0, match
  end

  test "does not pair different assets" do
    leg(@exchange, -100)
    leg(@wallet, 100, security: create_portfolio_security(ticker: "CRYPTO:BTC#{SecureRandom.hex(2)}"))

    assert_equal 0, match
  end

  test "does not pair legs in one account" do
    leg(@exchange, -100)
    leg(@exchange, 100)

    assert_equal 0, match
  end

  test "does not pair two different transactions even with matching amounts" do
    leg(@exchange, -100, tx_hash: HASH)
    leg(@wallet, 99, tx_hash: "ef" * 32)

    assert_equal 0, match
  end

  test "does not pair legs on different networks" do
    leg(@exchange, -100, network: "TRC20")
    leg(@wallet, 99, network: "ERC20")

    assert_equal 0, match
  end

  test "an ambiguous guess is left for nobody to answer" do
    leg(@exchange, -100)
    leg(@wallet, 99)
    leg(@other, 99)

    assert_equal 0, match, "two deposits could be the one withdrawal"
  end

  test "a hash settles what the amount alone could not" do
    leg(@exchange, -100, tx_hash: HASH)
    wallet_leg = leg(@wallet, 99, tx_hash: HASH)
    leg(@other, 99)

    assert_equal 1, match
    assert_equal wallet_leg.id, CryptoTransferLink.sole.inflow_entry_id
  end

  test "does not suggest a pair the user rejected" do
    out_leg = leg(@exchange, -100)
    in_leg = leg(@wallet, 99)
    CryptoTransferLink.create!(family: @family, outflow_entry: out_leg, inflow_entry: in_leg, basis: "amount_time", status: :rejected)

    assert_no_difference -> { CryptoTransferLink.count } do
      assert_equal 0, match
    end
  end

  test "leaves legs that are already linked alone, so running twice is harmless" do
    leg(@exchange, -100, tx_hash: HASH)
    leg(@wallet, 99, tx_hash: HASH)

    assert_equal 1, match
    assert_equal 0, match
    assert_equal 1, CryptoTransferLink.count
  end

  test "ignores excluded entries and other families" do
    leg(@exchange, -100, tx_hash: HASH)
    leg(@wallet, 99, tx_hash: HASH, excluded: true)

    foreign = create_portfolio_account(families(:dylan_family), name: "Foreign", accountable: Crypto.new)
    leg(foreign, 99, tx_hash: HASH)

    assert_equal 0, match
  end

  test "a link is created in one family only" do
    leg(@exchange, -100, tx_hash: HASH)
    leg(@wallet, 99, tx_hash: HASH)

    assert_equal 1, match
    assert_equal @family, CryptoTransferLink.sole.family
  end

  private

    def match
      CryptoTransfer::Matcher.new(@family).call
    end

    # A Transfer-labelled crypto movement: amount 0, signed quantity.
    def leg(account, qty, security: @usdt, date: Date.current, tx_hash: nil, reference: nil, network: nil, source: nil, external_id: nil, excluded: false)
      meta = { "tx_hash" => tx_hash, "reference" => reference, "network" => network }.compact
      extra = meta.empty? ? {} : { "crypto_transfer" => meta }

      account.entries.create!(
        name: "Transfer",
        date: date,
        amount: 0,
        currency: "USD",
        source: source,
        external_id: external_id,
        excluded: excluded,
        entryable: Trade.new(qty: qty, price: 1, currency: "USD", security: security, investment_activity_label: "Transfer", extra: extra)
      )
    end
end
