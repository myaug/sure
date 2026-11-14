require "test_helper"

class MexcItemsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @mexc_item = MexcItem.create!(
      family: @family,
      name: "Test MEXC",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "should destroy mexc item" do
    assert_difference("MexcItem.count", 0) do # doesn't delete immediately
      delete mexc_item_url(@mexc_item)
    end

    assert_redirected_to settings_providers_path
    @mexc_item.reload
    assert @mexc_item.scheduled_for_deletion?
  end

  test "invalid create from the page shows the error in the panel" do
    post mexc_items_url,
         params: { mexc_item: { api_key: "", api_secret: "" } },
         as: :turbo_stream

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "mexc-providers-panel"
    assert_includes response.body, %(id="mexc-providers-panel")
    assert_includes response.body, ERB::Util.html_escape("can't be blank")
  end

  test "should sync mexc item" do
    post sync_mexc_item_url(@mexc_item)
    assert_response :redirect
  end

  # Redirecting back to Bank sync would collapse the open connection row.
  test "sync from the panel re-renders the panel in place" do
    post sync_mexc_item_url(@mexc_item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "mexc-providers-panel"
    assert_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert @mexc_item.reload.syncing?
  end

  # Add Account -> Crypto -> MEXC used to bounce back to Settings even when
  # the connection's sync had already found accounts waiting to be set up.
  test "select_accounts opens the account setup of the family's MEXC connection" do
    only_mexc_item(@mexc_item)

    get select_accounts_mexc_items_url

    assert_redirected_to setup_accounts_mexc_item_path(@mexc_item)
    assert_response :see_other
  end

  test "select_accounts sends the user to Settings when no connection has credentials" do
    @family.mexc_items.update_all(scheduled_for_deletion: true)

    get select_accounts_mexc_items_url

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("mexc_items.select_accounts.no_credentials_configured"), flash[:alert]
  end

  test "select_accounts leaves the Add Account modal for Settings at the top level" do
    @family.mexc_items.update_all(scheduled_for_deletion: true)

    get select_accounts_mexc_items_url, headers: { "Turbo-Frame" => "modal" }

    # A redirect would be followed inside the frame and the flash lost.
    assert_response :success
    assert_select "turbo-frame#modal turbo-stream[action=redirect][target=?]", settings_providers_path
    assert_equal I18n.t("mexc_items.select_accounts.no_credentials_configured"), flash[:alert]
  end

  test "select_accounts asks which connection when there are several, unless one is named" do
    only_mexc_item(@mexc_item)
    other_item = MexcItem.create!(family: @family, name: "Second MEXC", api_key: "key_2", api_secret: "secret_2")

    get select_accounts_mexc_items_url

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("mexc_items.select_accounts.select_connection"), flash[:alert]

    get select_accounts_mexc_items_url(mexc_item_id: other_item.id)

    assert_redirected_to setup_accounts_mexc_item_path(other_item)
  end

  test "select_accounts says the named connection is unavailable when another one exists" do
    only_mexc_item(@mexc_item)
    get select_accounts_mexc_items_url(mexc_item_id: SecureRandom.uuid)

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("mexc_items.select_accounts.connection_unavailable"), flash[:alert]
  end

  test "select_accounts carries a safe return_to into setup and drops an unsafe one" do
    only_mexc_item(@mexc_item)
    get select_accounts_mexc_items_url(return_to: "/imports/123/confirm")
    assert_redirected_to setup_accounts_mexc_item_path(@mexc_item, return_to: "/imports/123/confirm")

    get select_accounts_mexc_items_url(return_to: "//evil.example")
    assert_redirected_to setup_accounts_mexc_item_path(@mexc_item)
  end

  test "setup_accounts keeps return_to for finishing and cancelling" do
    get setup_accounts_mexc_item_url(@mexc_item, return_to: "/imports/123/confirm")

    assert_response :success
    assert_select "input[type=hidden][name=return_to][value=?]", "/imports/123/confirm"
    assert_select "a[href=?]", "/imports/123/confirm", text: I18n.t("mexc_items.setup_accounts.cancel")
  end

  test "complete_account_setup returns to return_to" do
    post complete_account_setup_mexc_item_url(@mexc_item), params: { return_to: "/imports/123/confirm" }

    assert_redirected_to "/imports/123/confirm"
  end

  test "should show setup_accounts page" do
    get setup_accounts_mexc_item_url(@mexc_item)
    assert_response :success
  end

  test "complete_account_setup creates accounts for selected mexc_accounts" do
    mexc_account = @mexc_item.mexc_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_difference "Account.count", 1 do
      post complete_account_setup_mexc_item_url(@mexc_item), params: {
        selected_accounts: [ mexc_account.id ]
      }
    end

    assert_response :redirect

    mexc_account.reload
    assert_not_nil mexc_account.current_account
    assert_equal "Crypto", mexc_account.current_account.accountable_type
  end

  test "complete_account_setup updates sync_start_date when provided with a valid past date" do
    mexc_account = @mexc_item.mexc_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    past_date = (Date.current - 7.days).to_s

    post complete_account_setup_mexc_item_url(@mexc_item), params: {
      selected_accounts: [ mexc_account.id ],
      sync_start_date: past_date
    }

    assert_response :redirect
    @mexc_item.reload
    assert_equal Date.parse(past_date), @mexc_item.sync_start_date
  end

  test "complete_account_setup rejects a future sync_start_date and sets flash alert" do
    mexc_account = @mexc_item.mexc_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    future_date = (Date.current + 2.days).to_s
    original_sync_date = @mexc_item.sync_start_date

    post complete_account_setup_mexc_item_url(@mexc_item), params: {
      selected_accounts: [ mexc_account.id ],
      sync_start_date: future_date
    }

    @mexc_item.reload
    assert_nil @mexc_item.sync_start_date
    assert_equal "Sync start date must be a valid date in the past.", flash[:alert]
  end

  test "complete_account_setup with no selection shows message" do
    @mexc_item.mexc_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_no_difference "Account.count" do
      post complete_account_setup_mexc_item_url(@mexc_item), params: {
        selected_accounts: []
      }
    end

    assert_response :redirect
  end

  test "complete_account_setup skips already linked accounts" do
    mexc_account = @mexc_item.mexc_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    # Pre-link the account
    account = Account.create!(
      family: @family,
      name: "Existing MEXC",
      balance: 1000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: mexc_account)

    assert_no_difference "Account.count" do
      post complete_account_setup_mexc_item_url(@mexc_item), params: {
        selected_accounts: [ mexc_account.id ]
      }
    end
  end

  test "cannot access other family's mexc_item" do
    other_family = families(:empty)
    other_item = MexcItem.create!(
      family: other_family,
      name: "Other MEXC",
      api_key: "other_test_key",
      api_secret: "other_test_secret"
    )

    get setup_accounts_mexc_item_url(other_item)
    assert_response :not_found
  end

  test "link_existing_account links manual account to mexc_account" do
    manual_account = Account.create!(
      family: @family,
      name: "Manual Crypto",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    mexc_account = @mexc_item.mexc_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_mexc_items_url, params: {
        account_id: manual_account.id,
        mexc_account_id: mexc_account.id
      }
    end

    mexc_account.reload
    assert_equal manual_account, mexc_account.current_account
  end

  test "link_existing_account rejects account with existing provider" do
    linked_account = Account.create!(
      family: @family,
      name: "Already Linked",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    other_mexc_account = @mexc_item.mexc_accounts.create!(
      name: "Other Account",
      account_type: "margin",
      currency: "USD",
      current_balance: 500.0
    )
    AccountProvider.create!(account: linked_account, provider: other_mexc_account)

    mexc_account = @mexc_item.mexc_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_mexc_items_url, params: {
        account_id: linked_account.id,
        mexc_account_id: mexc_account.id
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

    get select_existing_account_mexc_items_url, params: { account_id: account.id }
    assert_response :success
  end

  private
    # The mexc_items fixtures add two more credentialed connections.
    def only_mexc_item(item)
      @family.mexc_items.where.not(id: item.id).update_all(scheduled_for_deletion: true)
    end
end
