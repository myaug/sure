# frozen_string_literal: true

# Reads the spot wallet and upserts a single combined MexcAccount holding every
# asset, valued in USD.
class MexcItem::Importer
  attr_reader :mexc_item, :mexc_provider

  def initialize(mexc_item, mexc_provider:)
    @mexc_item = mexc_item
    @mexc_provider = mexc_provider
  end

  def import
    # Raises on any failure: the wallet is a single source, so an error means
    # nothing was read and the previous snapshot must be left alone.
    raw = mexc_provider.get_account
    assets = build_assets(Array(raw["balances"]))

    if assets.empty? && mexc_item.mexc_accounts.find_by(account_type: "combined").nil?
      return { success: true, assets_imported: 0, total_usd: 0 }
    end

    total_usd = assets.sum { |asset| asset[:usd_value].to_d }.round(2)

    upsert_mexc_account(assets: assets, total_usd: total_usd)
    mexc_item.upsert_mexc_snapshot!({ "spot" => raw, "imported_at" => Time.current.iso8601 })

    { success: true, assets_imported: assets.size, total_usd: total_usd }
  end

  private

    def build_assets(balances)
      held = balances.filter_map do |balance|
        total = balance["free"].to_d + balance["locked"].to_d
        symbol = balance["asset"].to_s.upcase
        [ symbol, total ] if symbol.present? && total.positive?
      end

      # One request prices everything, and only when something needs pricing.
      prices = held.any? { |symbol, _| !CryptoAsset.usd_stablecoin?(symbol) } ? mexc_provider.get_all_prices : {}

      held.map do |symbol, total|
        { symbol: symbol, total: total.to_s("F"), usd_value: usd_value_for(symbol, total, prices), source: "spot" }
      end
    end

    # USD-pegged stablecoins are worth their face value; the family-currency
    # conversion later applies the dated official USD rate to them. nil when no
    # USDT pair prices the asset.
    def usd_value_for(symbol, total, prices)
      return total if CryptoAsset.usd_stablecoin?(symbol)

      price = prices["#{symbol}USDT"]
      price.present? ? (total * price.to_d) : nil
    end

    def upsert_mexc_account(assets:, total_usd:)
      account = mexc_item.mexc_accounts.find_or_initialize_by(account_type: "combined")

      account.assign_attributes(
        name: mexc_item.institution_name.presence || "MEXC",
        currency: "USD",
        current_balance: total_usd,
        institution_metadata: { "spot" => { "asset_count" => assets.size, "assets" => assets.map { |asset| asset[:symbol] } } },
        raw_payload: { "assets" => assets.map(&:stringify_keys), "fetched_at" => Time.current.iso8601 }
      )

      account.save!
      account
    end
end
