module BybitItem::Provided
  extend ActiveSupport::Concern

  def bybit_provider
    return nil unless credentials_configured?

    Provider::Bybit.new(api_key: api_key, api_secret: api_secret)
  end
end
