# frozen_string_literal: true

module Family::MexcConnectable
  extend ActiveSupport::Concern

  included do
    has_many :mexc_items, dependent: :destroy
  end

  def can_connect_mexc?
    true
  end

  def create_mexc_item!(api_key:, api_secret:, item_name: nil)
    item = mexc_items.create!(
      name: item_name || "MEXC",
      api_key: api_key,
      api_secret: api_secret
    )
    item.sync_later
    item
  end

  def has_mexc_credentials?
    mexc_items.where.not(api_key: nil).exists?
  end
end
