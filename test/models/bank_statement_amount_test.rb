require "test_helper"

class BankStatementAmountTest < ActiveSupport::TestCase
  test "reads Vietnamese dot-thousands and comma-decimal amounts" do
    assert_equal 1_234_567.0, BankStatementAmount.parse("1.234.567")
    assert_equal 1_234_567.89, BankStatementAmount.parse("1.234.567,89")
    assert_equal(-2_600_000.0, BankStatementAmount.parse("-2.600.000"))
    assert_equal 1234.0, BankStatementAmount.parse("1.234")
  end

  test "reads English comma-thousands amounts" do
    assert_equal 1_234_567.89, BankStatementAmount.parse("1,234,567.89")
    assert_equal 1234.0, BankStatementAmount.parse("1,234")
    assert_equal 12.5, BankStatementAmount.parse("12.50")
    assert_equal 0.125, BankStatementAmount.parse("0.125")
  end

  test "reads signs, brackets, currency marks and numbers" do
    assert_equal(-500_000.0, BankStatementAmount.parse("500.000 VND-"))
    assert_equal(-500_000.0, BankStatementAmount.parse("(500.000)"))
    assert_equal 500_000.0, BankStatementAmount.parse("+500.000 ₫")
    assert_equal 42.5, BankStatementAmount.parse(42.5)
  end

  test "returns nil when there is no number" do
    assert_nil BankStatementAmount.parse(nil)
    assert_nil BankStatementAmount.parse("")
    assert_nil BankStatementAmount.parse("n/a")
  end
end
