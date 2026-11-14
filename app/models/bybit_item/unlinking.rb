# frozen_string_literal: true

module BybitItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    results = []

    bybit_accounts.find_each do |provider_account|
      links = AccountProvider.where(provider_type: BybitAccount.name, provider_id: provider_account.id).to_a
      link_ids = links.map(&:id)
      result = {
        provider_account_id: provider_account.id,
        name: provider_account.name,
        provider_link_ids: link_ids
      }
      results << result

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          if link_ids.any?
            Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil)
          end
          links.each(&:destroy!)
        end
      rescue StandardError => e
        Rails.logger.warn("BybitItem Unlinker: failed to unlink ##{provider_account.id}: #{e.class} - #{e.message}")
        result[:error] = e.message
      end
    end

    results
  end
end
