# frozen_string_literal: true

module Family::OkxConnectable
  extend ActiveSupport::Concern

  included do
    has_many :okx_items, dependent: :destroy
  end

  def can_connect_okx?
    true
  end

  def create_okx_item!(api_key:, api_secret:, api_passphrase:, item_name: nil)
    item = okx_items.create!(
      name: item_name || "OKX",
      api_key: api_key,
      api_secret: api_secret,
      api_passphrase: api_passphrase
    )
    item.sync_later
    item
  end

  def has_okx_credentials?
    okx_items.where.not(api_key: nil).exists?
  end
end
