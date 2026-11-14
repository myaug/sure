# frozen_string_literal: true

# Creates/updates one Holding per (asset, wallet) pair in the combined OkxAccount.
class OkxAccount::HoldingsProcessor
  include OkxAccount::UsdConverter

  def initialize(okx_account)
    @okx_account = okx_account
  end

  def process
    unless account&.accountable_type == "Crypto"
      Rails.logger.info "OkxAccount::HoldingsProcessor - skipping: not a Crypto account"
      return
    end

    assets = raw_assets
    # No asset list at all means nothing has reported yet, not an empty wallet;
    # cleaning up on missing information would delete real holdings.
    return if assets.nil?

    assets.each { |asset| process_asset(asset) }
    cleanup_stale_holdings!(assets)
  rescue StandardError => e
    Rails.logger.error "OkxAccount::HoldingsProcessor - error: #{e.message}"
    nil
  end

  private

    attr_reader :okx_account

    def target_currency
      okx_account.okx_item.family.currency
    end

    def account
      okx_account.current_account
    end

    def raw_assets
      okx_account.raw_payload&.dig("assets")
    end

    # OKX reports what the wallet holds now, so today's holding for an asset
    # missing from the payload has left the wallet. Keyed on the payload, not on
    # what was priced, so a price outage does not make a holding disappear.
    def cleanup_stale_holdings!(assets)
      provider_id = okx_account.account_provider&.id
      return if provider_id.nil?

      keep = assets.filter_map { |asset| external_id_for(asset) }
      scope = account.holdings.where(account_provider_id: provider_id, date: Date.current)
      scope = scope.where.not(external_id: keep) if keep.any?

      removed = scope.delete_all
      Rails.logger.info "OkxAccount::HoldingsProcessor - removed #{removed} holding(s) no longer in the wallet" if removed.positive?
    end

    def external_id_for(asset)
      symbol = asset["symbol"]
      return if symbol.blank? || asset["total"].to_d.zero?

      holding_external_id(symbol, asset["source"])
    end

    def holding_external_id(symbol, source)
      "okx_#{symbol}_#{source}_#{Date.current}"
    end

    def process_asset(asset)
      symbol = asset["symbol"]
      total = asset["total"].to_d
      return if symbol.blank? || total.zero?

      # Unpriced assets are skipped rather than valued at zero or at 1:1.
      return if asset["usd_value"].blank?

      security = OkxAccount::SecurityResolver.resolve(symbol)
      return unless security

      amount_usd = asset["usd_value"].to_d
      amount, _stale, _rate_date = convert_from_usd(amount_usd, date: Date.current)
      price, _, _ = convert_from_usd(amount_usd / total, date: Date.current)

      import_adapter.import_holding(
        security: security,
        quantity: total,
        amount: amount,
        currency: target_currency,
        date: Date.current,
        price: price,
        cost_basis: nil,
        external_id: holding_external_id(symbol, asset["source"]),
        account_provider_id: okx_account.account_provider&.id,
        source: "okx",
        delete_future_holdings: false
      )
    rescue StandardError => e
      Rails.logger.error "OkxAccount::HoldingsProcessor - failed asset #{symbol}: #{e.message}"
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end
end
