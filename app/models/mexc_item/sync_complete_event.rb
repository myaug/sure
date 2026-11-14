# frozen_string_literal: true

# Broadcasts Turbo Stream updates when a MEXC sync completes.
# Updates account views and notifies the family of sync completion.
class MexcItem::SyncCompleteEvent
  attr_reader :mexc_item

  # @param mexc_item [MexcItem] The item that completed syncing
  def initialize(mexc_item)
    @mexc_item = mexc_item
  end

  # Broadcasts sync completion to update UI components.
  def broadcast
    # Update UI with latest account data
    mexc_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Let family handle sync notifications
    mexc_item.family.broadcast_sync_complete
  end
end
