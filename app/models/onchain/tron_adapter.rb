# frozen_string_literal: true

# TRON: TRX and TRC-20 tokens, notably USDT, the stablecoin most Vietnamese
# holders keep on this network.
#
# TronGrid's account summary reports every TRC-20 balance but no symbol or
# decimals, and TRON is full of airdropped lookalike tokens. A token is therefore
# only surfaced when its identity is known: shipped here, or reported in the
# address's own transfer history. A balance whose decimals we cannot vouch for
# would be scaled wrongly, so it is left out rather than guessed.
class Onchain::TronAdapter
  include Onchain::ChainAdapter

  SUN_PER_TRX = 1_000_000.to_d

  KNOWN_TOKENS = {
    "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" => { symbol: "USDT", name: "Tether USD", decimals: 6 },
    "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8" => { symbol: "USDC", name: "USD Coin", decimals: 6 }
  }.freeze

  def initialize(credentials: {})
    @credentials = credentials
  end

  def valid_address?(address)
    Onchain::TronAddress.valid?(address)
  end

  # One request. A never-activated address has no TRON account and answers
  # false; a source that fails answers nil, not false — see
  # Onchain::ChainAdapter#has_activity? on the third answer.
  def has_activity?(address)
    return false unless valid_address?(address)

    detection_provider.has_activity?(address)
  rescue StandardError => e
    Rails.logger.warn("Onchain::TronAdapter - activity probe failed: #{e.class}")
    nil
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid TRON address" unless valid_address?(address)

    wrap_provider_errors do
      balances = provider.trc20_balances(address)
      native = provider.native_balance(address)

      token_transfers = best_effort_movements { provider.trc20_transfers(address) }
      native_transfers = best_effort_movements { provider.native_transfers(address) }
      metadata = token_metadata(token_transfers || [])

      Onchain::Snapshot.new(
        assets: [ native_asset(native), *token_assets(balances, metadata) ],
        movements: build_movements(token_transfers, native_transfers),
        history_truncated: token_transfers.nil? || native_transfers.nil? || provider.truncated,
        assets_truncated: false
      )
    end
  end

  def provider_error_classes
    [ Provider::TronGrid::RateLimitError, Provider::TronGrid::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!(Onchain::Chains::TRON)
    end

    def provider
      @provider ||= Provider::TronGrid.new(max_pages: Onchain::HistoryBudget.pages)
    end

    # Detection asks every candidate chain in turn on the request thread, so it
    # reads with the detection budget rather than the sync's.
    def detection_provider
      @detection_provider ||= Provider::TronGrid.new(
        request_timeout: Onchain::DetectionBudget.timeout,
        max_retries: Onchain::DetectionBudget.retries
      )
    end

    def native_asset(sun)
      definition.native_asset(quantity: sun.to_d / SUN_PER_TRX)
    end

    # Shipped tokens win over anything a transfer claims, so a lookalike cannot
    # rename USDT.
    def token_metadata(transfers)
      from_history = transfers.each_with_object({}) do |transfer, found|
        found[transfer[:contract]] ||= transfer.slice(:symbol, :name, :decimals)
      end

      from_history.merge(KNOWN_TOKENS)
    end

    def token_assets(balances, metadata)
      balances.filter_map do |balance|
        info = metadata[balance[:contract]]
        next if info.nil? || info[:symbol].blank?

        quantity = balance[:raw_amount].to_d / (10.to_d**info[:decimals].to_i)
        next unless quantity.positive?

        definition.token_asset(
          symbol: info[:symbol],
          name: info[:name].presence || info[:symbol],
          decimals: info[:decimals].to_i,
          quantity: quantity,
          contract: balance[:contract],
          notable: KNOWN_TOKENS.key?(balance[:contract])
        )
      end
    end

    def build_movements(token_transfers, native_transfers)
      tokens = Array(token_transfers).filter_map do |transfer|
        next if transfer[:timestamp].blank?

        info = KNOWN_TOKENS[transfer[:contract]] || transfer
        amount = transfer[:raw_amount].to_d / (10.to_d**info[:decimals].to_i)
        next if amount.zero?

        Onchain::Movement.new(
          external_id: "#{transfer[:external_id]}_#{transfer[:contract]}",
          symbol: info[:symbol],
          contract: transfer[:contract],
          amount: amount,
          timestamp: transfer[:timestamp]
        )
      end

      natives = Array(native_transfers).filter_map do |transfer|
        next if transfer[:timestamp].blank?

        Onchain::Movement.new(
          external_id: transfer[:external_id],
          symbol: definition.native.symbol,
          contract: nil,
          amount: transfer[:raw_amount].to_d / SUN_PER_TRX,
          timestamp: transfer[:timestamp]
        )
      end

      tokens + natives
    end
end
