# frozen_string_literal: true

module Family::BybitConnectable
  extend ActiveSupport::Concern

  included do
    has_many :bybit_items, dependent: :destroy
  end

  def can_connect_bybit?
    true
  end

  def create_bybit_item!(api_key:, api_secret:, item_name: nil)
    item = bybit_items.create!(
      name: item_name || "Bybit",
      api_key: api_key,
      api_secret: api_secret
    )
    item.sync_later
    item
  end

  def has_bybit_credentials?
    bybit_items.where.not(api_key: nil).exists?
  end
end
