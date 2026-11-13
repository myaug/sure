# frozen_string_literal: true

# Keyless TRON data source backed by TronGrid's public HTTP API (read-only).
#
# An optional TRONGRID_API_KEY raises the rate limit; nothing here ever needs
# one. The account summary returns the TRX balance and every TRC-20 balance in
# one request, which is what makes wallet detection a single bounded call. It
# carries no token metadata (symbol, decimals), so that is read from transfer
# history by the caller.
class Provider::TronGrid
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_BASE_URL = "https://api.trongrid.io"
  DEFAULT_MAX_PAGES = 10
  PAGE_LIMIT = 200
  MIN_REQUEST_INTERVAL = 0.3
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5

  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  # True when a collection stopped on the page budget rather than its last page.
  attr_reader :truncated

  def initialize(max_pages: DEFAULT_MAX_PAGES, request_timeout: nil, max_retries: MAX_RETRIES)
    @base_url = ENV["TRONGRID_URL"].presence || DEFAULT_BASE_URL
    @max_pages = max_pages
    @request_timeout = request_timeout
    @max_retries = max_retries
    @truncated = false
  end

  # Whether the address is worth tracking: a TRX balance, or any TRC-20 balance.
  # An address that was never activated on-chain has no account and answers false.
  def has_activity?(address)
    summary = account(address)
    return false if summary.nil?

    summary["balance"].to_i.positive? || trc20_balances(address).any?
  end

  # @return [Integer] TRX balance in sun (1 TRX = 1_000_000 sun)
  def native_balance(address)
    account(address)&.dig("balance").to_i
  end

  # Positive TRC-20 balances only, in each token's smallest unit.
  # @return [Array<Hash>] { contract:, raw_amount: }
  def trc20_balances(address)
    Array(account(address)&.dig("trc20")).flat_map do |entry|
      entry.to_h.filter_map do |contract, raw|
        next unless raw.to_s.to_i.positive?

        { contract: contract.to_s, raw_amount: raw.to_s }
      end
    end
  end

  # Confirmed TRC-20 transfers touching the address, newest first. Each entry
  # carries the token's metadata, which is the only place TronGrid reports it.
  # @return [Array<Hash>] { external_id:, contract:, symbol:, name:, decimals:, raw_amount: (signed), timestamp: }
  def trc20_transfers(address)
    paginate("/v1/accounts/#{encode(address)}/transactions/trc20", "only_confirmed" => true).filter_map do |transfer|
      info = transfer["token_info"].to_h
      contract = info["address"].to_s
      next if contract.blank?

      raw = signed_amount(transfer["value"], from: transfer["from"], to: transfer["to"], address: address)
      next if raw.zero?

      {
        external_id: transfer["transaction_id"],
        contract: contract,
        symbol: info["symbol"],
        name: info["name"],
        decimals: info["decimals"].to_i,
        raw_amount: raw,
        timestamp: parse_time(transfer["block_timestamp"])
      }
    end
  end

  # Confirmed TRX transfers touching the address. Smart-contract calls (which
  # also appear in this feed) are TRC-20 movements and are read separately.
  # @return [Array<Hash>] { external_id:, raw_amount: (signed sun), timestamp: }
  def native_transfers(address)
    paginate("/v1/accounts/#{encode(address)}/transactions", "only_confirmed" => true).filter_map do |transaction|
      next unless transaction.dig("ret", 0, "contractRet") == "SUCCESS"

      contract = transaction.dig("raw_data", "contract", 0).to_h
      next unless contract["type"] == "TransferContract"

      value = contract.dig("parameter", "value").to_h
      raw = signed_amount(
        value["amount"],
        from: Onchain::TronAddress.from_hex(value["owner_address"]),
        to: Onchain::TronAddress.from_hex(value["to_address"]),
        address: address
      )
      next if raw.zero?

      { external_id: transaction["txID"], raw_amount: raw, timestamp: parse_time(transaction["block_timestamp"]) }
    end
  end

  private
    def account(address)
      @accounts ||= {}
      return @accounts[address.to_s] if @accounts.key?(address.to_s)

      body = api_get("/v1/accounts/#{encode(address)}")
      @accounts[address.to_s] = Array(body.is_a?(Hash) ? body["data"] : nil).first
    end

    def paginate(path, params = {})
      items = []
      fingerprint = nil

      @max_pages.times do
        query = params.merge("limit" => PAGE_LIMIT)
        query["fingerprint"] = fingerprint if fingerprint
        body = api_get("#{path}?#{URI.encode_www_form(query)}")

        page = Array(body.is_a?(Hash) ? body["data"] : nil)
        items.concat(page)

        fingerprint = body.is_a?(Hash) ? body.dig("meta", "fingerprint") : nil
        break if fingerprint.blank? || page.empty?
      end

      @truncated ||= fingerprint.present?
      items
    end

    # The sender of a transfer to itself nets to nothing, so it is not a movement.
    def signed_amount(value, from:, to:, address:)
      amount = value.to_s.to_i
      received = to.to_s == address.to_s
      sent = from.to_s == address.to_s
      return 0 if received == sent

      received ? amount : -amount
    end

    def parse_time(milliseconds)
      return nil if milliseconds.blank?

      Time.zone.at(milliseconds.to_i / 1000.0)
    end

    def encode(address)
      ERB::Util.url_encode(address.to_s)
    end

    def api_get(path)
      attempts = 0

      begin
        attempts += 1
        throttle_request
        translate_transport_errors { handle_response(self.class.get("#{@base_url}#{path}", **request_options)) }
      rescue RateLimitError => e
        raise if attempts > @max_retries

        Rails.logger.warn("Provider::TronGrid - rate limited (attempt #{attempts}/#{@max_retries}): #{e.message}")
        sleep(RETRY_BASE_DELAY * (2**(attempts - 1)))
        retry
      end
    end

    def request_options
      options = {}
      options[:timeout] = @request_timeout if @request_timeout
      api_key = ENV["TRONGRID_API_KEY"].presence
      options[:headers] = { "TRON-PRO-API-KEY" => api_key } if api_key
      options
    end

    def throttle_request
      @last_request_at ||= Time.at(0)
      remaining = MIN_REQUEST_INTERVAL - (Time.current - @last_request_at)
      sleep(remaining) if remaining.positive?
      @last_request_at = Time.current
    end

    def handle_response(response)
      raise RateLimitError, "TronGrid rate limit exceeded" if response.code == 429
      raise ApiError, "TronGrid API error: #{response.code}" unless response.code.between?(200, 299)

      response.parsed_response
    end
end
