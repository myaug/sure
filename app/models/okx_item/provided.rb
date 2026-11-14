module OkxItem::Provided
  extend ActiveSupport::Concern

  def okx_provider
    return nil unless credentials_configured?

    Provider::Okx.new(api_key: api_key, api_secret: api_secret, api_passphrase: api_passphrase)
  end
end
