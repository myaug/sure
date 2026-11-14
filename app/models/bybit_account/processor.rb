# frozen_string_literal: true

# Updates the account balance and imports spot executions as trades.
class BybitAccount::Processor
  include BybitAccount::UsdConverter
  include CryptoTransfer::ExchangeMovements

  SOURCE = "bybit"
  SECURITY_RESOLVER = BybitAccount::SecurityResolver
  PROVIDER_ERROR = Provider::Bybit::Error

  # Quote currencies a spot symbol can end in, longest first so USDT is not read
  # as USD. Fiat quotes are converted through the app's exchange rates.
  QUOTE_CURRENCIES = %w[USDT USDC USDE EUR BRL TRY BTC ETH DAI USD].freeze

  # Without a configured start date, history begins this far back.
  DEFAULT_LOOKBACK = 30.days

  attr_reader :bybit_account

  def initialize(bybit_account)
    @bybit_account = bybit_account
  end

  def process
    unless bybit_account.current_account.present?
      Rails.logger.info "BybitAccount::Processor - no linked account for #{bybit_account.id}, skipping"
      return
    end

    begin
      BybitAccount::HoldingsProcessor.new(bybit_account).process
    rescue StandardError => e
      Rails.logger.error "BybitAccount::Processor - holdings failed for #{bybit_account.id}: #{e.message}"
    end

    process_account!
    fetch_and_process_trades
    fetch_and_process_transfers
    fetch_and_process_internal_deposits

    # The account was anchored before this history existed; the anchor has to precede it.
    bybit_account.current_account.ensure_opening_anchor_precedes_entries
  end

  private

    def target_currency
      bybit_account.bybit_item.family.currency
    end

    def provider
      @provider ||= bybit_account.bybit_item&.bybit_provider
    end

    def process_account!
      raw_usd = (bybit_account.current_balance || 0).to_d
      amount, stale, rate_date = convert_from_usd(raw_usd, date: Date.current)

      bybit_account.current_account.update!(balance: amount, cash_balance: 0, currency: target_currency)
      bybit_account.update!(extra: bybit_account.extra.to_h.deep_merge(build_stale_extra(stale, rate_date, Date.current)))
    rescue StandardError => e
      Rails.logger.error "BybitAccount::Processor - account update failed for #{bybit_account.id}: #{e.message}"
      raise
    end

    def fetch_and_process_trades
      return unless provider

      now_ms = Time.current.to_i * 1000
      executions = fetch_executions(from_ms: history_start_ms(now_ms), to_ms: now_ms)

      # Entries first: if this raises, the cursor below is not advanced and the
      # next sync retries the same range.
      unconverted = executions.filter_map { |execution| process_execution(execution) }
      retried, attempts = retry_unconverted_trades(bybit_account, unconverted)

      newest = executions.filter_map { |execution| execution["execTime"].to_i.presence }.max
      cursor = retried.map(&:time_ms).min || [ newest, last_exec_time ].compact.max || now_ms
      store_trade_cursor(bybit_account, "last_exec_time", cursor, attempts)
    end

    def account
      bybit_account.current_account
    end

    # Deposits and withdrawals: Transfer-labelled trades that CryptoTransfer::Matcher
    # can pair with the other side. Read after the trades and never fatal to them.
    def fetch_and_process_transfers
      return unless provider

      importing_movements("deposits and withdrawals") do
        now_ms = Time.current.to_i * 1000
        from_ms = transfer_scan_start_ms(
          bybit_account.raw_transactions_payload.to_h["last_transfer_scan"]&.to_i,
          bybit_account.bybit_item.sync_start_date,
          lookback: DEFAULT_LOOKBACK, retention_ms: Provider::Bybit::RECORD_HISTORY_MS, now_ms: now_ms
        )

        deposits = []
        withdrawals = []
        each_transfer_window(from_ms, now_ms, Provider::Bybit::RECORD_WINDOW_MS) do |window_start, window_end|
          deposits.concat(provider.get_deposit_records(start_time: window_start, end_time: window_end))
          withdrawals.concat(provider.get_withdraw_records(start_time: window_start, end_time: window_end))
        end

        deposits.each { |deposit| record_deposit(deposit) }
        withdrawals.each { |withdrawal| record_withdrawal(withdrawal) }

        store_movement_cursor(bybit_account, "last_transfer_scan", now_ms)
        reprice_missing_movements
      end
    end

    # Deposits from another Bybit user, such as the owner's other account. Kept
    # apart from the on-chain scan, with its own cursor, so a key that cannot
    # read them still imports everything else.
    def fetch_and_process_internal_deposits
      return unless provider

      importing_movements("internal deposits") do
        now_ms = Time.current.to_i * 1000
        from_ms = transfer_scan_start_ms(
          bybit_account.raw_transactions_payload.to_h["last_internal_deposit_scan"]&.to_i,
          bybit_account.bybit_item.sync_start_date,
          lookback: DEFAULT_LOOKBACK, retention_ms: Provider::Bybit::RECORD_HISTORY_MS, now_ms: now_ms
        )

        deposits = []
        each_transfer_window(from_ms, now_ms, Provider::Bybit::RECORD_WINDOW_MS) do |window_start, window_end|
          deposits.concat(provider.get_internal_deposit_records(start_time: window_start, end_time: window_end))
        end

        deposits.each { |deposit| record_internal_deposit(deposit) }
        store_movement_cursor(bybit_account, "last_internal_deposit_scan", now_ms)
      end
    end

    # status 2 is credited. The transfer never touches a chain, so it carries
    # Bybit's own txID instead of a hash. When the sender's off-chain withdrawal
    # shows the same txID the two pair by reference; otherwise the matcher falls
    # back to amount and time.
    def record_internal_deposit(deposit)
      return unless deposit["status"].to_i == 2

      record_movement(
        external_id: "bybit_internal_deposit_#{deposit["id"].presence || deposit["txID"]}",
        symbol: deposit["coin"],
        quantity: deposit["amount"].to_d,
        time_ms: epoch_ms(deposit["createdTime"]),
        tx_hash: nil,
        network: nil,
        address: deposit["address"],
        reference: internal_reference(deposit["txID"]),
        provider_meta: { "type" => "internal_deposit", "id" => deposit["id"], "tx_id" => deposit["txID"], "from_member_id" => deposit["fromMemberId"] }
      )
    end

    # Bybit's own id for a transfer between two Bybit users, shared by both sides.
    def internal_reference(tx_id)
      tx_id.presence && "bybit:internal:#{tx_id}"
    end

    # Internal deposit times come in seconds, everything else in milliseconds.
    def epoch_ms(value)
      return if value.blank?

      value.to_i < 100_000_000_000 ? value.to_i * 1000 : value.to_i
    end

    # status 3 is a successful deposit; the others are still in flight or failed.
    def record_deposit(deposit)
      return unless deposit["status"].to_i == 3

      record_movement(
        external_id: "bybit_deposit_#{deposit["id"].presence || deposit["txID"]}",
        symbol: deposit["coin"],
        quantity: deposit["amount"].to_d,
        time_ms: deposit["successAt"],
        tx_hash: deposit["txID"],
        network: deposit["chain"],
        address: deposit["toAddress"],
        provider_meta: { "type" => "deposit", "id" => deposit["id"], "chain" => deposit["chain"], "tx_id" => deposit["txID"], "from_address" => deposit["fromAddress"] }
      )
    end

    # What leaves the balance is the amount plus the withdrawal fee, so the
    # quantity is both; the network then delivers the amount. An off-chain one
    # (withdrawType 1) goes to another Bybit user and has no chain or hash.
    def record_withdrawal(withdrawal)
      return unless withdrawal["status"].to_s.casecmp?("success")

      off_chain = withdrawal["withdrawType"].to_i == 1

      record_movement(
        external_id: "bybit_withdraw_#{withdrawal["withdrawId"]}",
        symbol: withdrawal["coin"],
        quantity: -(withdrawal["amount"].to_d + withdrawal["withdrawFee"].to_d),
        time_ms: withdrawal["updateTime"].presence || withdrawal["createTime"],
        tx_hash: off_chain ? nil : withdrawal["txID"],
        network: off_chain ? nil : withdrawal["chain"],
        address: withdrawal["toAddress"],
        reference: (internal_reference(withdrawal["txID"]) if off_chain),
        provider_meta: { "type" => "withdrawal", "id" => withdrawal["withdrawId"], "chain" => withdrawal["chain"], "tx_id" => withdrawal["txID"], "fee" => withdrawal["withdrawFee"], "off_chain" => (true if off_chain) }
      )
    end

    def last_exec_time
      bybit_account.raw_transactions_payload&.dig("last_exec_time")&.to_i
    end

    # Resume from the newest execution seen (re-reading it is harmless, entries
    # are deduplicated by execution id), else from the configured start date.
    # Bybit only keeps two years of spot history.
    def history_start_ms(now_ms)
      configured_start = bybit_account.bybit_item.sync_start_date
      start_ms = last_exec_time ||
        (configured_start ? configured_start.to_time.to_i * 1000 : (Time.current - DEFAULT_LOOKBACK).to_i * 1000)

      note_history_gap(start_ms, now_ms - Provider::Bybit::EXECUTION_HISTORY_MS + 60_000, "trades")
      [ start_ms, now_ms - Provider::Bybit::EXECUTION_HISTORY_MS + 60_000 ].max
    end

    def fetch_executions(from_ms:, to_ms:)
      executions = []
      cursor = from_ms

      while cursor <= to_ms
        window_end = [ cursor + Provider::Bybit::EXECUTION_WINDOW_MS - 1, to_ms ].min
        executions.concat(provider.get_spot_executions(start_time: cursor, end_time: window_end))
        cursor = window_end + 1
      end

      executions
    end

    # Returns an UnconvertedTrade when the execution could not be imported yet,
    # else nil.
    def process_execution(execution)
      account = bybit_account.current_account
      return unless account

      external_id = "bybit_spot_#{execution["execId"]}"
      return if execution["execId"].blank? || account.entries.exists?(external_id: external_id)

      qty = execution["execQty"].to_d
      return if qty.zero?

      time_ms = execution["execTime"].to_i
      base, quote = split_symbol(execution["symbol"])
      return unconverted_trade(external_id, time_ms: time_ms, reason: "unknown_pair", symbol: execution["symbol"]) if base.blank?
      return if CryptoAsset.usd_stablecoin?(base)

      security = BybitAccount::SecurityResolver.resolve(base)
      return unconverted_trade(external_id, time_ms: time_ms, reason: "no_security", symbol: execution["symbol"]) unless security

      date = Time.zone.at(time_ms / 1000).to_date
      amount_usd = quote_to_usd(execution["execValue"].to_d, quote, date: date)
      price_usd = quote_to_usd(execution["execPrice"].to_d, quote, date: date)

      if amount_usd.nil? || price_usd.nil?
        Rails.logger.warn "BybitAccount::Processor - holding execution #{execution["execId"]}: could not convert #{quote} to USD"
        return unconverted_trade(external_id, time_ms: time_ms, reason: "no_usd_price", symbol: execution["symbol"])
      end

      fee = fee_in_usd(execution, base, price_usd, date: date)
      buy = execution["side"].to_s.casecmp?("Buy")
      amount_usd = amount_usd.round(2)

      account.entries.create!(
        date: date,
        name: "#{buy ? "Buy" : "Sell"} #{qty.round(8)} #{base}",
        amount: buy ? -amount_usd : amount_usd,
        currency: "USD",
        external_id: external_id,
        source: "bybit",
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
      Rails.logger.error "BybitAccount::Processor - failed to process execution #{execution["execId"]}: #{e.message}"
      raise
    end

    def split_symbol(symbol)
      quote = QUOTE_CURRENCIES.find { |candidate| symbol.to_s.end_with?(candidate) && symbol.to_s.length > candidate.length }
      return [ nil, nil ] unless quote

      [ symbol.to_s.delete_suffix(quote), quote ]
    end

    # Stablecoins and USD are 1:1; crypto quotes use Bybit's daily close; fiat
    # quotes fall back to the app's exchange rates. nil when nothing can price it.
    def quote_to_usd(amount, quote, date:)
      return amount if CryptoAsset.usd_stablecoin?(quote) || quote == "USD"

      spot = provider&.get_historical_price("#{quote}USDT", date) || provider&.get_spot_price("#{quote}USDT")
      return (amount * spot.to_d).round(8) if spot.present?

      rate = ExchangeRate.find_or_fetch_rate(from: quote, to: "USD", date: date, cache: true)
      rate.present? ? (amount * rate.rate.to_d).round(8) : nil
    rescue StandardError => e
      Rails.logger.warn "BybitAccount::Processor - could not convert #{quote} to USD: #{e.message}"
      nil
    end

    # Spot fees are charged in the received asset: the base on a buy, the quote
    # on a sell. Anything else is priced through Bybit, and 0 when it cannot be.
    def fee_in_usd(execution, base, price_usd, date:)
      fee = execution["execFee"].to_d.abs
      currency = execution["feeCurrency"].to_s.upcase
      return 0 if fee.zero? || currency.blank?
      return fee if CryptoAsset.usd_stablecoin?(currency) || currency == "USD"
      return (fee * price_usd).round(8) if currency == base

      quote_to_usd(fee, currency, date: date) || 0
    end
end
