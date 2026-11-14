# frozen_string_literal: true

# Updates the account balance and imports spot trades.
class MexcAccount::Processor
  include MexcAccount::UsdConverter
  include CryptoTransfer::ExchangeMovements

  SOURCE = "mexc"
  SECURITY_RESOLVER = MexcAccount::SecurityResolver
  PROVIDER_ERROR = Provider::Mexc::Error

  # Quote currencies probed for each held asset, and the ones a symbol can end in.
  TRADE_QUOTES = %w[USDT USDC].freeze
  QUOTE_CURRENCIES = %w[USDT USDC BTC ETH EUR USD].freeze

  # Without a configured start date, history begins this far back. MEXC itself
  # only serves the past month.
  DEFAULT_LOOKBACK = 30.days

  # A pair is re-read from slightly before where the last scan ended, so a trade
  # that settled late is not missed. Entries are deduplicated by trade id.
  SCAN_OVERLAP_MS = 60 * 60 * 1000

  attr_reader :mexc_account

  def initialize(mexc_account)
    @mexc_account = mexc_account
  end

  def process
    unless mexc_account.current_account.present?
      Rails.logger.info "MexcAccount::Processor - no linked account for #{mexc_account.id}, skipping"
      return
    end

    begin
      MexcAccount::HoldingsProcessor.new(mexc_account).process
    rescue StandardError => e
      Rails.logger.error "MexcAccount::Processor - holdings failed for #{mexc_account.id}: #{e.message}"
    end

    process_account!
    fetch_and_process_trades
    fetch_and_process_transfers

    # The account was anchored before this history existed; the anchor has to precede it.
    mexc_account.current_account.ensure_opening_anchor_precedes_entries
  end

  private

    def target_currency
      mexc_account.mexc_item.family.currency
    end

    def provider
      @provider ||= mexc_account.mexc_item&.mexc_provider
    end

    def process_account!
      raw_usd = (mexc_account.current_balance || 0).to_d
      amount, stale, rate_date = convert_from_usd(raw_usd, date: Date.current)

      mexc_account.current_account.update!(balance: amount, cash_balance: 0, currency: target_currency)
      mexc_account.update!(extra: mexc_account.extra.to_h.deep_merge(build_stale_extra(stale, rate_date, Date.current)))
    rescue StandardError => e
      Rails.logger.error "MexcAccount::Processor - account update failed for #{mexc_account.id}: #{e.message}"
      raise
    end

    # MEXC lists trades per symbol, so the pairs are the held assets against the
    # usual quotes plus every pair scanned before, which recovers sold-out assets.
    def fetch_and_process_trades
      return unless provider

      now_ms = Time.current.to_i * 1000
      scanned = scanned_until
      fetched = {}

      pairs_to_scan(scanned).each do |pair|
        trades = fetch_pair_trades(pair, from_ms: scan_start_ms(scanned[pair], now_ms), to_ms: now_ms)
        fetched[pair] = trades unless trades.nil?
      end

      # Entries first: if this raises, the cursors below are not advanced and
      # the next sync retries the same range.
      unconverted = fetched.flat_map do |pair, trades|
        trades.sort_by { |trade| trade["time"].to_i }.filter_map { |trade| process_trade(trade, pair) }
      end
      retried, attempts = retry_unconverted_trades(mexc_account, unconverted)

      held = retried.group_by(&:scope).transform_values { |trades| trades.map(&:time_ms).min }
      cursors = fetched.keys.index_with { |pair| held[pair] || now_ms }
      store_trade_cursor(mexc_account, "scanned_until", scanned.merge(cursors), attempts)
    end

    def account
      mexc_account.current_account
    end

    # Deposits and withdrawals: Transfer-labelled trades that CryptoTransfer::Matcher
    # can pair with the other side. They need a permission trades do not, so a key
    # without it keeps its balances and trades and loses only these.
    def fetch_and_process_transfers
      return unless provider

      importing_movements("deposits and withdrawals") do
        now_ms = Time.current.to_i * 1000
        from_ms = transfer_scan_start_ms(
          mexc_account.raw_transactions_payload.to_h["last_transfer_scan"]&.to_i,
          mexc_account.mexc_item.sync_start_date,
          lookback: DEFAULT_LOOKBACK, retention_ms: Provider::Mexc::RECORD_HISTORY_MS, now_ms: now_ms
        )

        deposits = []
        withdrawals = []
        each_transfer_window(from_ms, now_ms, Provider::Mexc::RECORD_WINDOW_MS) do |window_start, window_end|
          deposits.concat(Array(provider.get_deposit_history(start_time: window_start, end_time: window_end)))
          withdrawals.concat(Array(provider.get_withdraw_history(start_time: window_start, end_time: window_end)))
        end

        deposits.uniq.each { |deposit| record_deposit(deposit) }
        withdrawals.uniq.each { |withdrawal| record_withdrawal(withdrawal) }

        store_movement_cursor(mexc_account, "last_transfer_scan", now_ms)
        reprice_missing_movements
      end
    end

    def record_deposit(deposit)
      return unless [ 5, 12 ].include?(deposit["status"].to_i)

      record_movement(
        external_id: "mexc_deposit_#{deposit["coin"]}_#{deposit["txId"].presence || deposit["insertTime"]}",
        symbol: deposit["coin"],
        quantity: deposit["amount"].to_d,
        time_ms: deposit["insertTime"],
        tx_hash: deposit["txId"],
        network: deposit["network"],
        address: deposit["address"],
        provider_meta: { "type" => "deposit", "network" => deposit["network"], "tx_id" => deposit["txId"] }
      )
    end

    # The fee is charged on top of the amount, so both leave the balance.
    def record_withdrawal(withdrawal)
      return unless withdrawal["status"].to_i == 7

      record_movement(
        external_id: "mexc_withdraw_#{withdrawal["id"]}",
        symbol: withdrawal["coin"],
        quantity: -(withdrawal["amount"].to_d + withdrawal["transactionFee"].to_d),
        time_ms: withdrawal["updateTime"].presence || withdrawal["applyTime"],
        tx_hash: withdrawal["txId"].presence || withdrawal["transHash"],
        network: withdrawal["network"],
        address: withdrawal["address"],
        provider_meta: { "type" => "withdrawal", "id" => withdrawal["id"], "network" => withdrawal["network"], "tx_id" => withdrawal["txId"].presence || withdrawal["transHash"], "fee" => withdrawal["transactionFee"] }
      )
    end

    # nil when MEXC does not list the pair, which is not an error.
    def fetch_pair_trades(pair, from_ms:, to_ms:)
      provider.get_my_trades(pair, start_time: from_ms, end_time: to_ms)
    rescue Provider::Mexc::InvalidSymbolError => e
      Rails.logger.debug "MexcAccount::Processor - skipping #{pair}: #{e.message}"
      nil
    end

    def scanned_until
      mexc_account.raw_transactions_payload&.dig("scanned_until").to_h
    end

    def pairs_to_scan(scanned)
      assets = mexc_account.raw_payload&.dig("assets").to_a.filter_map { |asset| asset["symbol"] }
      current = assets.reject { |symbol| CryptoAsset.usd_stablecoin?(symbol) }.product(TRADE_QUOTES).map(&:join)

      (current + scanned.keys).uniq
    end

    def scan_start_ms(scanned_ms, now_ms)
      configured_start = mexc_account.mexc_item.sync_start_date
      start_ms = if scanned_ms
        scanned_ms.to_i - SCAN_OVERLAP_MS
      elsif configured_start
        configured_start.to_time.to_i * 1000
      else
        (Time.current - DEFAULT_LOOKBACK).to_i * 1000
      end

      [ start_ms, now_ms - Provider::Mexc::TRADES_HISTORY_MS + 60_000 ].max
    end

    # Returns an UnconvertedTrade when the trade could not be imported yet, else nil.
    def process_trade(trade, pair)
      account = mexc_account.current_account
      return unless account

      external_id = "mexc_spot_#{trade["symbol"]}_#{trade["id"]}"
      return if trade["id"].blank? || account.entries.exists?(external_id: external_id)

      qty = trade["qty"].to_d
      return if qty.zero?

      time_ms = trade["time"].to_i
      base, quote = split_symbol(trade["symbol"])
      return unconverted_trade(external_id, time_ms: time_ms, reason: "unknown_pair", symbol: trade["symbol"], scope: pair) if base.blank?
      return if CryptoAsset.usd_stablecoin?(base)

      security = MexcAccount::SecurityResolver.resolve(base)
      return unconverted_trade(external_id, time_ms: time_ms, reason: "no_security", symbol: trade["symbol"], scope: pair) unless security

      date = Time.zone.at(time_ms / 1000).to_date
      amount_usd = quote_to_usd(trade["quoteQty"].to_d, quote, date: date)
      price_usd = quote_to_usd(trade["price"].to_d, quote, date: date)

      if amount_usd.nil? || price_usd.nil?
        Rails.logger.warn "MexcAccount::Processor - holding trade #{trade["id"]}: could not convert #{quote} to USD"
        return unconverted_trade(external_id, time_ms: time_ms, reason: "no_usd_price", symbol: trade["symbol"], scope: pair)
      end

      fee = fee_in_usd(trade, base, price_usd, date: date)
      buy = trade.key?("isBuyer") ? trade["isBuyer"] : trade["buyer"]
      amount_usd = amount_usd.round(2)

      account.entries.create!(
        date: date,
        name: "#{buy ? "Buy" : "Sell"} #{qty.round(8)} #{base}",
        amount: buy ? -amount_usd : amount_usd,
        currency: "USD",
        external_id: external_id,
        source: "mexc",
        entryable: Trade.new(
          security: security,
          qty: buy ? qty : -qty,
          price: price_usd,
          currency: "USD",
          fee: fee,
          investment_activity_label: buy ? "Buy" : "Sell"
        )
      )
      nil
    rescue StandardError => e
      Rails.logger.error "MexcAccount::Processor - failed to process trade #{trade["id"]}: #{e.message}"
      raise
    end

    def split_symbol(symbol)
      quote = QUOTE_CURRENCIES.find { |candidate| symbol.to_s.end_with?(candidate) && symbol.to_s.length > candidate.length }
      return [ nil, nil ] unless quote

      [ symbol.to_s.delete_suffix(quote), quote ]
    end

    # Stablecoins and USD are 1:1; crypto quotes use MEXC's daily close; fiat
    # quotes fall back to the app's exchange rates. nil when nothing can price it.
    def quote_to_usd(amount, quote, date:)
      return amount if CryptoAsset.usd_stablecoin?(quote) || quote == "USD"

      spot = provider&.get_historical_price("#{quote}USDT", date) || provider&.get_spot_price("#{quote}USDT")
      return (amount * spot.to_d).round(8) if spot.present?

      rate = ExchangeRate.find_or_fetch_rate(from: quote, to: "USD", date: date, cache: true)
      rate.present? ? (amount * rate.rate.to_d).round(8) : nil
    rescue StandardError => e
      Rails.logger.warn "MexcAccount::Processor - could not convert #{quote} to USD: #{e.message}"
      nil
    end

    # The commission is charged in commissionAsset: usually the received asset
    # or MX. Anything that cannot be priced counts as 0.
    def fee_in_usd(trade, base, price_usd, date:)
      fee = trade["commission"].to_d.abs
      currency = trade["commissionAsset"].to_s.upcase
      return 0 if fee.zero? || currency.blank?
      return fee if CryptoAsset.usd_stablecoin?(currency) || currency == "USD"
      return (fee * price_usd).round(8) if currency == base

      quote_to_usd(fee, currency, date: date) || 0
    end
end
