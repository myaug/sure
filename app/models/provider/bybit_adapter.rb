# frozen_string_literal: true

class Provider::BybitAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("BybitAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    %w[Crypto]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_bybit?

    [ {
      key: "bybit",
      name: "Bybit",
      description: "Link to a Bybit wallet",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_bybit_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_bybit_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "bybit"
  end

  # Build a Bybit provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Bybit, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    bybit_item = family.bybit_items.where.not(api_key: nil).order(created_at: :desc).first
    return nil unless bybit_item&.credentials_configured?

    Provider::Bybit.new(
      api_key: bybit_item.api_key,
      api_secret: bybit_item.api_secret
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_bybit_item_path(item)
  end

  def item
    provider_account.bybit_item
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
        Rails.logger.warn("Invalid institution URL for Bybit account #{provider_account.id}: #{url}")
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
