# frozen_string_literal: true

class Provider::MexcAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("MexcAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    %w[Crypto]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_mexc?

    [ {
      key: "mexc",
      name: "MEXC",
      description: "Link to a MEXC wallet",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_mexc_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_mexc_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "mexc"
  end

  # Build a MEXC provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Mexc, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    mexc_item = family.mexc_items.where.not(api_key: nil).order(created_at: :desc).first
    return nil unless mexc_item&.credentials_configured?

    Provider::Mexc.new(
      api_key: mexc_item.api_key,
      api_secret: mexc_item.api_secret
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_mexc_item_path(item)
  end

  def item
    provider_account.mexc_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    metadata = provider_account.institution_metadata || {}

    domain = metadata["domain"]
    url = metadata["url"]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for MEXC account #{provider_account.id}: #{url}")
      end
    end

    domain || item&.institution_domain
  end

  def institution_name
    metadata = provider_account.institution_metadata || {}
    metadata["name"] || item&.institution_name
  end

  def institution_url
    metadata = provider_account.institution_metadata || {}
    metadata["url"] || item&.institution_url
  end

  def institution_color
    metadata = provider_account.institution_metadata || {}
    metadata["color"] || item&.institution_color
  end
end
