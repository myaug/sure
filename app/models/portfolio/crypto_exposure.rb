# What a family's crypto holdings are worth and where they sit: by token, by
# exchange or wallet, by chain, and how much of it is USD stablecoins.
#
# Everything is in the family currency at the latest dated rate. A holding in a
# currency with no rate is left out of the totals and reported in
# `unconverted`, and an asset the provider cannot price (worth zero while a
# quantity is held) is reported in `unpriced`: a missing figure is shown as
# missing, never counted at 1:1 or as zero value.
#
# Holdings come from the statement, so the viewer's account sharing and the
# "included in reports" setting apply exactly as on the rest of the portfolio.
class Portfolio::CryptoExposure
  Segment = Data.define(:id, :name, :amount, :weight)
  Rate = Data.define(:currency, :value, :date)

  attr_reader :statement

  def initialize(statement)
    @statement = statement
  end

  def any?
    holdings.any?
  end

  def currency
    statement.family.currency
  end

  def total
    @total ||= priced_rows.sum { |row| row[:value] }
  end

  def by_token
    segments(priced_rows.group_by { |row| row[:token] }.transform_values { |rows| rows.sum { |r| r[:value] } })
  end

  def by_venue
    segments(priced_rows.group_by { |row| row[:venue] }.transform_values { |rows| rows.sum { |r| r[:value] } })
  end

  # Exchange balances have no chain, so they are filed under one bucket that the
  # view names, instead of being mistaken for a chain.
  def by_chain
    segments(priced_rows.group_by { |row| row[:chain] }.transform_values { |rows| rows.sum { |r| r[:value] } })
  end

  def stablecoin_total
    @stablecoin_total ||= priced_rows.select { |row| row[:stablecoin] }.sum { |row| row[:value] }
  end

  # Share of the crypto holdings (not of the whole portfolio) that is pegged to
  # the dollar. Nil when nothing is valued yet.
  def stablecoin_share
    return nil unless total.positive?

    (stablecoin_total / total * 100).round(1)
  end

  def stablecoins
    segments(
      priced_rows.select { |row| row[:stablecoin] }.group_by { |row| row[:token] }
        .transform_values { |rows| rows.sum { |r| r[:value] } },
      of: stablecoin_total
    )
  end

  # Names of assets held but not valued: no price from any provider.
  def unpriced
    @unpriced ||= rows.select { |row| row[:unpriced] }.map { |row| row[:token] }.uniq.sort
  end

  # Currencies held with no exchange rate into the family currency.
  def unconverted
    @unconverted ||= rows.select { |row| row[:unconverted] }.map { |row| row[:native_currency] }.uniq.sort
  end

  # The accounts whose last sync used an older rate than today's, or could not
  # read the full transfer history.
  def stale_accounts
    @stale_accounts ||= crypto_accounts.select { |account| stale?(account) }.map(&:name).sort
  end

  def history_truncated_accounts
    @history_truncated_accounts ||= wallet_accounts.select(&:history_truncated?).map(&:display_name).sort
  end

  # The dated USD -> family currency rate that values stablecoins and the
  # USD-quoted assets. Nil when the family reports in USD or no rate exists.
  def usd_rate
    return @usd_rate if defined?(@usd_rate)

    @usd_rate = unless currency == "USD"
      rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: currency, date: Date.current)
      rate && Rate.new(currency: currency, value: rate.rate, date: rate.date)
    end
  end

  private
    def holdings
      @holdings ||= statement.current_holdings.select { |holding| holding.security.crypto? }
    end

    def rows
      @rows ||= holdings.map { |holding| build_row(holding) }
    end

    def priced_rows
      @priced_rows ||= rows.reject { |row| row[:unpriced] || row[:unconverted] }
    end

    def build_row(holding)
      rate = rate_for(holding.currency)
      token = holding.security.crypto_base_asset.presence || holding.security.ticker

      {
        token: token,
        venue: holding.account.name,
        chain: chain_label(holding),
        stablecoin: holding.security.usd_stablecoin?,
        native_currency: holding.currency,
        unpriced: holding.qty.to_d.positive? && holding.amount.to_d.zero?,
        unconverted: rate.nil?,
        value: rate ? holding.amount.to_d * rate : 0.to_d
      }
    end

    def rate_for(from)
      return 1 if from == currency

      @rates ||= {}
      @rates[from] = ExchangeRate.find_or_fetch_rate(from: from, to: currency, date: Date.current)&.rate unless @rates.key?(from)
      @rates[from]
    end

    # A wallet asset's chain lives on its OnchainWalletAccount, reached through
    # the account link the holding carries.
    def chain_label(holding)
      wallet = wallet_by_account_provider[holding.account_provider_id]
      wallet ? wallet.chain_label : nil
    end

    def wallet_by_account_provider
      @wallet_by_account_provider ||= begin
        links = AccountProvider.where(id: holdings.filter_map(&:account_provider_id), provider_type: "OnchainWalletAccount")
        wallets = OnchainWalletAccount.where(id: links.map(&:provider_id)).index_by(&:id)
        links.to_h { |link| [ link.id, wallets[link.provider_id] ] }.compact
      end
    end

    def wallet_accounts
      @wallet_accounts ||= wallet_by_account_provider.values.uniq
    end

    def crypto_accounts
      @crypto_accounts ||= holdings.map(&:account).uniq
    end

    def stale?(account)
      account.account_providers.any? do |link|
        provider = link.provider
        provider.respond_to?(:extra) && provider.extra.to_h.values.any? { |meta| meta.is_a?(Hash) && meta["stale_rate"] == true }
      end
    end

    def segments(grouped, of: total)
      return [] unless of.positive?

      grouped.select { |_, value| value.positive? }.sort_by { |name, value| [ -value, name.to_s ] }.map do |name, value|
        Segment.new(id: name.to_s, name: name, amount: Money.new(value, currency), weight: (value / of * 100).round(1))
      end
    end
end
