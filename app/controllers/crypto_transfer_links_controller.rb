# frozen_string_literal: true

# Confirms or rejects a pending pairing of a crypto withdrawal with a deposit.
class CryptoTransferLinksController < ApplicationController
  def update
    link = Current.family.crypto_transfer_links.pending.find(params[:id])

    unless writable?(link)
      redirect_to auto_matches_path, alert: t(".not_allowed")
      return
    end

    status = params.dig(:crypto_transfer_link, :status)
    unless %w[confirmed rejected].include?(status)
      redirect_to auto_matches_path, alert: t(".invalid_status")
      return
    end

    # Reloaded under a row lock, so a link another request already resolved is
    # not resolved twice.
    link.with_lock do
      next unless link.pending?

      status == "confirmed" ? link.confirm! : link.reject!
    end

    redirect_to auto_matches_path, notice: t(".#{status}")
  end

  private
    # Resolving a link changes how both accounts read the movement, so the user
    # must be able to write to both.
    def writable?(link)
      writable_ids = Account.writable_by(Current.user).where(family: Current.family).ids.to_set
      link.accounts.size == 2 && link.accounts.all? { |account| writable_ids.include?(account.id) }
    end
end
