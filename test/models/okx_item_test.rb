# frozen_string_literal: true

require "test_helper"

class OkxItemTest < ActiveSupport::TestCase
  setup do
    @item = OkxItem.create!(family: families(:dylan_family), name: "My OKX", api_key: "k", api_secret: "s", api_passphrase: "pass")
  end

  test "requires name, key, secret and passphrase" do
    item = OkxItem.new(family: families(:dylan_family))

    assert_not item.valid?
    assert_includes item.errors[:name], "can't be blank"
    assert_includes item.errors[:api_key], "can't be blank"
    assert_includes item.errors[:api_secret], "can't be blank"
    assert_includes item.errors[:api_passphrase], "can't be blank"
  end

  test "builds a provider only with credentials" do
    assert_instance_of Provider::Okx, @item.okx_provider
    assert_nil OkxItem.new(name: "x").okx_provider
  end

  test "a revoked key flags the item for the user and logs the failure" do
    Provider::Okx.any_instance.stubs(:read_only_key!).raises(Provider::Okx::AuthenticationError, "API key is invalid.")

    assert_raises(Provider::Okx::AuthenticationError) { @item.import_latest_okx_data }

    assert @item.reload.requires_update?
    assert_equal 1, DebugLogEntry.where(provider_key: "okx").count
  end

  test "a key with write permission flags the item" do
    Provider::Okx.any_instance.stubs(:read_only_key!).raises(Provider::Okx::WritePermissionError, "write")

    assert_raises(Provider::Okx::WritePermissionError) { @item.import_latest_okx_data }

    assert @item.reload.requires_update?
  end

  test "other failures leave the status alone" do
    Provider::Okx.any_instance.stubs(:read_only_key!).raises(Provider::Okx::ApiError, "boom")

    assert_raises(Provider::Okx::ApiError) { @item.import_latest_okx_data }

    assert @item.reload.good?
  end

  test "is registered for reset and connection status" do
    assert_includes Family::FinancialDataReset::PROVIDER_ITEM_ASSOCIATIONS, :okx_items
    assert(ProviderConnectionStatus::PROVIDERS.any? { |p| p[:key] == "okx" })
  end
end
