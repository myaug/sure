# frozen_string_literal: true

# Keeps CoinStats usage inside the plan's monthly credits.
#
# Credits are the limit that matters: the free plan has 20,000 a month, a single
# exchange sync costs on the order of a hundred, and DeFi positions cost 400 per
# wallet. Synced hourly that is far more than the plan holds, so syncing is
# paced against the share of the month that has passed, and the calls that cost
# most are skipped once the remainder gets thin.
#
# The balance comes from the free /usage/credits endpoint. If it cannot be read,
# or its figures cannot be made out, nothing is held back: running into the
# provider's own 406 is better than refusing to sync on a guess.
#
# Assumes credits reset at the start of the calendar month.
class CoinstatsItem::CreditBudget
  # What the expensive calls cost, from CoinStats' published ranges (rate-limits
  # page): wallet operations 40-50, portfolio 8-10, DeFi 400.
  WALLET_BALANCES_COST = 50
  WALLET_TRANSACTIONS_COST = 50
  DEFI_COST_PER_WALLET = 400

  # Held back so the cheap calls that keep an account usable still work.
  RESERVE_RATIO = 0.05
  MIN_RESERVE = 200

  CACHE_TTL = 5.minutes

  def initialize(coinstats_item, provider: coinstats_item.coinstats_provider, now: Time.current)
    @coinstats_item = coinstats_item
    @provider = provider
    @now = now
  end

  # { total:, remaining: } as numbers, or nil when unknown.
  def snapshot
    return @snapshot if defined?(@snapshot)

    @snapshot = fetch_snapshot
  end

  def remaining
    snapshot&.fetch(:remaining)
  end

  # Too few credits left to do anything but the cheapest calls.
  def exhausted?
    snapshot.nil? ? false : snapshot[:remaining] <= reserve
  end

  def can_afford?(credits)
    snapshot.nil? ? true : snapshot[:remaining] - reserve >= credits
  end

  # An extra, scheduled sync is worth its credits only while usage is on pace
  # with the month: no more of the plan used than of the month gone.
  def on_pace?
    return true if snapshot.nil? || snapshot[:total].to_d.zero?

    snapshot[:remaining].to_d / snapshot[:total] >= month_left_fraction
  end

  def hourly_sync_allowed?
    !exhausted? && on_pace?
  end

  private

    attr_reader :coinstats_item, :provider, :now

    def reserve
      [ snapshot[:total].to_d * RESERVE_RATIO, MIN_RESERVE ].max
    end

    def month_left_fraction
      month_start = now.beginning_of_month
      month_end = now.end_of_month
      (month_end - now).to_f / (month_end - month_start)
    end

    def fetch_snapshot
      Rails.cache.fetch("coinstats_credits/#{coinstats_item.id}", expires_in: CACHE_TTL, skip_nil: true) do
        read_snapshot
      end
    end

    def read_snapshot
      return nil unless provider

      response = provider.get_credits
      return nil unless response.success?

      data = response.data
      return nil unless data[:total].present? && data[:remaining].present?

      { total: data[:total].to_d, remaining: data[:remaining].to_d }
    rescue StandardError => e
      Rails.logger.warn "CoinstatsItem::CreditBudget #{coinstats_item.id} - could not read credits: #{e.message}"
      nil
    end
end
