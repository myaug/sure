# frozen_string_literal: true

require "test_helper"

class BybitItemTest < ActiveSupport::TestCase
  setup do
    @item = BybitItem.create!(family: families(:dylan_family), name: "My Bybit", api_key: "k", api_secret: "s")
  end

  test "requires name and both credentials" do
    item = BybitItem.new(family: families(:dylan_family))

    assert_not item.valid?
    assert_includes item.errors[:name], "can't be blank"
    assert_includes item.errors[:api_key], "can't be blank"
    assert_includes item.errors[:api_secret], "can't be blank"
  end

  test "builds a provider only with credentials" do
    assert_instance_of Provider::Bybit, @item.bybit_provider
    assert_nil BybitItem.new(name: "x").bybit_provider
  end

  test "a revoked key flags the item for the user and logs the failure" do
    Provider::Bybit.any_instance.stubs(:read_only_key!).raises(Provider::Bybit::AuthenticationError, "API key is invalid.")

    assert_raises(Provider::Bybit::AuthenticationError) { @item.import_latest_bybit_data }

    assert @item.reload.requires_update?
    assert_equal 1, DebugLogEntry.where(provider_key: "bybit").count
  end

  test "a key with write permission flags the item" do
    Provider::Bybit.any_instance.stubs(:read_only_key!).raises(Provider::Bybit::WritePermissionError, "write")

    assert_raises(Provider::Bybit::WritePermissionError) { @item.import_latest_bybit_data }

    assert @item.reload.requires_update?
  end

  test "other failures leave the status alone" do
    Provider::Bybit.any_instance.stubs(:read_only_key!).raises(Provider::Bybit::ApiError, "boom")

    assert_raises(Provider::Bybit::ApiError) { @item.import_latest_bybit_data }

    assert @item.reload.good?
  end

  test "is registered for reset and connection status" do
    assert_includes Family::FinancialDataReset::PROVIDER_ITEM_ASSOCIATIONS, :bybit_items
    assert(ProviderConnectionStatus::PROVIDERS.any? { |p| p[:key] == "bybit" })
  end
end
