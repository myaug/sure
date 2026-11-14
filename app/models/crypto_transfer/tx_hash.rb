# frozen_string_literal: true

# Reads a blockchain transaction hash out of the strings providers keep it in,
# in one canonical form, so two accounts that saw the same transaction agree.
#
# Exchanges write "0x..." for EVM chains, bare hex for Bitcoin and TRON, and
# base58 signatures for Solana; on-chain movements carry a hash inside a longer
# external id ("<hash>_<contract>"). Anything else yields nil, which makes the
# movement unmatchable by hash rather than wrongly matched.
module CryptoTransfer::TxHash
  HEX = /(?<![0-9a-zA-Z])(?:0x)?([0-9a-fA-F]{64})(?![0-9a-zA-Z])/
  SOLANA = /(?<![1-9A-HJ-NP-Za-km-z])([1-9A-HJ-NP-Za-km-z]{85,90})(?![1-9A-HJ-NP-Za-km-z])/

  # The prefix OnchainWalletAccount::Processor gives its trades' external ids.
  ONCHAIN_PREFIX = /\Aonchain_[0-9a-f-]{36}_/

  class << self
    def normalize(raw)
      value = raw.to_s.strip
      return nil if value.blank?

      if (hex = value.match(HEX))
        hex[1].downcase
      elsif (signature = value.match(SOLANA))
        signature[1]
      end
    end

    # The hash a Transfer-labelled trade entry was recorded with: the one its
    # provider stored, or for an on-chain wallet the one inside its external id.
    def for_entry(entry, trade)
      stored = trade.extra.to_h.dig("crypto_transfer", "tx_hash")
      return normalize(stored) if stored.present?

      return nil unless entry.source == "onchain_wallet" && entry.external_id.present?

      normalize(entry.external_id.sub(ONCHAIN_PREFIX, ""))
    end
  end
end
