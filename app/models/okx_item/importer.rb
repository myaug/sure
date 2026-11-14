# frozen_string_literal: true

# Reads the trading and funding accounts and upserts a single combined
# OkxAccount holding every asset, valued in USD.
class OkxItem::Importer
  # A source that fails tells us nothing about what it holds, so "the wallet is
  # empty" and "nothing could be fetched" must not look alike. Raising when every
  # source failed keeps the sync honest.
  class AllRequestsFailed < StandardError; end

  SOURCES = %w[trading funding].freeze

  attr_reader :okx_item, :okx_provider

  def initialize(okx_item, okx_provider:)
    @okx_item = okx_item
    @okx_provider = okx_provider
  end

  def import
    # Refuse a key that could trade or withdraw before reading anything with it.
    okx_provider.read_only_key!

    results = [ fetch_trading, fetch_funding ]

    if results.all? { |result| result[:error].present? }
      raise AllRequestsFailed, results.filter_map { |result| result[:error] }.uniq.join("; ")
    end

    # The holdings processor drops whatever is missing from the asset list, so a
    # source that failed this time keeps its last known assets instead of making
    # live positions vanish on a transient error.
    all_assets = results.flat_map { |result| result[:assets] } + carried_over_assets(results)

    if all_assets.empty? && okx_item.okx_accounts.find_by(account_type: "combined").nil?
      return { success: true, assets_imported: 0, total_usd: 0 }
    end

    total_usd = all_assets.sum { |asset| asset[:usd_value].to_d }.round(2)

    upsert_okx_account(all_assets: all_assets, total_usd: total_usd, results: results)
    okx_item.upsert_okx_snapshot!(
      results.to_h { |result| [ result[:source], result[:raw] ] }.merge("imported_at" => Time.current.iso8601)
    )

    { success: true, assets_imported: all_assets.size, total_usd: total_usd }
  end

  private

    def fetch_trading
      raw = okx_provider.get_trading_balances
      assets = Array(raw["details"]).filter_map do |coin|
        build_asset("trading", coin["ccy"], coin["cashBal"], usd_value: coin["eqUsd"])
      end

      { source: "trading", assets: assets, raw: raw }
    rescue Provider::Okx::Error => e
      failed_source("trading", e)
    end

    def fetch_funding
      raw = okx_provider.get_funding_balances
      assets = raw.filter_map { |coin| build_asset("funding", coin["ccy"], coin["bal"]) }

      { source: "funding", assets: assets, raw: { "balances" => raw } }
    rescue Provider::Okx::Error => e
      failed_source("funding", e)
    end

    def failed_source(source, error)
      # Bad credentials affect every source and belong to the item, not to one wallet.
      raise error if error.is_a?(Provider::Okx::AuthenticationError)

      { source: source, assets: [], raw: nil, error: error.message }
    end

    # nil for empty balances; usd_value is nil when no price could be found.
    def build_asset(source, symbol, balance, usd_value: nil)
      total = balance.to_d
      return if symbol.blank? || total <= 0

      { symbol: symbol.to_s.upcase, total: total.to_s("F"), usd_value: usd_value_for(symbol, total, usd_value), source: source }
    end

    # USD-pegged stablecoins are worth their face value; the family-currency
    # conversion later applies the dated official USD rate to them.
    def usd_value_for(symbol, total, reported)
      return total if CryptoAsset.usd_stablecoin?(symbol)
      return reported.to_d if reported.present?

      price = okx_provider.get_spot_price("#{symbol.to_s.upcase}-USDT")
      price.present? ? (total * price.to_d) : nil
    end

    def carried_over_assets(results)
      failed = results.select { |result| result[:error].present? }
      return [] if failed.empty?

      record_partial_failure(failed)

      sources = failed.map { |result| result[:source] }
      previous = okx_item.okx_accounts.find_by(account_type: "combined")&.raw_payload&.dig("assets")
      return [] if previous.blank?

      previous.map(&:deep_symbolize_keys).select { |asset| sources.include?(asset[:source]) }
    end

    # A partial failure returns normally and never reaches the rescue in
    # OkxItem#import_latest_okx_data, so leave a trace support can find.
    def record_partial_failure(failed)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "OKX import read only part of the wallet",
        source: self.class.name,
        provider_key: "okx",
        family: okx_item.family,
        metadata: {
          okx_item_id: okx_item.id,
          unavailable_sources: failed.map { |result| result[:source] },
          errors: failed.to_h { |result| [ result[:source], result[:error] ] }
        }
      )
    end

    def upsert_okx_account(all_assets:, total_usd:, results:)
      account = okx_item.okx_accounts.find_or_initialize_by(account_type: "combined")

      account.assign_attributes(
        name: okx_item.institution_name.presence || "OKX",
        currency: "USD",
        current_balance: total_usd,
        institution_metadata: build_institution_metadata(all_assets),
        raw_payload: {
          "assets" => all_assets.map(&:stringify_keys),
          "fetched_at" => Time.current.iso8601
        }
      )

      account.save!
      account
    end

    def build_institution_metadata(all_assets)
      SOURCES.each_with_object({}) do |source, hash|
        source_assets = all_assets.select { |asset| asset[:source] == source }
        hash[source] = { "asset_count" => source_assets.size, "assets" => source_assets.map { |asset| asset[:symbol] } }
      end
    end
end
