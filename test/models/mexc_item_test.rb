# frozen_string_literal: true

require "test_helper"

class MexcItemTest < ActiveSupport::TestCase
  setup do
    @item = MexcItem.create!(family: families(:dylan_family), name: "My MEXC", api_key: "k", api_secret: "s")
  end

  test "requires name and both credentials" do
    item = MexcItem.new(family: families(:dylan_family))

    assert_not item.valid?
    assert_includes item.errors[:name], "can't be blank"
    assert_includes item.errors[:api_key], "can't be blank"
    assert_includes item.errors[:api_secret], "can't be blank"
  end

  test "builds a provider only with credentials" do
    assert_instance_of Provider::Mexc, @item.mexc_provider
    assert_nil MexcItem.new(name: "x").mexc_provider
  end

  test "a revoked key flags the item for the user and logs the failure" do
    Provider::Mexc.any_instance.stubs(:get_account).raises(Provider::Mexc::AuthenticationError, "API key is invalid.")

    assert_raises(Provider::Mexc::AuthenticationError) { @item.import_latest_mexc_data }

    assert @item.reload.requires_update?
    assert_equal 1, DebugLogEntry.where(provider_key: "mexc").count
  end

  test "an IP that is not whitelisted flags the item" do
    Provider::Mexc.any_instance.stubs(:get_account).raises(Provider::Mexc::PermissionError, "IP non white list")

    assert_raises(Provider::Mexc::PermissionError) { @item.import_latest_mexc_data }

    assert @item.reload.requires_update?
  end

  test "other failures leave the status alone" do
    Provider::Mexc.any_instance.stubs(:get_account).raises(Provider::Mexc::ApiError, "boom")

    assert_raises(Provider::Mexc::ApiError) { @item.import_latest_mexc_data }

    assert @item.reload.good?
  end

  test "is registered for reset and connection status" do
    assert_includes Family::FinancialDataReset::PROVIDER_ITEM_ASSOCIATIONS, :mexc_items
    assert(ProviderConnectionStatus::PROVIDERS.any? { |p| p[:key] == "mexc" })
  end
end
