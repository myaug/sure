# frozen_string_literal: true

# Resolves the security that represents a MEXC asset.
#
# One security per asset, never per trading pair, and bound straight to the
# crypto price provider exactly as Onchain::SecurityResolver does, so a coin held
# on MEXC and on-chain is a single security. A Security already created for the
# ticker by another integration is reused.
class MexcAccount::SecurityResolver
  PRICE_PROVIDER = Onchain::SecurityResolver::PRICE_PROVIDER
  EXCHANGE_MIC = Onchain::SecurityResolver::EXCHANGE_MIC

  class << self
    def resolve(asset_symbol)
      asset = asset_symbol.to_s.strip.upcase.delete_prefix(CryptoAsset::TICKER_PREFIX)
      return nil unless asset.match?(Onchain::SecurityResolver::SYMBOL_PATTERN)

      ticker = CryptoAsset.ticker_for(asset)
      existing_security(ticker) || create_security(ticker, asset)
    end

    private

      def existing_security(ticker)
        security = Security.find_by(ticker: ticker, exchange_operating_mic: EXCHANGE_MIC) ||
          Security.where(ticker: ticker).order(:created_at).first
        return nil if security.nil?

        security.update!(price_provider: PRICE_PROVIDER, offline: false) if security.price_provider.blank?
        security
      end

      def create_security(ticker, asset)
        Security.create!(ticker: ticker, name: asset, exchange_operating_mic: EXCHANGE_MIC, price_provider: PRICE_PROVIDER)
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        Rails.logger.warn "MexcAccount::SecurityResolver - could not create #{ticker}: #{e.message}"
        Security.find_by(ticker: ticker)
      end
  end
end
