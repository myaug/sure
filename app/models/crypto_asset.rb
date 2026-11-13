# Provider-neutral facts about crypto assets: how a crypto security is
# identified, which tokens are pegged to the US dollar, and how those are valued.
#
# Valuation path: asset price (quoted in USDT) -> USD (a USD-pegged stablecoin is
# worth 1 USD) -> family currency at the dated official USD rate. USDT is
# deliberately not priced from P2P quotes, so BTC and USDT in one portfolio
# always share a single, historical, official rate.
module CryptoAsset
  # Prefix holdings processors put on a bare coin symbol to tell it apart from
  # a stock ticker.
  TICKER_PREFIX = "CRYPTO:".freeze

  # Operating MICs that identify a crypto security: Binance's market-data MIC and
  # the one the offline Binance fallback writes.
  MICS = %w[BNCX XBNC].freeze

  USD_STABLECOINS = %w[USDT USDC BUSD DAI FDUSD TUSD USDP PYUSD USDG].freeze

  class << self
    def mic?(mic)
      MICS.include?(mic.to_s.upcase)
    end

    def prefixed?(ticker)
      ticker.to_s.upcase.start_with?(TICKER_PREFIX)
    end

    def ticker_for(symbol)
      "#{TICKER_PREFIX}#{symbol.to_s.upcase}"
    end

    def usd_stablecoin?(symbol)
      USD_STABLECOINS.include?(symbol.to_s.upcase.delete_prefix(TICKER_PREFIX))
    end
  end
end
