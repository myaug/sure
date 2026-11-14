# frozen_string_literal: true

# Says that a crypto withdrawal in one account and a deposit in another are the
# same coins moving between two places the family owns.
#
# Crypto moves between accounts as a pair of Transfer-labelled Trades, which a
# Transfer cannot represent: it joins two cash Transactions. A link joins the two
# Trade entries instead, so a movement that is confirmed to stay inside the
# family is read as internal (Portfolio::FlowClassifier), whatever fee the
# network took out of the quantity in between.
#
# Links are created by CryptoTransfer::Matcher. One found by transaction hash is
# confirmed on the spot; one guessed from quantity and date waits as pending
# until its owner confirms or rejects it. A rejected link stays on record so the
# pair is not suggested again.
class CryptoTransferLink < ApplicationRecord
  enum :status, { pending: "pending", confirmed: "confirmed", rejected: "rejected" }

  # How the two legs were paired, strongest first.
  BASES = %w[tx_hash reference amount_time].freeze

  belongs_to :family
  belongs_to :outflow_entry, class_name: "Entry"
  belongs_to :inflow_entry, class_name: "Entry"

  validates :basis, inclusion: { in: BASES }
  validate :legs_are_one_movement

  scope :live, -> { where.not(status: "rejected") }
  scope :involving, ->(entry_id) { where(outflow_entry_id: entry_id).or(where(inflow_entry_id: entry_id)) }

  def confirm!
    update!(status: "confirmed")
  end

  def reject!
    update!(status: "rejected")
  end

  def counterpart_of(entry)
    entry.id == outflow_entry_id ? inflow_entry : outflow_entry
  end

  def accounts
    [ outflow_entry&.account, inflow_entry&.account ].compact
  end

  private
    def legs_are_one_movement
      out_trade = outflow_entry&.entryable
      in_trade = inflow_entry&.entryable
      return errors.add(:base, :not_trades) unless out_trade.is_a?(Trade) && in_trade.is_a?(Trade)

      errors.add(:base, :not_transfers) unless [ out_trade, in_trade ].all? { |trade| trade.investment_activity_label == Trade::TRANSFER_LABEL }
      errors.add(:base, :wrong_direction) unless out_trade.qty.negative? && in_trade.qty.positive?
      errors.add(:base, :different_securities) unless out_trade.security_id == in_trade.security_id
      errors.add(:base, :same_account) if outflow_entry.account_id == inflow_entry.account_id
      errors.add(:base, :different_families) unless [ outflow_entry.account.family_id, inflow_entry.account.family_id ].all? { |id| id == family_id }
    end
end
