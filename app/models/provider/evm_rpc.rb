# frozen_string_literal: true

# Keyless EVM data source for networks with no public token indexer (BNB Smart
# Chain). It reads balances straight from a public JSON-RPC node: the native
# coin plus a curated list of well-known tokens, all in ONE batched request.
#
# That is the trade-off against an indexer: tokens outside the curated list are
# not discovered, and there is no transfer history (so snapshots built from it
# report an incomplete history). Wallet linking never needs history.
#
# Read-only by construction: it only issues eth_getBalance and eth_call.
class Provider::EvmRpc
  include Provider::EvmExplorer
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  # balanceOf(address)
  BALANCE_OF_SELECTOR = "0x70a08231"

  default_options.merge!({ timeout: 20 }.merge(httparty_ssl_options))

  # History is not available through a plain node.
  def truncated
    true
  end

  # @param tokens [Array<Hash>] { contract:, symbol:, name:, decimals: }
  def initialize(chain:, rpc_url:, tokens: [], request_timeout: nil)
    @chain = chain.to_s
    @rpc_url = ENV["EVM_RPC_#{@chain.upcase}_URL"].presence || rpc_url
    @tokens = tokens
    @request_timeout = request_timeout
  end

  def has_activity?(address)
    native_balance(address).to_i.positive? ||
      token_balances(address).any? { |token| token[:raw_amount].to_i.positive? }
  end

  def native_balance(address)
    balances(address).fetch(:native).to_s
  end

  def token_balances(address)
    held = balances(address).fetch(:tokens)

    @tokens.filter_map do |token|
      raw = held[token[:contract].downcase]
      next if raw.nil?

      token.slice(:contract, :symbol, :name, :decimals).merge(
        contract: token[:contract].downcase,
        raw_amount: raw.to_s,
        market_cap: nil,
        rate: nil
      )
    end
  end

  def transfers(_address)
    []
  end

  private
    # One batched request answers the native balance and every token balance, so
    # detection and snapshots stay a single bounded call.
    def balances(address)
      @balances ||= {}
      @balances[address.to_s] ||= fetch_balances(address.to_s)
    end

    def fetch_balances(address)
      calls = [ rpc_call(0, "eth_getBalance", [ address, "latest" ]) ]
      @tokens.each_with_index do |token, index|
        calls << rpc_call(index + 1, "eth_call", [ { to: token[:contract], data: balance_of_data(address) }, "latest" ])
      end

      results = post(calls).index_by { |entry| entry["id"] }

      {
        native: hex_to_int(result_for(results, 0)),
        tokens: @tokens.each_with_index.to_h do |token, index|
          [ token[:contract].downcase, hex_to_int(results.dig(index + 1, "result")) ]
        end
      }
    end

    def result_for(results, id)
      entry = results[id]
      raise ApiError, "EVM RPC returned no result" if entry.nil? || entry["result"].nil?

      entry["result"]
    end

    def rpc_call(id, method, params)
      { jsonrpc: "2.0", id: id, method: method, params: params }
    end

    def balance_of_data(address)
      BALANCE_OF_SELECTOR + address.delete_prefix("0x").downcase.rjust(64, "0")
    end

    # A token that answers with an error (or nothing) is treated as a zero
    # balance rather than failing the whole read.
    def hex_to_int(value)
      value.to_s.start_with?("0x") && value.length > 2 ? value.to_i(16) : 0
    end

    def post(calls)
      translate_transport_errors do
        response = self.class.post(
          @rpc_url,
          body: calls.to_json,
          headers: { "Content-Type" => "application/json" },
          **timeout_option
        )
        raise RateLimitError, "EVM RPC rate limit exceeded" if response.code == 429
        raise ApiError, "EVM RPC error: #{response.code}" unless response.code.between?(200, 299)

        parsed = response.parsed_response
        raise ApiError, "EVM RPC returned an unexpected response" unless parsed.is_a?(Array)

        parsed
      end
    end

    def timeout_option
      @request_timeout ? { timeout: @request_timeout } : {}
    end
end
