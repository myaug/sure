# frozen_string_literal: true

require "test_helper"

class CoinstatsItem::CreditBudgetTest < ActiveSupport::TestCase
  setup do
    @item = CoinstatsItem.create!(family: families(:dylan_family), name: "CS", api_key: "k")
    @provider = mock("Provider::Coinstats")
    @mid_month = Time.utc(2026, 11, 16, 0, 0, 0) # 15 of 30 days gone
  end

  test "is exhausted at or below the reserve, never above it" do
    assert budget(total: 20_000, remaining: 1_000).exhausted?, "5% of 20,000 is the reserve"
    assert_not budget(total: 20_000, remaining: 1_001).exhausted?
    assert budget(total: 1_000, remaining: 150).exhausted?, "the reserve is never below 200 credits"
  end

  test "can afford a call only from what is left after the reserve" do
    assert budget(total: 20_000, remaining: 1_400).can_afford?(400)
    assert_not budget(total: 20_000, remaining: 1_399).can_afford?(400)
  end

  test "hourly sync is on pace while no more of the plan is used than of the month" do
    assert budget(total: 20_000, remaining: 11_000).on_pace?, "55% left with 50% of the month left"
    assert_not budget(total: 20_000, remaining: 9_000).on_pace?, "45% left with 50% of the month left"
  end

  test "hourly sync is held back once exhausted even if on pace" do
    assert_not budget(total: 20_000, remaining: 500, now: Time.utc(2026, 11, 30, 23, 0)).hourly_sync_allowed?
  end

  test "a big plan stays on pace at hourly cost" do
    # ~100 credits an hour for half a month is 36,000 of 1,000,000.
    assert budget(total: 1_000_000, remaining: 964_000).hourly_sync_allowed?
  end

  test "holds nothing back when the balance cannot be read" do
    @provider.stubs(:get_credits).returns(Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("x")))
    unreadable = CoinstatsItem::CreditBudget.new(@item, provider: @provider, now: @mid_month)

    assert_nil unreadable.snapshot
    assert_not unreadable.exhausted?
    assert unreadable.can_afford?(1_000_000)
    assert unreadable.hourly_sync_allowed?
  end

  test "holds nothing back when the request raises" do
    @provider.stubs(:get_credits).raises(StandardError, "boom")

    assert CoinstatsItem::CreditBudget.new(@item, provider: @provider, now: @mid_month).hourly_sync_allowed?
  end

  test "holds nothing back when the response carries no figures" do
    @provider.stubs(:get_credits).returns(response({ total: nil, remaining: nil }))

    assert_nil CoinstatsItem::CreditBudget.new(@item, provider: @provider, now: @mid_month).snapshot
  end

  test "the item's hourly check fails open on an unexpected error" do
    CoinstatsItem::CreditBudget.any_instance.stubs(:hourly_sync_allowed?).raises(StandardError, "boom")

    assert @item.hourly_sync_allowed?
  end

  private

    def budget(total:, remaining:, now: @mid_month)
      @provider.stubs(:get_credits).returns(response({ total: total, remaining: remaining }))
      CoinstatsItem::CreditBudget.new(@item, provider: @provider, now: now)
    end

    def response(data)
      Provider::Response.new(success?: true, data: data, error: nil)
    end
end
