# frozen_string_literal: true

# A coarse, provider-neutral name for the chain a movement travelled on, so two
# movements are only paired when they did not use different ones. Exchanges name
# the same chain "TRX", "TRC20" or "Tron"; unknown names stay nil, which never
# rules a pair out.
module CryptoTransfer::Network
  ALIASES = {
    "tron" => %w[trx trc20 tron],
    "ethereum" => %w[eth erc20 ethereum],
    "bsc" => %w[bsc bep20 bnb bnbsmartchain bnbsmartchainbep20 bnbchain],
    "solana" => %w[sol solana],
    "bitcoin" => %w[btc bitcoin],
    "polygon" => %w[matic polygon pol],
    "arbitrum" => %w[arb arbitrum arbitrumone arbone],
    "optimism" => %w[op optimism opmainnet],
    "base" => %w[base],
    "avalanche" => %w[avax avaxc avalanche cchain],
    "ton" => %w[ton toncoin]
  }.freeze

  LOOKUP = ALIASES.flat_map { |name, tokens| tokens.map { |token| [ token, name ] } }.to_h.freeze

  class << self
    # "USDT-TRC20" and "TRC20" and "Tron (TRC20)" all read as "tron".
    def normalize(raw)
      tokens = raw.to_s.downcase.split(/[^a-z0-9]+/).reject(&:empty?)
      return nil if tokens.empty?

      candidates = tokens + [ tokens.join ]
      candidates.each do |token|
        name = LOOKUP[token]
        return name if name
      end

      nil
    end
  end
end
