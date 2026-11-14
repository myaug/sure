# frozen_string_literal: true

class OkxItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Encrypt sensitive credentials if ActiveRecord encryption is configured
  # api_key uses deterministic encryption for querying, api_secret uses standard encryption
  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :api_secret
    encrypts :api_passphrase
    encrypts :raw_payload
  end

  validates :name, presence: true
  validates :api_key, presence: true
  # Two connections on one key import the same account twice, doubling it. Only
  # checked when the key changes, so an older duplicate can still sync and rename.
  validates :api_key, uniqueness: { scope: :family_id, conditions: -> { where(scheduled_for_deletion: false) }, message: :already_connected }, if: :api_key_changed?
  validates :api_secret, presence: true
  validates :api_passphrase, presence: true

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :okx_accounts, dependent: :destroy
  has_many :accounts, through: :okx_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def import_latest_okx_data
    provider = okx_provider
    unless provider
      raise StandardError, "OKX credentials not configured"
    end

    OkxItem::Importer.new(self, okx_provider: provider).import
  rescue Provider::Okx::AuthenticationError, Provider::Okx::PermissionError => e
    # A revoked, expired, IP-blocked or over-privileged key needs the user, not a retry.
    update!(status: :requires_update)
    capture_import_failure(e)
    raise
  rescue StandardError => e
    capture_import_failure(e)
    raise
  end

  def capture_import_failure(e)
    DebugLogEntry.capture(
      category: "provider_sync",
      level: "error",
      message: "OKX import failed",
      source: self.class.name,
      provider_key: "okx",
      family: family,
      account_provider: okx_accounts.includes(:account_provider).filter_map(&:account_provider).first,
      metadata: { okx_item_id: id, error_class: e.class.name, error: e.message }
    )
    Rails.logger.error "OkxItem #{id} - Failed to import: #{e.message}"
  end
  private :capture_import_failure

  def process_accounts
    Rails.logger.info "OkxItem #{id} - process_accounts: total okx_accounts=#{okx_accounts.count}"

    return [] if okx_accounts.empty?

    okx_accounts.each do |ba|
      Rails.logger.info(
        "OkxItem #{id} - okx_account #{ba.id}: " \
        "name='#{ba.name}' " \
        "account_provider=#{ba.account_provider&.id || 'nil'} " \
        "account=#{ba.account&.id || 'nil'}"
      )
    end

    linked = okx_accounts.joins(:account).merge(Account.visible)
    Rails.logger.info "OkxItem #{id} - found #{linked.count} linked visible accounts to process"

    results = []

    linked.each do |ba|
      begin
        Rails.logger.info "OkxItem #{id} - processing okx_account #{ba.id}"
        result = OkxAccount::Processor.new(ba).process
        results << { okx_account_id: ba.id, success: true, result: result }
      rescue StandardError => e
        Rails.logger.error "OkxItem #{id} - Failed to process account #{ba.id}: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        results << { okx_account_id: ba.id, success: false, error: e.message }
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    results = []
    accounts.visible.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue StandardError => e
        Rails.logger.error "OkxItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_okx_snapshot!(payload)
    update!(raw_payload: payload)
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total == 0
      I18n.t("okx_items.okx_item.sync_status.no_accounts")
    elsif unlinked == 0
      I18n.t("okx_items.okx_item.sync_status.all_synced", count: linked)
    else
      I18n.t("okx_items.okx_item.sync_status.partial_sync", linked_count: linked, unlinked_count: unlinked)
    end
  end

  def stale_rate_accounts
    okx_accounts
      .joins(:account)
      .where(accounts: { status: "active" })
      .where("okx_accounts.extra -> 'okx' ->> 'stale_rate' = 'true'")
  end

  def linked_accounts_count
    okx_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    okx_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    okx_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def credentials_configured?
    api_key.present? && api_secret.present? && api_passphrase.present?
  end

  def set_okx_institution_defaults!
    update!(
      institution_name: "OKX",
      institution_domain: "okx.com",
      institution_url: "https://www.okx.com",
      institution_color: "#000000"
    )
  end
end
