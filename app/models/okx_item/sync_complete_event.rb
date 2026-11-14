# frozen_string_literal: true

# Broadcasts Turbo Stream updates when a OKX sync completes.
# Updates account views and notifies the family of sync completion.
class OkxItem::SyncCompleteEvent
  attr_reader :okx_item

  # @param okx_item [OkxItem] The item that completed syncing
  def initialize(okx_item)
    @okx_item = okx_item
  end

  # Broadcasts sync completion to update UI components.
  def broadcast
    # Update UI with latest account data
    okx_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Let family handle sync notifications
    okx_item.family.broadcast_sync_complete
  end
end
