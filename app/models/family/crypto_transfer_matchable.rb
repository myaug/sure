# frozen_string_literal: true

module Family::CryptoTransferMatchable
  extend ActiveSupport::Concern

  included do
    has_many :crypto_transfer_links, dependent: :destroy
  end

  # Pairs crypto withdrawals with deposits across the family's accounts. Runs
  # after every sync with auto-matching, and never fails the sync: a matching
  # problem leaves unmatched movements, which is where they started.
  def match_crypto_transfers!
    CryptoTransfer::Matcher.new(self).call
  rescue StandardError => e
    DebugLogEntry.capture(
      category: "provider_sync",
      level: "error",
      message: "Crypto transfer matching failed",
      source: self.class.name,
      provider_key: "crypto_transfer",
      family: self,
      metadata: { error_class: e.class.name, error: e.message }
    )
    0
  end
end
