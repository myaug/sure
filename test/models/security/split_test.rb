require "test_helper"

class Security::SplitTest < ActiveSupport::TestCase
  setup do
    @security = Security.create!(ticker: "SPLT", name: "Split Test")
    @ex_date = Date.new(2025, 6, 10)
  end

  test "a split needs positive terms that are not one-for-one" do
    [ [ 0, 1 ], [ 2, 0 ], [ -2, 1 ], [ 3, 3 ] ].each do |numerator, denominator|
      split = @security.splits.new(ex_date: @ex_date, numerator: numerator, denominator: denominator, source: "manual")

      assert_not split.valid?, "#{numerator}:#{denominator} should be refused"
    end

    assert @security.splits.new(ex_date: @ex_date, numerator: 1, denominator: 10, source: "manual").valid?
  end

  test "one split per security per ex-date" do
    @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")

    assert_not @security.splits.new(ex_date: @ex_date, numerator: 3, denominator: 1, source: "manual").valid?
    assert Security.create!(ticker: "OTHR", name: "Other").splits.new(ex_date: @ex_date, numerator: 3, denominator: 1, source: "manual").valid?
  end

  test "the database refuses a zero term that bypasses the model" do
    split = @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")

    assert_raises(ActiveRecord::StatementInvalid) { split.update_columns(denominator: 0) }
  end

  test "the ratio is exact" do
    split = @security.splits.new(ex_date: @ex_date, numerator: 1, denominator: 3, source: "manual")

    assert_equal Rational(1, 3), split.ratio
  end

  test "deleting the security deletes its splits" do
    @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")

    assert_difference "Security::Split.count", -1 do
      @security.destroy
    end
  end

  test "the split factor between two dates takes the splits after the first and on or before the second" do
    @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")
    @security.splits.create!(ex_date: @ex_date + 30, numerator: 3, denominator: 1, source: "manual")

    assert_equal 1, @security.split_factor_between(@ex_date - 10, @ex_date - 1)
    assert_equal 2, @security.split_factor_between(@ex_date - 1, @ex_date)
    assert_equal 1, @security.split_factor_between(@ex_date, @ex_date + 29)
    assert_equal 6, @security.split_factor_between(@ex_date - 1, @ex_date + 30)
  end

  test "a stock dividend is a split by one plus the percentage" do
    assert_equal Rational(6, 5), Security::Split.ratio_for_stock_dividend("20")
    assert_equal Rational(23, 20), Security::Split.ratio_for_stock_dividend("15")
    assert_equal Rational(9, 8), Security::Split.ratio_for_stock_dividend("12.5")
    assert_equal Rational(2, 1), Security::Split.ratio_for_stock_dividend(100)
    assert_equal Rational(101, 100), Security::Split.ratio_for_stock_dividend("1")
  end

  test "a stock dividend percentage must be a positive number" do
    [ nil, "", "abc", "0", "-5", "NaN", "Infinity", "1.23456" ].each do |value|
      assert_nil Security::Split.ratio_for_stock_dividend(value), "#{value.inspect} should be refused"
    end
  end

  test "a 20 percent stock dividend turns 100 shares into 120" do
    ratio = Security::Split.ratio_for_stock_dividend("20")

    assert_equal 120, Security::Split.scale(100, ratio)
  end

  test "the accounts a split changes are those holding or trading the security, in any family" do
    mine = Account.create!(family: families(:dylan_family), name: "Mine", balance: 0, currency: "USD", accountable: Investment.new)
    theirs = Account.create!(family: families(:empty), name: "Theirs", balance: 0, currency: "USD", accountable: Investment.new)
    unrelated = Account.create!(family: families(:dylan_family), name: "Unrelated", balance: 0, currency: "USD", accountable: Investment.new)
    mine.holdings.create!(security: @security, date: Date.current, qty: 1, price: 1, amount: 1, currency: "USD")
    theirs.entries.create!(name: "Buy", date: Date.current, amount: 1, currency: "USD",
      entryable: Trade.new(qty: 1, price: 1, currency: "USD", security: @security, investment_activity_label: "Buy"))
    split = @security.splits.create!(ex_date: @ex_date, numerator: 6, denominator: 5, source: "manual")

    assert_equal [ mine.id, theirs.id ].sort, split.affected_accounts.ids.sort
    assert_not_includes split.affected_accounts.ids, unrelated.id
  end
end
