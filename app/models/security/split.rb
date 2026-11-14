# A change in a security's share count that no trade made: a 2-for-1 split
# turns 10 shares into 20 on its ex-date, and a 1-for-10 reverse split turns
# 100 into 10. The money invested does not change, so cost per share moves by
# the inverse of the ratio.
#
# The holding calculators apply it at the open of the ex-date, before that
# day's trades (#249).
class Security::Split < ApplicationRecord
  belongs_to :security

  validates :ex_date, :source, presence: true
  # The terms are int4 columns: a larger one must fail validation, not raise
  # ActiveModel::RangeError on save.
  validates :numerator, :denominator,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 2_147_483_647 }
  validates :ex_date, uniqueness: { scope: :security_id }
  validate :changes_the_share_count

  # New shares per old, exact.
  def ratio
    Rational(numerator, denominator)
  end

  # The scale of the `qty` columns on `holdings` and `trades`. A quantity this
  # code hands around has to be one the database can hold: anything finer is a
  # number no position can actually be in.
  QTY_SCALE = 18

  # A share count after a split of `ratio`, and before it. Multiplying a
  # BigDecimal by a Rational rounds at 32 digits, so 3 shares through a
  # 1-for-3 split came out 0.999...; multiplying by the numerator and then
  # dividing by the denominator is exact whenever the answer is.
  #
  # When the answer doesn't terminate -- 10 shares through a 1-for-3 split is
  # 3.333... -- the result is rounded to the stored scale. Carrying the extra
  # digits instead left a position that had been sold in full holding about
  # 3e-31 of a share: the seller can only sell what the column can hold, so the
  # subtraction missed exact zero, the cost-basis tracker never reset, and an
  # inbound transfer's "cost unknown" mark survived a full liquidation.
  #
  # The cost of rounding here is that scaling and unscaling back can land one
  # unit in the last place away from where it started. That is the floor the
  # column imposes anyway.
  def self.scale(qty, ratio)
    (qty.to_d * ratio.numerator / ratio.denominator).round(QTY_SCALE)
  end

  def self.unscale(qty, ratio)
    (qty.to_d * ratio.denominator / ratio.numerator).round(QTY_SCALE)
  end

  SOURCE_MANUAL = "manual".freeze

  class << self
    # A stock dividend or bonus issue of `percent` new shares per 100 held
    # (cổ tức bằng cổ phiếu, cổ phiếu thưởng) is a split by (100 + percent) / 100:
    # the share count rises, nothing is paid, and cost per share falls by the
    # same factor. 20% is 6 new for 5 old.
    #
    # @return [Rational] new shares per old, or nil for a percentage that is not
    #   a positive number with at most 4 decimals
    def ratio_for_stock_dividend(percent)
      value = BigDecimal(percent.to_s, exception: false)
      return nil if value.nil? || !value.finite? || !value.positive? || value.round(4) != value

      Rational(((100 + value) * 10_000).to_i, 1_000_000)
    end
  end

  # Accounts whose holdings change when this split is added or removed: every
  # account with a trade or a holding in the security, whichever family owns it.
  # A security is shared, so its splits are too.
  def affected_accounts
    Account.where(id: Trade.joins(:entry).where(security_id: security_id).select("entries.account_id"))
      .or(Account.where(id: Holding.where(security_id: security_id).select(:account_id)))
  end

  private
    # A 1:1 "split" changes nothing, and the DB refuses it too. Reuses Rails'
    # own `other_than` message, so no new string is needed.
    def changes_the_share_count
      errors.add(:denominator, :other_than, count: numerator) if numerator.present? && numerator == denominator
    end
end
