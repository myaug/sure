# frozen_string_literal: true

class OkxItemsController < ApplicationController
  before_action :set_okx_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :new, :create, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @okx_items = Current.family.okx_items.ordered
  end

  def show
  end

  def new
    @okx_item = Current.family.okx_items.build
  end

  def edit
  end

  def create
    @okx_item = Current.family.okx_items.build(okx_item_params)
    @okx_item.name ||= t(".default_name")

    if @okx_item.save
      @okx_item.set_okx_institution_defaults!
      @okx_item.sync_later

      redirect_to settings_providers_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("okx", alert: @okx_item.errors.full_messages.join(", "))
    end
  end

  # The panel has no edit form, so an update never re-renders it.
  def update
    if @okx_item.update(okx_item_params)
      redirect_to settings_providers_path, notice: t(".success"), status: :see_other
    else
      redirect_to settings_providers_path, alert: @okx_item.errors.full_messages.join(", "), status: :see_other
    end
  end

  def destroy
    @okx_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success")
  end

  def sync
    unless @okx_item.syncing?
      @okx_item.sync_later
    end
    return render_provider_panel("okx", notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Add Account -> Crypto -> OKX lands here. The connection's sync is what
  # finds the accounts, so open that connection's account setup, as Kraken does.
  def select_accounts
    okx_items = Current.family.okx_items.active.ordered.select(&:credentials_configured?)
    okx_item = if params[:okx_item_id].present?
      okx_items.find { |item| item.id.to_s == params[:okx_item_id].to_s }
    elsif okx_items.one?
      okx_items.first
    end

    unless okx_item
      message_key = if params[:okx_item_id].present? && okx_items.any?
        ".connection_unavailable"
      elsif okx_items.many?
        ".select_connection"
      else
        ".no_credentials_configured"
      end
      frame_redirect_to(settings_providers_path, alert: t(message_key))
      return
    end

    redirect_to setup_accounts_okx_item_path(okx_item, return_to: safe_return_to(params[:return_to])), status: :see_other
  end

  def link_accounts
    redirect_to settings_providers_path
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    @available_okx_accounts = Current.family.okx_items
      .includes(okx_accounts: [ :account, { account_provider: :account } ])
      .flat_map(&:okx_accounts)
      .select { |ba| ba.account.present? || ba.account_provider.nil? }
      .sort_by { |ba| ba.updated_at || ba.created_at }
      .reverse

    render :select_existing_account, layout: false
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    okx_account = OkxAccount
      .joins(:okx_item)
      .where(id: params[:okx_account_id], okx_items: { family_id: Current.family.id })
      .first

    unless okx_account
      alert_msg = t(".errors.invalid_okx_account")
      if turbo_frame_request?
        flash.now[:alert] = alert_msg
        render turbo_stream: Array(flash_notification_stream_items)
      else
        redirect_to account_path(@account), alert: alert_msg
      end
      return
    end

    if @account.account_providers.any? || @account.plaid_account_id.present? || @account.simplefin_account_id.present?
      alert_msg = t(".errors.only_manual")
      if turbo_frame_request?
        flash.now[:alert] = alert_msg
        return render turbo_stream: Array(flash_notification_stream_items)
      else
        return redirect_to account_path(@account), alert: alert_msg
      end
    end

    unless @account.crypto?
      alert_msg = t(".errors.only_manual")
      if turbo_frame_request?
        flash.now[:alert] = alert_msg
        return render turbo_stream: Array(flash_notification_stream_items)
      else
        return redirect_to account_path(@account), alert: alert_msg
      end
    end

    Account.transaction do
      okx_account.lock!
      ap = AccountProvider.find_or_initialize_by(provider: okx_account)
      previous_account = ap.account
      ap.account_id = @account.id
      ap.save!

      # Orphan cleanup (detaching the old account from this provider) is handled
      # by the background sync job; no immediate action is required here.
      if previous_account && previous_account.id != @account.id && previous_account.family_id == @account.family_id
        Rails.logger.info("Okx: re-linked OkxAccount #{okx_account.id} from account ##{previous_account.id} to ##{@account.id}")
      end
    end

    if turbo_frame_request?
      item = okx_account.okx_item.reload
      @okx_items = Current.family.okx_items.ordered.includes(:syncs)
      @manual_accounts = Account.uncached { Current.family.accounts.visible_manual_for(Current.user).order(:name).to_a }

      flash.now[:notice] = t(".success")
      @account.reload
      manual_accounts_stream = if @manual_accounts.any?
        turbo_stream.update("manual-accounts", partial: "accounts/index/manual_accounts", locals: { accounts: @manual_accounts })
      else
        turbo_stream.replace("manual-accounts", view_context.tag.div(id: "manual-accounts"))
      end

      render turbo_stream: [
        # Admin-only action (require_admin!), so the card lists every account.
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(item),
          partial: "okx_items/okx_item",
          locals: { okx_item: item, visible_accounts: item.accounts }
        ),
        manual_accounts_stream,
        *Array(flash_notification_stream_items)
      ]
    else
      redirect_to accounts_path, notice: t(".success")
    end
  end

  def setup_accounts
    # Where Add Account was opened from, carried through the form so finishing
    # or cancelling goes back there.
    @return_to = safe_return_to(params[:return_to])
    @okx_accounts = @okx_item.okx_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)
  end

  def complete_account_setup
    setup_params = complete_account_setup_params

    if setup_params[:sync_start_date].present?
      parsed_date = begin
        Date.parse(setup_params[:sync_start_date].to_s)
      rescue ArgumentError
        nil
      end

      if parsed_date.present? && parsed_date <= Date.current
        @okx_item.update!(sync_start_date: parsed_date)
      else
        flash.now[:alert] = t(".invalid_sync_start_date")
      end
    end

    selected_accounts = Array(setup_params[:selected_accounts]).reject(&:blank?)
    created_accounts = []

    selected_accounts.each do |okx_account_id|
      ba = @okx_item.okx_accounts.find_by(id: okx_account_id)
      next unless ba

      begin
        ba.with_lock do
          next if ba.account.present?

          account = Account.create_from_okx_account(ba)
          provider_link = ba.ensure_account_provider!(account)

          if provider_link
            created_accounts << account
          else
            account.destroy!
          end
        end
      rescue StandardError => e
        Rails.logger.error("Failed to setup account for OkxAccount #{ba.id}: #{e.message}")
        next
      end

      ba.reload

      begin
        OkxAccount::HoldingsProcessor.new(ba).process
      rescue StandardError => e
        Rails.logger.error("Failed to process holdings for #{ba.id}: #{e.message}")
      end
    end

    unlinked_remaining = @okx_item.okx_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .count
    @okx_item.update!(pending_account_setup: unlinked_remaining > 0)

    if created_accounts.any?
      flash.now[:notice] = t(".success", count: created_accounts.count)
    elsif selected_accounts.empty?
      flash.now[:notice] = t(".none_selected")
    else
      flash.now[:notice] = t(".no_accounts")
    end

    @okx_item.sync_later if created_accounts.any?

    if turbo_frame_request?
      @okx_items = Current.family.okx_items.ordered.includes(:syncs)
      render turbo_stream: [
        # Admin-only action (require_admin!), so the card lists every account.
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@okx_item),
          partial: "okx_items/okx_item",
          locals: { okx_item: @okx_item, visible_accounts: @okx_item.accounts }
        )
      ] + Array(flash_notification_stream_items)
    else
      redirect_to safe_return_to(params[:return_to]) || accounts_path, status: :see_other
    end
  end

  private

    def set_okx_item
      @okx_item = Current.family.okx_items.find(params[:id])
    end

    def okx_item_params
      params.require(:okx_item).permit(:name, :sync_start_date, :api_key, :api_secret, :api_passphrase)
    end

    def complete_account_setup_params
      params.permit(:sync_start_date, selected_accounts: [])
    end
end
