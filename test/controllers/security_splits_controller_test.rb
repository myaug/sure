require "test_helper"

class SecuritySplitsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @security = Security.create!(ticker: "VNM", name: "Vinamilk")
    @admin = users(:family_admin)
    @admin.update_columns(role: "super_admin")
    @member = users(:family_member)
    @account = Account.create!(family: families(:dylan_family), name: "Broker", balance: 0, currency: "VND", accountable: Investment.new)
    @account.holdings.create!(security: @security, date: Date.current, qty: 100, price: 1, amount: 100, currency: "VND")
  end

  test "an instance manager can open the form" do
    sign_in @admin

    get new_security_split_path(security_id: @security.id)

    assert_response :success
    assert_select "form[action=?]", security_splits_path
  end

  test "a stock dividend is recorded as the split it amounts to and positions are recalculated" do
    sign_in @admin
    Account.any_instance.expects(:sync_later).at_least_once

    assert_difference -> { Security::Split.count }, 1 do
      post security_splits_path, params: { security_split: { security_id: @security.id, kind: "stock_dividend", percent: "20", ex_date: "2026-11-02" } }
    end

    split = @security.splits.sole
    assert_equal [ 6, 5 ], [ split.numerator, split.denominator ]
    assert_equal Date.new(2026, 11, 2), split.ex_date
    assert_equal "manual", split.source
  end

  test "a share split takes the ratio as entered" do
    sign_in @admin

    post security_splits_path, params: { security_split: { security_id: @security.id, kind: "split", numerator: "1", denominator: "10", ex_date: "2026-11-02" } }

    assert_equal [ 1, 10 ], @security.splits.pluck(:numerator, :denominator).first
  end

  test "a ratio that changes nothing, or a bad percentage, is refused" do
    sign_in @admin

    assert_no_difference -> { Security::Split.count } do
      post security_splits_path, params: { security_split: { security_id: @security.id, kind: "split", numerator: "2", denominator: "2", ex_date: "2026-11-02" } }
      assert_response :unprocessable_entity

      post security_splits_path, params: { security_split: { security_id: @security.id, kind: "stock_dividend", percent: "-3", ex_date: "2026-11-02" } }
      assert_response :unprocessable_entity
    end
  end

  test "a refused form keeps what was entered" do
    sign_in @admin

    post security_splits_path, params: { security_split: { security_id: @security.id, kind: "split", numerator: "2", denominator: "2", ex_date: "2026-11-02" } }
    assert_response :unprocessable_entity
    assert_select "input[name=?][value=?]", "security_split[numerator]", "2"
    assert_select "input[name=?][value=?]", "security_split[denominator]", "2"
    assert_select "input[name=?][value=?]", "security_split[ex_date]", "2026-11-02"

    post security_splits_path, params: { security_split: { security_id: @security.id, kind: "stock_dividend", percent: "-3", ex_date: "2026-11-02" } }
    assert_response :unprocessable_entity
    assert_select "input[name=?][value=?]", "security_split[percent]", "-3"
  end

  test "a second split on the same ex-date is refused" do
    sign_in @admin
    @security.splits.create!(ex_date: Date.new(2026, 11, 2), numerator: 6, denominator: 5, source: "manual")

    assert_no_difference -> { Security::Split.count } do
      post security_splits_path, params: { security_split: { security_id: @security.id, kind: "stock_dividend", percent: "10", ex_date: "2026-11-02" } }
    end
    assert_response :unprocessable_entity
  end

  test "removing a split recalculates the positions it restated" do
    sign_in @admin
    split = @security.splits.create!(ex_date: Date.new(2026, 11, 2), numerator: 6, denominator: 5, source: "manual")
    Account.any_instance.expects(:sync_later).at_least_once

    assert_difference -> { Security::Split.count }, -1 do
      delete security_split_path(split, security_id: @security.id)
    end
  end

  test "a family member who does not manage the instance cannot record or remove one" do
    sign_in @member
    split = @security.splits.create!(ex_date: Date.new(2026, 11, 2), numerator: 6, denominator: 5, source: "manual")

    assert_no_difference -> { Security::Split.count } do
      post security_splits_path, params: { security_split: { security_id: @security.id, kind: "stock_dividend", percent: "20", ex_date: "2026-11-05" } }
      delete security_split_path(split, security_id: @security.id)
    end
  end

  test "the holding drawer offers the form to an instance manager only" do
    holding = @account.holdings.first

    sign_in @admin
    get holding_path(holding)
    assert_response :success
    assert_select "a[href=?]", new_security_split_path(security_id: @security.id)

    @account.update_column(:owner_id, @member.id)
    sign_in @member
    get holding_path(holding)
    assert_response :success
    assert_select "a[href=?]", new_security_split_path(security_id: @security.id), count: 0
  end

  test "the drawer lists what was recorded, even to a member" do
    @security.splits.create!(ex_date: Date.new(2026, 11, 2), numerator: 6, denominator: 5, source: "manual")
    @account.update_column(:owner_id, @member.id)
    sign_in @member

    get holding_path(@account.holdings.first)

    assert_response :success
    assert_includes response.body, "6 new shares for every 5 held"
  end
end
