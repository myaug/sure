# frozen_string_literal: true

# Updates the account balance and imports spot fills as trades.
class OkxAccount::Processor
  include OkxAccount::UsdConverter
  include CryptoTransfer::ExchangeMovements

  SOURCE = "okx"
  SECURITY_RESOLVER = OkxAccount::SecurityResolver
  PROVIDER_ERROR = Provider::Okx::Error

  # Without a configured start date, history begins this far back.
  DEFAULT_LOOKBACK = 30.days

  attr_reader :okx_account

  def initialize(okx_account)
    @okx_account = okx_account
  end

  def process
    unless okx_account.current_account.present?
      Rails.logger.info "OkxAccount::Processor - no linked account for #{okx_account.id}, skipping"
      return
    end

    begin
      OkxAccount::HoldingsProcessor.new(okx_account).process
    rescue StandardError => e
      Rails.logger.error "OkxAccount::Processor - holdings failed for #{okx_account.id}: #{e.message}"
    end

    process_account!
    fetch_and_process_trades
    fetch_and_process_transfers

    # The account was anchored before this history existed; the anchor has to precede it.
    okx_account.current_account.ensure_opening_anchor_precedes_entries
  end

  private

    def target_currency
      okx_account.okx_item.family.currency
    end

    def provider
      @provider ||= okx_account.okx_item&.okx_provider
    end

    def process_account!
      raw_usd = (okx_account.current_balance || 0).to_d
      amount, stale, rate_date = convert_from_usd(raw_usd, date: Date.current)

      okx_account.current_account.update!(balance: amount, cash_balance: 0, currency: target_currency)
      okx_account.update!(extra: okx_account.extra.to_h.deep_merge(build_stale_extra(stale, rate_date, Date.current)))
    rescue StandardError => e
      Rails.logger.error "OkxAccount::Processor - account update failed for #{okx_account.id}: #{e.message}"
      raise
    end

    def fetch_and_process_trades
      return unless provider

      now_ms = Time.current.to_i * 1000
      fills = provider.get_spot_fills(begin_time: history_start_ms(now_ms))

      # Entries first: if this raises, the cursor below is not advanced and the
      # next sync retries the same range. Oldest first so cost basis builds in order.
      unconverted = fills.reverse.filter_map { |fill| process_fill(fill) }
      retried, attempts = retry_unconverted_trades(okx_account, unconverted)

      newest = fills.filter_map { |fill| fill["fillTime"].presence&.to_i }.max
      cursor = retried.map(&:time_ms).min || [ newest, last_fill_time ].compact.max || now_ms
      store_trade_cursor(okx_account, "last_fill_time", cursor, attempts)
    end

    def account
      okx_account.current_account
    end

    # Deposits and withdrawals: Transfer-labelled trades that CryptoTransfer::Matcher
    # can pair with the other side. Read after the trades and never fatal to them.
    def fetch_and_process_transfers
      return unless provider

      importing_movements("deposits and withdrawals") do
        now_ms = Time.current.to_i * 1000
        from_ms = transfer_scan_start_ms(
          okx_account.raw_transactions_payload.to_h["last_transfer_scan"]&.to_i,
          okx_account.okx_item.sync_start_date,
          lookback: DEFAULT_LOOKBACK, retention_ms: Provider::Okx::RECORD_HISTORY_MS, now_ms: now_ms
        )

        provider.get_deposit_history(begin_time: from_ms).each { |deposit| record_deposit(deposit) }
        provider.get_withdrawal_history(begin_time: from_ms).each { |withdrawal| record_withdrawal(withdrawal) }

        store_movement_cursor(okx_account, "last_transfer_scan", now_ms)
        reprice_missing_movements
      end
    end

    # state 1 (credited) and 2 (successful) put coins on the account. An internal
    # transfer names the withdrawal that sent it, which pairs it with that
    # withdrawal when both accounts are OKX's.
    def record_deposit(deposit)
      return unless %w[1 2].include?(deposit["state"].to_s)

      record_movement(
        external_id: "okx_deposit_#{deposit["depId"].presence || deposit["txId"]}",
        symbol: deposit["ccy"],
        quantity: deposit["amt"].to_d,
        time_ms: deposit["ts"],
        tx_hash: deposit["txId"],
        network: deposit["chain"],
        address: deposit["to"],
        reference: (deposit["fromWdId"].presence && "okx:wd:#{deposit["fromWdId"]}"),
        provider_meta: { "type" => "deposit", "id" => deposit["depId"], "chain" => deposit["chain"], "tx_id" => deposit["txId"], "from_wd_id" => deposit["fromWdId"].presence }
      )
    end

    # state "2" is a completed withdrawal. The fee is charged on top of the
    # amount, in feeCcy, so it leaves the balance too.
    def record_withdrawal(withdrawal)
      return unless withdrawal["state"].to_s == "2"

      fee = withdrawal["feeCcy"].to_s.casecmp?(withdrawal["ccy"].to_s) ? withdrawal["fee"].to_d.abs : 0.to_d

      record_movement(
        external_id: "okx_withdraw_#{withdrawal["wdId"]}",
        symbol: withdrawal["ccy"],
        quantity: -(withdrawal["amt"].to_d + fee),
        time_ms: withdrawal["ts"],
        tx_hash: withdrawal["txId"],
        network: withdrawal["chain"],
        address: withdrawal["to"],
        reference: "okx:wd:#{withdrawal["wdId"]}",
        provider_meta: { "type" => "withdrawal", "id" => withdrawal["wdId"], "chain" => withdrawal["chain"], "tx_id" => withdrawal["txId"], "fee" => withdrawal["fee"] }
      )
    end

    def last_fill_time
      okx_account.raw_transactions_payload&.dig("last_fill_time")&.to_i
    end

    # Resume from the newest fill seen (re-reading it is harmless, entries are
    # deduplicated by bill id), else from the configured start date. OKX only
    # keeps three months of fills.
    def history_start_ms(now_ms)
      configured_start = okx_account.okx_item.sync_start_date
      start_ms = last_fill_time ||
        (configured_start ? configured_start.to_time.to_i * 1000 : (Time.current - DEFAULT_LOOKBACK).to_i * 1000)

      note_history_gap(start_ms, now_ms - Provider::Okx::FILLS_HISTORY_MS + 60_000, "trades")
      [ start_ms, now_ms - Provider::Okx::FILLS_HISTORY_MS + 60_000 ].max
    end

    # Returns an UnconvertedTrade when the fill could not be imported yet, else nil.
    def process_fill(fill)
      account = okx_account.current_account
      return unless account

      external_id = "okx_spot_#{fill["billId"]}"
      return if fill["billId"].blank? || account.entries.exists?(external_id: external_id)

      qty = fill["fillSz"].to_d
      return if qty.zero?

      time_ms = (fill["fillTime"].presence || fill["ts"]).to_i
      base, quote = fill["instId"].to_s.split("-", 2)
      return unconverted_trade(external_id, time_ms: time_ms, reason: "unknown_pair", symbol: fill["instId"]) if base.blank? || quote.blank?
      return if CryptoAsset.usd_stablecoin?(base)

      security = OkxAccount::SecurityResolver.resolve(base)
      return unconverted_trade(external_id, time_ms: time_ms, reason: "no_security", symbol: fill["instId"]) unless security

      date = Time.zone.at(time_ms / 1000).to_date
      price = fill["fillPx"].to_d
      amount_usd = quote_to_usd(qty * price, quote, date: date)
      price_usd = quote_to_usd(price, quote, date: date)

      if amount_usd.nil? || price_usd.nil?
        Rails.logger.warn "OkxAccount::Processor - holding fill #{fill["billId"]}: could not convert #{quote} to USD"
        return unconverted_trade(external_id, time_ms: time_ms, reason: "no_usd_price", symbol: fill["instId"])
      end

      fee = fee_in_usd(fill, base, price_usd, date: date)
      buy = fill["side"].to_s.casecmp?("buy")
      amount_usd = amount_usd.round(2)

      account.entries.create!(
        date: date,
        name: "#{buy ? "Buy" : "Sell"} #{qty.round(8)} #{base}",
        amount: buy ? -amount_usd : amount_usd,
        currency: "USD",
        external_id: external_id,
        source: "okx",
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
      Rails.logger.error "OkxAccount::Processor - failed to process fill #{fill["billId"]}: #{e.message}"
      raise
    end

    # Stablecoins and USD are 1:1; crypto quotes use OKX's daily close; fiat
    # quotes fall back to the app's exchange rates. nil when nothing can price it.
    def quote_to_usd(amount, quote, date:)
      return amount if CryptoAsset.usd_stablecoin?(quote) || quote == "USD"

      spot = provider&.get_historical_price("#{quote}-USDT", date) || provider&.get_spot_price("#{quote}-USDT")
      return (amount * spot.to_d).round(8) if spot.present?

      rate = ExchangeRate.find_or_fetch_rate(from: quote, to: "USD", date: date, cache: true)
      rate.present? ? (amount * rate.rate.to_d).round(8) : nil
    rescue StandardError => e
      Rails.logger.warn "OkxAccount::Processor - could not convert #{quote} to USD: #{e.message}"
      nil
    end

    # OKX reports a fee paid as a negative number, in the received asset: the
    # base on a buy, the quote on a sell. Anything else is priced through OKX,
    # and 0 when it cannot be.
    def fee_in_usd(fill, base, price_usd, date:)
      fee = fill["fee"].to_d.abs
      currency = fill["feeCcy"].to_s.upcase
      return 0 if fee.zero? || currency.blank?
      return fee if CryptoAsset.usd_stablecoin?(currency) || currency == "USD"
      return (fee * price_usd).round(8) if currency == base

      quote_to_usd(fee, currency, date: date) || 0
    end
end
