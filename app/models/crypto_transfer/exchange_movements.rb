# frozen_string_literal: true

# Shared by the exchange processors that import deposits and withdrawals.
#
# A movement is a Transfer-labelled Trade with amount 0 and a signed quantity,
# the same shape on-chain wallets and Kraken use: coins changing place move no
# cash, create no cost basis and realize no gain. What this adds is what pairing
# needs -- the transaction hash, network and address -- kept under
# extra["crypto_transfer"] where CryptoTransfer::Matcher reads them.
#
# The including processor supplies:
#   - #account            the linked Account
#   - #provider           the exchange client, or nil
#   - #quote_to_usd       (amount, symbol, date:) -> BigDecimal or nil
#   - SOURCE              the entry source, e.g. "bybit"
#   - SECURITY_RESOLVER   class answering .resolve(symbol)
#   - PROVIDER_ERROR      the client's base error class
module CryptoTransfer::ExchangeMovements
  # Deposits and withdrawals are listed by when they were requested, but only
  # count once they succeed, so a window is re-read this far back to catch one
  # that settled after the previous sync looked. A withdrawal held for review
  # can take days to complete, which is what sets the length.
  TRANSFER_RESCAN_MS = 7 * 24 * 60 * 60 * 1000

  # Reading slightly before what the exchange keeps is not worth a log entry.
  GAP_TOLERANCE_MS = 24 * 60 * 60 * 1000

  # A trade that could not be priced or matched to a security holds the trade
  # cursor at its time, so later syncs read it again: the price feed or rate
  # that failed may answer next time. After this many failed syncs it is let
  # go, and logged for support, so one bad trade cannot pin the cursor forever.
  UNCONVERTED_TRADE_ATTEMPTS = 5
  UNCONVERTED_TRADES_KEY = "unconverted_trades"

  # Deposits and withdrawals without a price, priced again per sync.
  REPRICE_BATCH = 50

  UnconvertedTrade = Data.define(:external_id, :time_ms, :reason, :symbol, :scope)

  private

    def unconverted_trade(external_id, time_ms:, reason:, symbol:, scope: nil)
      UnconvertedTrade.new(external_id: external_id, time_ms: time_ms.to_i, reason: reason, symbol: symbol, scope: scope)
    end

    # Counts the failed syncs of each trade in `unconverted` and returns
    # [still_retried, attempts]. Attempts only cover trades that failed in this
    # sync, so one converted since drops out. The sync that uses up the last
    # attempt logs the trade.
    def retry_unconverted_trades(provider_account, unconverted)
      previous = provider_account.raw_transactions_payload.to_h[UNCONVERTED_TRADES_KEY].to_h
      attempts = unconverted.to_h { |trade| [ trade.external_id, previous[trade.external_id].to_i + 1 ] }

      retried = unconverted.select do |trade|
        log_abandoned_trade(trade, attempts[trade.external_id]) if attempts[trade.external_id] == UNCONVERTED_TRADE_ATTEMPTS
        attempts[trade.external_id] < UNCONVERTED_TRADE_ATTEMPTS
      end

      [ retried, attempts ]
    end

    def log_abandoned_trade(trade, attempts)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "#{self.class::SOURCE.capitalize} trade not imported after #{attempts} syncs: #{trade.reason}",
        source: self.class.name,
        provider_key: self.class::SOURCE,
        family: account.family,
        account: account,
        metadata: {
          external_id: trade.external_id,
          reason: trade.reason,
          symbol: trade.symbol,
          occurred_at: Time.zone.at(trade.time_ms / 1000).iso8601,
          attempts: attempts
        }
      )
    end

    # Stores the trade cursor beside the failed-sync counts it was held for.
    def store_trade_cursor(provider_account, key, value, attempts)
      payload = provider_account.raw_transactions_payload.to_h.merge(key => value, "fetched_at" => Time.current.iso8601)
      attempts.any? ? payload[UNCONVERTED_TRADES_KEY] = attempts : payload.delete(UNCONVERTED_TRADES_KEY)
      provider_account.update!(raw_transactions_payload: payload)
    end

    # Yields [from_ms, to_ms] spans no longer than `span_ms`, oldest first.
    def each_transfer_window(from_ms, to_ms, span_ms)
      cursor = from_ms
      while cursor <= to_ms
        window_end = [ cursor + span_ms - 1, to_ms ].min
        yield cursor, window_end
        cursor = window_end + 1
      end
    end

    # Where to resume reading deposits and withdrawals: just before the end of the
    # last scan, else the configured start date, else a default lookback.
    def transfer_scan_start_ms(last_scan_end_ms, configured_start, lookback:, retention_ms:, now_ms:)
      start_ms = if last_scan_end_ms
        last_scan_end_ms - TRANSFER_RESCAN_MS
      elsif configured_start
        configured_start.to_time.to_i * 1000
      else
        (Time.current - lookback).to_i * 1000
      end

      note_history_gap(start_ms, now_ms - retention_ms + 60_000, "deposits and withdrawals")
      [ start_ms, now_ms - retention_ms + 60_000 ].max
    end

    # The exchange no longer serves what the next read needs: a sync left too
    # long, or a start date set further back than it keeps. Whatever fell
    # outside is gone for good, so say so where support can find it.
    def note_history_gap(wanted_ms, available_from_ms, what)
      return if wanted_ms >= available_from_ms - GAP_TOLERANCE_MS

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "#{self.class::SOURCE.capitalize} history gap: #{what} before #{Time.zone.at(available_from_ms / 1000).to_date} cannot be imported",
        source: self.class.name,
        provider_key: self.class::SOURCE,
        family: account.family,
        metadata: { wanted_from: Time.zone.at(wanted_ms / 1000).iso8601, available_from: Time.zone.at(available_from_ms / 1000).iso8601 }
      )
    end

    # Writes one deposit (positive quantity) or withdrawal (negative). Returns
    # true when a new entry was created.
    def record_movement(external_id:, symbol:, quantity:, time_ms:, tx_hash:, network:, address:, provider_meta:, reference: nil)
      return false if quantity.zero? || time_ms.blank? || account.entries.exists?(source: self.class::SOURCE, external_id: external_id)

      security = resolve_movement_security(symbol)
      return false unless security

      time_ms = movement_time_ms(time_ms)
      date = Time.zone.at(time_ms / 1000).to_date
      price = quote_to_usd(1.to_d, symbol.to_s.upcase, date: date)
      deposit = quantity.positive?

      meta = {
        "direction" => deposit ? "in" : "out",
        "tx_hash" => CryptoTransfer::TxHash.normalize(tx_hash),
        "network" => network.presence,
        "address" => address.presence,
        "reference" => reference.presence,
        "occurred_at" => Time.zone.at(time_ms / 1000).iso8601
      }.compact

      extra = { self.class::SOURCE => provider_meta.compact, "crypto_transfer" => meta }
      if price.nil?
        extra[self.class::SOURCE]["price_missing"] = true
        extra[self.class::SOURCE]["symbol"] = symbol.to_s.upcase
      end

      account.entries.create!(
        date: date,
        name: "#{deposit ? "Deposit" : "Withdrawal"} #{quantity.abs.round(8).to_s("F")} #{symbol.to_s.upcase}",
        amount: 0,
        currency: "USD",
        external_id: external_id,
        source: self.class::SOURCE,
        entryable: Trade.new(
          security: security,
          qty: quantity,
          price: price || 0,
          currency: "USD",
          investment_activity_label: Trade::TRANSFER_LABEL,
          extra: extra
        )
      )

      true
    end

    # Deposit and withdrawal history needs permissions a key may lack, and a
    # failure there must not cost the balances and trades already read. Leaves
    # a trace support can find and returns false.
    def importing_movements(description)
      yield
      true
    rescue self.class::PROVIDER_ERROR => e
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "#{self.class::SOURCE.capitalize} #{description} not imported",
        source: self.class.name,
        provider_key: self.class::SOURCE,
        family: account.family,
        metadata: { error_class: e.class.name, error: e.message }
      )
      false
    end

    # The security for a bare coin symbol; a processor whose resolver takes
    # something else overrides this.
    def resolve_movement_security(symbol)
      self.class::SECURITY_RESOLVER.resolve(symbol)
    end

    # A deposit or withdrawal written while no price could be found (a rate
    # limit, a feed outage) is priced again on later syncs, oldest first, up to
    # UNCONVERTED_TRADE_ATTEMPTS times. Its quantity is already right; only the
    # price behind its cost basis was missing.
    def reprice_missing_movements
      source = self.class::SOURCE

      account.entries
        .where(source: source, entryable_type: "Trade")
        .joins("JOIN trades ON trades.id = entries.entryable_id")
        .where("trades.extra -> ? ->> 'price_missing' = 'true'", source)
        .where("COALESCE((trades.extra -> ? ->> 'price_attempts')::int, 0) < ?", source, UNCONVERTED_TRADE_ATTEMPTS)
        .order(:date)
        .limit(REPRICE_BATCH)
        .preload(entryable: :security)
        .each { |entry| reprice_movement(entry.entryable, entry.date) }
    end

    def reprice_movement(trade, date)
      source = self.class::SOURCE
      meta = trade.extra[source].to_h
      symbol = meta["symbol"].presence || trade.security.ticker.to_s.delete_prefix(CryptoAsset::TICKER_PREFIX)
      price = quote_to_usd(1.to_d, symbol.upcase, date: date)

      if price
        trade.update!(price: price, extra: trade.extra.merge(source => meta.except("price_missing", "price_attempts")))
      else
        trade.update!(extra: trade.extra.merge(source => meta.merge("price_attempts" => meta["price_attempts"].to_i + 1)))
      end
    end

    # Exchanges give times as epoch milliseconds, as a string of them, or as a
    # UTC "YYYY-MM-DD HH:MM:SS" string.
    def movement_time_ms(value)
      return value.to_i if value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)

      Time.find_zone!("UTC").parse(value.to_s).to_i * 1000
    end

    # Keeps whatever else the provider account caches in raw_transactions_payload
    # (the trade cursor) and sets the movement cursor beside it.
    def store_movement_cursor(provider_account, key, value)
      payload = provider_account.raw_transactions_payload.to_h
      provider_account.update!(raw_transactions_payload: payload.merge(key => value, "fetched_at" => Time.current.iso8601))
    end
end
