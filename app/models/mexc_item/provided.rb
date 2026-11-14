module MexcItem::Provided
  extend ActiveSupport::Concern

  def mexc_provider
    return nil unless credentials_configured?

    Provider::Mexc.new(api_key: api_key, api_secret: api_secret)
  end
end
