require "test_helper"

class CryptoTransferLinkTest < ActiveSupport::TestCase
  include PortfolioFlowTestHelper

  setup do
    @family = families(:empty)
    @exchange = create_portfolio_account(@family, name: "Exchange", accountable: Crypto.new)
    @wallet = create_portfolio_account(@family, name: "Wallet", accountable: Crypto.new)
    @security = create_portfolio_security
    @out = create_portfolio_trade(account: @exchange, security: @security, qty: -10, price: 1, label: "Transfer")
    @in = create_portfolio_trade(account: @wallet, security: @security, qty: 9.9, price: 1, label: "Transfer")
  end

  test "links a withdrawal to a deposit of the same asset" do
    link = build_link

    assert link.valid?, link.errors.full_messages.to_sentence
    assert link.pending?
    assert_equal @in, link.counterpart_of(@out)
    assert_equal @out, link.counterpart_of(@in)
  end

  test "confirm and reject set the status" do
    link = build_link.tap(&:save!)

    link.confirm!
    assert link.reload.confirmed?

    link.reject!
    assert link.reload.rejected?
  end

  test "rejects legs that are not both Transfer-labelled trades" do
    buy = create_portfolio_trade(account: @wallet, security: @security, qty: 9.9, price: 1, label: "Buy")

    assert_not build_link(inflow: buy).valid?
    assert_not build_link(inflow: @exchange.entries.create!(name: "Cash", date: Date.current, amount: 1, currency: "USD", entryable: Transaction.new)).valid?
  end

  test "rejects legs going the wrong way, in one account or for different assets" do
    assert_not build_link(outflow: @in, inflow: @out).valid?

    same_account = create_portfolio_trade(account: @exchange, security: @security, qty: 9.9, price: 1, label: "Transfer")
    assert_not build_link(inflow: same_account).valid?

    other_asset = create_portfolio_trade(account: @wallet, security: create_portfolio_security, qty: 9.9, price: 1, label: "Transfer")
    assert_not build_link(inflow: other_asset).valid?
  end

  test "rejects accounts from another family" do
    foreign = create_portfolio_account(families(:dylan_family), name: "Foreign", accountable: Crypto.new)
    foreign_in = create_portfolio_trade(account: foreign, security: @security, qty: 9.9, price: 1, label: "Transfer")

    assert_not build_link(inflow: foreign_in).valid?
  end

  test "a leg belongs to one live link only, but a rejected pair may be recorded again elsewhere" do
    build_link.save!
    other_in = create_portfolio_trade(account: @wallet, security: @security, qty: 9.9, price: 1, label: "Transfer")

    assert_raises(ActiveRecord::RecordNotUnique) { build_link(inflow: other_in).save!(validate: false) }

    CryptoTransferLink.sole.reject!
    assert_nothing_raised { build_link(inflow: other_in).save! }
  end

  test "deleting an entry removes its links" do
    build_link.save!

    assert_difference -> { CryptoTransferLink.count }, -1 do
      @out.destroy!
    end
  end

  private

    def build_link(outflow: @out, inflow: @in)
      CryptoTransferLink.new(family: @family, outflow_entry: outflow, inflow_entry: inflow, basis: "amount_time")
    end
end
