# frozen_string_literal: true

# Records a change in a security's share count that no trade made -- a share
# split, a reverse split, or a stock dividend / bonus issue -- so every position
# in it is restated from the ex-date.
#
# A security belongs to no family and its splits are read by every account
# holding it, so recording one is an instance-level action, not a family one.
class SecuritySplitsController < ApplicationController
  before_action :require_instance_manager!
  before_action :set_security

  def new
    @split = @security.splits.build(ex_date: Date.current)
    @kind = "stock_dividend"
  end

  def create
    @kind = params.dig(:security_split, :kind).to_s
    @split = @security.splits.build(split_attributes)

    if @split.errors.empty? && @split.save
      resync(@split)
      redirect_back_or_to portfolio_path, notice: t(".success", ticker: @security.ticker)
    else
      @split.errors.add(:base, t(".invalid_ratio")) if @split.errors.empty?
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    split = @security.splits.find(params[:id])
    accounts = split.affected_accounts.to_a
    split.destroy!
    accounts.each(&:sync_later)

    redirect_back_or_to portfolio_path, notice: t(".success", ticker: @security.ticker), status: :see_other
  end

  private
    def require_instance_manager!
      return if Current.user.manages_instance_settings?

      redirect_back_or_to root_path, alert: t("security_splits.not_allowed")
    end

    def set_security
      @security = Security.find(params[:security_id] || params.dig(:security_split, :security_id))
    end

    # The form offers a stock dividend as a percentage, the way brokers announce
    # it, or a split as new shares per old.
    def split_attributes
      attributes = { ex_date: params.dig(:security_split, :ex_date), source: Security::Split::SOURCE_MANUAL }

      if @kind == "stock_dividend"
        ratio = Security::Split.ratio_for_stock_dividend(params.dig(:security_split, :percent))
        attributes.merge(numerator: ratio&.numerator, denominator: ratio&.denominator)
      else
        attributes.merge(
          numerator: params.dig(:security_split, :numerator).to_s.to_i,
          denominator: params.dig(:security_split, :denominator).to_s.to_i
        )
      end
    end

    # Holdings and balances are rebuilt from trades on a sync.
    def resync(split)
      split.affected_accounts.find_each(&:sync_later)
    end
end
