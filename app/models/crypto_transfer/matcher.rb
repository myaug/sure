# frozen_string_literal: true

# Pairs the crypto withdrawals and deposits of a family's accounts into
# CryptoTransferLinks.
#
# Evidence, strongest first:
#   1. the same blockchain transaction hash on both legs (confirmed);
#   2. the same exchange reference, e.g. an internal transfer's withdrawal id
#      (confirmed);
#   3. the same asset, a received quantity just under the sent one (a network fee
#      came out), within a day, with exactly one candidate on each side
#      (pending: the owner decides).
#
# A pair is never linked when the legs name different networks, or when both
# carry a transaction hash and the hashes differ -- that is two transactions.
# Legs already in a live link, and pairs once rejected, are left alone.
class CryptoTransfer::Matcher
  # A fee takes part of what was sent. A received quantity below this share of the
  # sent one is more likely two unrelated movements.
  MIN_RECEIVED_SHARE = 0.9.to_d
  DATE_WINDOW = 1.day

  Leg = Struct.new(:entry, :trade, :security_id, :quantity, :date, :tx_hash, :reference, :network, keyword_init: true) do
    def account_id = entry.account_id
  end

  def initialize(family)
    @family = family
  end

  # @return [Integer] how many links were created
  def call
    outflows, inflows = legs.partition { |leg| leg.trade.qty.negative? }
    return 0 if outflows.empty? || inflows.empty?

    created = 0
    taken = Set.new

    [ [ :tx_hash, :confirmed ], [ :reference, :confirmed ] ].each do |key, status|
      pair_by_key(outflows, inflows, key, taken).each do |out_leg, in_leg|
        created += create_link(out_leg, in_leg, key.to_s, status, taken)
      end
    end

    pair_by_amount_and_date(outflows, inflows, taken).each do |out_leg, in_leg|
      created += create_link(out_leg, in_leg, "amount_time", :pending, taken)
    end

    created
  end

  private
    attr_reader :family

    # Transfer-labelled trades in the family's live accounts that no live link
    # covers yet.
    def legs
      @legs ||= begin
        linked_ids = CryptoTransferLink.live.where(family_id: family.id).pluck(:outflow_entry_id, :inflow_entry_id).flatten.to_set

        Entry
          .joins(:account)
          .where(accounts: { family_id: family.id, status: %w[draft active] })
          .where(entryable_type: "Trade")
          .where("entries.excluded IS NOT TRUE")
          .joins("JOIN trades ON trades.id = entries.entryable_id")
          .where(trades: { investment_activity_label: Trade::TRANSFER_LABEL })
          .preload(:account, :entryable)
          .reject { |entry| linked_ids.include?(entry.id) }
          .filter_map { |entry| build_leg(entry) }
      end
    end

    def build_leg(entry)
      trade = entry.entryable
      return nil if trade.qty.zero?

      meta = trade.extra.to_h["crypto_transfer"].to_h
      Leg.new(
        entry: entry,
        trade: trade,
        security_id: trade.security_id,
        quantity: trade.qty.abs,
        date: entry.date,
        tx_hash: CryptoTransfer::TxHash.for_entry(entry, trade),
        reference: meta["reference"].presence,
        network: CryptoTransfer::Network.normalize(meta["network"])
      )
    end

    # Legs sharing a key value and an asset, paired one to one by how close the
    # received quantity is to the sent one.
    def pair_by_key(outflows, inflows, key, taken)
      in_by_key = inflows.reject { |leg| leg[key].nil? }.group_by { |leg| [ leg.security_id, leg[key] ] }

      outflows.reject { |leg| leg[key].nil? }.group_by { |leg| [ leg.security_id, leg[key] ] }.flat_map do |group_key, outs|
        ins = in_by_key[group_key].to_a
        pairs = []

        outs.sort_by { |leg| -leg.quantity }.each do |out_leg|
          candidate = ins
            .reject { |leg| taken.include?(leg.entry.id) || leg.account_id == out_leg.account_id }
            .select { |leg| compatible?(out_leg, leg, key) }
            .min_by { |leg| (out_leg.quantity - leg.quantity).abs }
          next unless candidate

          pairs << [ out_leg, candidate ]
          ins -= [ candidate ]
        end

        pairs
      end
    end

    # Pairs with one candidate on each side only: two similar withdrawals and one
    # deposit is a question the owner has to answer, not a guess to make.
    def pair_by_amount_and_date(outflows, inflows, taken)
      free_outs = outflows.reject { |leg| taken.include?(leg.entry.id) }
      free_ins = inflows.reject { |leg| taken.include?(leg.entry.id) }

      candidates = free_outs.to_h { |out_leg| [ out_leg, free_ins.select { |in_leg| plausible?(out_leg, in_leg) } ] }
      reverse = free_ins.to_h { |in_leg| [ in_leg, candidates.select { |_, ins| ins.include?(in_leg) }.keys ] }

      candidates.filter_map do |out_leg, ins|
        next unless ins.one?

        in_leg = ins.first
        [ out_leg, in_leg ] if reverse[in_leg].one?
      end
    end

    def plausible?(out_leg, in_leg)
      return false unless out_leg.security_id == in_leg.security_id
      return false if out_leg.account_id == in_leg.account_id
      return false unless compatible?(out_leg, in_leg, :amount_time)
      return false unless in_leg.quantity <= out_leg.quantity && in_leg.quantity >= out_leg.quantity * MIN_RECEIVED_SHARE
      return false if rejected_pair?(out_leg, in_leg)

      (in_leg.date - out_leg.date).abs <= DATE_WINDOW.in_days
    end

    # Two movements that cannot be one: different networks, or two transaction
    # hashes that do not match.
    def compatible?(out_leg, in_leg, _basis)
      return false if out_leg.network && in_leg.network && out_leg.network != in_leg.network
      return false if out_leg.tx_hash && in_leg.tx_hash && out_leg.tx_hash != in_leg.tx_hash
      return false if rejected_pair?(out_leg, in_leg)

      true
    end

    def rejected_pair?(out_leg, in_leg)
      rejected_pairs.include?([ out_leg.entry.id, in_leg.entry.id ])
    end

    def rejected_pairs
      @rejected_pairs ||= CryptoTransferLink.rejected.where(family_id: family.id).pluck(:outflow_entry_id, :inflow_entry_id).to_set
    end

    def create_link(out_leg, in_leg, basis, status, taken)
      return 0 if taken.include?(out_leg.entry.id) || taken.include?(in_leg.entry.id)

      CryptoTransferLink.transaction(requires_new: true) do
        CryptoTransferLink.create!(
          family: family, outflow_entry: out_leg.entry, inflow_entry: in_leg.entry, basis: basis, status: status
        )
      end
      taken << out_leg.entry.id << in_leg.entry.id
      1
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # Another sync paired one of the legs first, or the pair is no longer one
      # movement; either way nothing to do for this pair now.
      Rails.logger.info "CryptoTransfer::Matcher - skipped a pair for family #{family.id}: #{e.class}"
      0
    end
end
