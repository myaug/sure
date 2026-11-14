require "test_helper"

class CryptoTransferLinksControllerTest < ActionDispatch::IntegrationTest
  include PortfolioFlowTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @exchange = create_portfolio_account(@family, name: "Exchange", accountable: Crypto.new)
    @wallet = create_portfolio_account(@family, name: "Wallet", accountable: Crypto.new)
    security = create_portfolio_security
    out_leg = create_portfolio_trade(account: @exchange, security: security, qty: -10, price: 1, label: "Transfer")
    in_leg = create_portfolio_trade(account: @wallet, security: security, qty: 9.9, price: 1, label: "Transfer")
    @link = CryptoTransferLink.create!(family: @family, outflow_entry: out_leg, inflow_entry: in_leg, basis: "amount_time")
  end

  test "the auto matches page lists a pending crypto transfer" do
    get auto_matches_path

    assert_response :success
    assert_select "tr##{ActionView::RecordIdentifier.dom_id(@link)}"
    assert_includes response.body, "Exchange"
    assert_includes response.body, "Wallet"
  end

  test "confirming makes the link confirmed" do
    patch crypto_transfer_link_path(@link, crypto_transfer_link: { status: "confirmed" })

    assert_redirected_to auto_matches_path
    assert @link.reload.confirmed?
  end

  test "rejecting records the pair as rejected" do
    patch crypto_transfer_link_path(@link, crypto_transfer_link: { status: "rejected" })

    assert_redirected_to auto_matches_path
    assert @link.reload.rejected?
  end

  test "an unknown status changes nothing" do
    patch crypto_transfer_link_path(@link, crypto_transfer_link: { status: "pending" })

    assert_redirected_to auto_matches_path
    assert @link.reload.pending?
  end

  test "a link already resolved is not found" do
    @link.confirm!

    patch crypto_transfer_link_path(@link, crypto_transfer_link: { status: "rejected" })

    assert_response :not_found
    assert @link.reload.confirmed?
  end

  test "a link of another family is not found" do
    @link.update_column(:family_id, families(:empty).id)

    patch crypto_transfer_link_path(@link, crypto_transfer_link: { status: "confirmed" })

    assert_response :not_found
    assert @link.reload.pending?
  end

  test "a pair involving an account the user cannot see is neither listed nor resolvable" do
    @exchange.update_column(:owner_id, @user.id)
    @wallet.update_column(:owner_id, users(:family_member).id)

    get auto_matches_path
    assert_select "tr##{ActionView::RecordIdentifier.dom_id(@link)}", count: 0

    patch crypto_transfer_link_path(@link, crypto_transfer_link: { status: "confirmed" })

    assert_redirected_to auto_matches_path
    assert @link.reload.pending?
  end
end
