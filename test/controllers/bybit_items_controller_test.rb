require "test_helper"

class BybitItemsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @bybit_item = BybitItem.create!(
      family: @family,
      name: "Test Bybit",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "should destroy bybit item" do
    assert_difference("BybitItem.count", 0) do # doesn't delete immediately
      delete bybit_item_url(@bybit_item)
    end

    assert_redirected_to settings_providers_path
    @bybit_item.reload
    assert @bybit_item.scheduled_for_deletion?
  end

  test "invalid create from the page shows the error in the panel" do
    post bybit_items_url,
         params: { bybit_item: { api_key: "", api_secret: "" } },
         as: :turbo_stream

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "bybit-providers-panel"
    assert_includes response.body, %(id="bybit-providers-panel")
    assert_includes response.body, ERB::Util.html_escape("can't be blank")
  end

  test "a second and third connection are added beside the first, named apart" do
    assert_difference -> { @family.bybit_items.count }, 2 do
      post bybit_items_url, params: { bybit_item: { name: "", api_key: "second_key", api_secret: "s2" } }
      post bybit_items_url, params: { bybit_item: { name: "", api_key: "third_key", api_secret: "s3" } }
    end

    assert_equal [ "Bybit", "Bybit 2" ], @family.bybit_items.order(:created_at).last(2).map(&:name)
  end

  test "a typed name is kept" do
    post bybit_items_url, params: { bybit_item: { name: "Savings", api_key: "second_key", api_secret: "s2" } }

    assert @family.bybit_items.exists?(name: "Savings")
  end

  test "the same API key cannot be connected twice" do
    assert_no_difference -> { BybitItem.count } do
      post bybit_items_url, params: { bybit_item: { api_key: "test_key", api_secret: "other" } }, as: :turbo_stream
    end

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "bybit-providers-panel"
    assert_includes response.body, I18n.t("activerecord.errors.models.bybit_item.attributes.api_key.already_connected")
  end

  test "a disconnected connection's key can be connected again" do
    @bybit_item.update!(scheduled_for_deletion: true)

    assert_difference -> { @family.bybit_items.count }, 1 do
      post bybit_items_url, params: { bybit_item: { api_key: "test_key", api_secret: "test_secret" } }
    end
  end

  test "a connection is renamed without touching its credentials" do
    patch bybit_item_url(@bybit_item), params: { bybit_item: { name: "Trading" } }

    @bybit_item.reload
    assert_equal "Trading", @bybit_item.name
    assert_equal "test_key", @bybit_item.api_key
  end

  test "the panel lists every connection and still offers another" do
    @family.bybit_items.create!(name: "Second", api_key: "second_key", api_secret: "s2")

    post sync_bybit_item_url(@bybit_item, source: "panel"), as: :turbo_stream

    assert_includes response.body, "Test Bybit"
    assert_includes response.body, "Second"
    assert_includes response.body, ERB::Util.html_escape(I18n.t("settings.providers.exchange_connection.add_connection", provider: "Bybit"))
    assert_select "form[action=?]", bybit_items_path
  end

  test "should sync bybit item" do
    post sync_bybit_item_url(@bybit_item)
    assert_response :redirect
  end

  # Redirecting back to Bank sync would collapse the open connection row.
  test "sync from the panel re-renders the panel in place" do
    post sync_bybit_item_url(@bybit_item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "bybit-providers-panel"
    assert_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert @bybit_item.reload.syncing?
  end

  # Add Account -> Crypto -> Bybit used to bounce back to Settings even when
  # the connection's sync had already found accounts waiting to be set up.
  test "select_accounts opens the account setup of the family's Bybit connection" do
    only_bybit_item(@bybit_item)

    get select_accounts_bybit_items_url

    assert_redirected_to setup_accounts_bybit_item_path(@bybit_item)
    assert_response :see_other
  end

  test "select_accounts sends the user to Settings when no connection has credentials" do
    @family.bybit_items.update_all(scheduled_for_deletion: true)

    get select_accounts_bybit_items_url

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("bybit_items.select_accounts.no_credentials_configured"), flash[:alert]
  end

  test "select_accounts leaves the Add Account modal for Settings at the top level" do
    @family.bybit_items.update_all(scheduled_for_deletion: true)

    get select_accounts_bybit_items_url, headers: { "Turbo-Frame" => "modal" }

    # A redirect would be followed inside the frame and the flash lost.
    assert_response :success
    assert_select "turbo-frame#modal turbo-stream[action=redirect][target=?]", settings_providers_path
    assert_equal I18n.t("bybit_items.select_accounts.no_credentials_configured"), flash[:alert]
  end

  test "select_accounts asks which connection when there are several, unless one is named" do
    only_bybit_item(@bybit_item)
    other_item = BybitItem.create!(family: @family, name: "Second Bybit", api_key: "key_2", api_secret: "secret_2")

    get select_accounts_bybit_items_url

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("bybit_items.select_accounts.select_connection"), flash[:alert]

    get select_accounts_bybit_items_url(bybit_item_id: other_item.id)

    assert_redirected_to setup_accounts_bybit_item_path(other_item)
  end

  test "select_accounts says the named connection is unavailable when another one exists" do
    only_bybit_item(@bybit_item)
    get select_accounts_bybit_items_url(bybit_item_id: SecureRandom.uuid)

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("bybit_items.select_accounts.connection_unavailable"), flash[:alert]
  end

  test "select_accounts carries a safe return_to into setup and drops an unsafe one" do
    only_bybit_item(@bybit_item)
    get select_accounts_bybit_items_url(return_to: "/imports/123/confirm")
    assert_redirected_to setup_accounts_bybit_item_path(@bybit_item, return_to: "/imports/123/confirm")

    get select_accounts_bybit_items_url(return_to: "//evil.example")
    assert_redirected_to setup_accounts_bybit_item_path(@bybit_item)
  end

  test "setup_accounts keeps return_to for finishing and cancelling" do
    get setup_accounts_bybit_item_url(@bybit_item, return_to: "/imports/123/confirm")

    assert_response :success
    assert_select "input[type=hidden][name=return_to][value=?]", "/imports/123/confirm"
    assert_select "a[href=?]", "/imports/123/confirm", text: I18n.t("bybit_items.setup_accounts.cancel")
  end

  test "complete_account_setup returns to return_to" do
    post complete_account_setup_bybit_item_url(@bybit_item), params: { return_to: "/imports/123/confirm" }

    assert_redirected_to "/imports/123/confirm"
  end

  test "should show setup_accounts page" do
    get setup_accounts_bybit_item_url(@bybit_item)
    assert_response :success
  end

  test "complete_account_setup creates accounts for selected bybit_accounts" do
    bybit_account = @bybit_item.bybit_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_difference "Account.count", 1 do
      post complete_account_setup_bybit_item_url(@bybit_item), params: {
        selected_accounts: [ bybit_account.id ]
      }
    end

    assert_response :redirect

    bybit_account.reload
    assert_not_nil bybit_account.current_account
    assert_equal "Crypto", bybit_account.current_account.accountable_type
  end

  test "complete_account_setup updates sync_start_date when provided with a valid past date" do
    bybit_account = @bybit_item.bybit_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    past_date = (Date.current - 7.days).to_s

    post complete_account_setup_bybit_item_url(@bybit_item), params: {
      selected_accounts: [ bybit_account.id ],
      sync_start_date: past_date
    }

    assert_response :redirect
    @bybit_item.reload
    assert_equal Date.parse(past_date), @bybit_item.sync_start_date
  end

  test "complete_account_setup rejects a future sync_start_date and sets flash alert" do
    bybit_account = @bybit_item.bybit_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    future_date = (Date.current + 2.days).to_s
    original_sync_date = @bybit_item.sync_start_date

    post complete_account_setup_bybit_item_url(@bybit_item), params: {
      selected_accounts: [ bybit_account.id ],
      sync_start_date: future_date
    }

    @bybit_item.reload
    assert_nil @bybit_item.sync_start_date
    assert_equal "Sync start date must be a valid date in the past.", flash[:alert]
  end

  test "complete_account_setup with no selection shows message" do
    @bybit_item.bybit_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_no_difference "Account.count" do
      post complete_account_setup_bybit_item_url(@bybit_item), params: {
        selected_accounts: []
      }
    end

    assert_response :redirect
  end

  test "complete_account_setup skips already linked accounts" do
    bybit_account = @bybit_item.bybit_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    # Pre-link the account
    account = Account.create!(
      family: @family,
      name: "Existing Bybit",
      balance: 1000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: bybit_account)

    assert_no_difference "Account.count" do
      post complete_account_setup_bybit_item_url(@bybit_item), params: {
        selected_accounts: [ bybit_account.id ]
      }
    end
  end

  test "cannot access other family's bybit_item" do
    other_family = families(:empty)
    other_item = BybitItem.create!(
      family: other_family,
      name: "Other Bybit",
      api_key: "other_test_key",
      api_secret: "other_test_secret"
    )

    get setup_accounts_bybit_item_url(other_item)
    assert_response :not_found
  end

  test "link_existing_account links manual account to bybit_account" do
    manual_account = Account.create!(
      family: @family,
      name: "Manual Crypto",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    bybit_account = @bybit_item.bybit_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_bybit_items_url, params: {
        account_id: manual_account.id,
        bybit_account_id: bybit_account.id
      }
    end

    bybit_account.reload
    assert_equal manual_account, bybit_account.current_account
  end

  test "link_existing_account rejects account with existing provider" do
    linked_account = Account.create!(
      family: @family,
      name: "Already Linked",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    other_bybit_account = @bybit_item.bybit_accounts.create!(
      name: "Other Account",
      account_type: "margin",
      currency: "USD",
      current_balance: 500.0
    )
    AccountProvider.create!(account: linked_account, provider: other_bybit_account)

    bybit_account = @bybit_item.bybit_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_bybit_items_url, params: {
        account_id: linked_account.id,
        bybit_account_id: bybit_account.id
      }
    end
  end

  test "select_existing_account renders without layout" do
    account = Account.create!(
      family: @family,
      name: "Manual Account",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    get select_existing_account_bybit_items_url, params: { account_id: account.id }
    assert_response :success
  end

  private
    # The bybit_items fixtures add two more credentialed connections.
    def only_bybit_item(item)
      @family.bybit_items.where.not(id: item.id).update_all(scheduled_for_deletion: true)
    end
end
