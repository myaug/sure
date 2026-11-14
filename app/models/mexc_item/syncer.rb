# frozen_string_literal: true

# Orchestrates the sync process for a MEXC connection.
class MexcItem::Syncer
  include SyncStats::Collector

  attr_reader :mexc_item

  def initialize(mexc_item)
    @mexc_item = mexc_item
  end

  def perform_sync(sync)
    # Phase 1: Check credentials
    sync.update!(status_text: I18n.t("mexc_item.syncer.checking_credentials")) if sync.respond_to?(:status_text)
    unless mexc_item.credentials_configured?
      mexc_item.update!(status: :requires_update)
      mark_failed(sync, I18n.t("mexc_item.syncer.credentials_invalid"))
      return
    end

    begin
      # Phase 2: Import from MEXC APIs
      sync.update!(status_text: I18n.t("mexc_item.syncer.importing_accounts")) if sync.respond_to?(:status_text)
      mexc_item.import_latest_mexc_data

      # Clear error status if import succeeds
      mexc_item.update!(status: :good) if mexc_item.status == "requires_update"

      # Phase 3: Check setup status
      sync.update!(status_text: I18n.t("mexc_item.syncer.checking_configuration")) if sync.respond_to?(:status_text)
      collect_setup_stats(sync, provider_accounts: mexc_item.mexc_accounts.to_a)

      unlinked = mexc_item.mexc_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
      linked = mexc_item.mexc_accounts.joins(:account_provider).joins(:account).merge(Account.visible)

      if unlinked.any?
        mexc_item.update!(pending_account_setup: true)
        sync.update!(status_text: I18n.t("mexc_item.syncer.accounts_need_setup", count: unlinked.count)) if sync.respond_to?(:status_text)
      else
        mexc_item.update!(pending_account_setup: false)
      end

      # Phase 4: Process linked accounts
      if linked.any?
        sync.update!(status_text: I18n.t("mexc_item.syncer.processing_accounts")) if sync.respond_to?(:status_text)
        mexc_item.process_accounts

        # Phase 5: Schedule balance calculations
        sync.update!(status_text: I18n.t("mexc_item.syncer.calculating_balances")) if sync.respond_to?(:status_text)
        mexc_item.schedule_account_syncs(
          parent_sync: sync,
          window_start_date: sync.window_start_date,
          window_end_date: sync.window_end_date
        )

        account_ids = linked.map { |ba| ba.current_account&.id }.compact
        if account_ids.any?
          collect_transaction_stats(sync, account_ids: account_ids, source: "mexc")
          collect_trades_stats(sync, account_ids: account_ids, source: "mexc")
        end
      end
    rescue StandardError => e
      Rails.logger.error "MexcItem::Syncer - unexpected error during sync: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      mark_failed(sync, e.message)
      raise
    end
  end

  def perform_post_sync
    # no-op
  end

  private

    def mark_failed(sync, error_message)
      if sync.respond_to?(:status) && sync.status.to_s == "completed"
        Rails.logger.warn("MexcItem::Syncer#mark_failed called after completion: #{error_message}")
        return
      end

      sync.start! if sync.respond_to?(:may_start?) && sync.may_start?

      if sync.respond_to?(:may_fail?) && sync.may_fail?
        sync.fail!
      elsif sync.respond_to?(:status)
        sync.update!(status: :failed)
      end

      sync.update!(error: error_message) if sync.respond_to?(:error)
      sync.update!(status_text: error_message) if sync.respond_to?(:status_text)
    end
end
