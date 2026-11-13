# frozen_string_literal: true

require "digest"

# TRON addresses: Base58Check over a 0x41 version byte and a 20-byte account
# hash, 34 characters starting with "T". Validating the checksum (not just the
# shape) matters because the shape also fits Solana and Bitcoin addresses, so
# chain detection would otherwise probe TRON for every one of them.
module Onchain::TronAddress
  ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  VERSION_BYTE = "41"
  SHAPE = /\AT[1-9A-HJ-NP-Za-km-z]{33}\z/

  class << self
    def valid?(address)
      value = address.to_s.strip
      return false unless SHAPE.match?(value)

      bytes_hex = decode_hex(value)
      return false if bytes_hex.nil? || bytes_hex.length != 50

      payload = bytes_hex[0, 42]
      checksum = bytes_hex[42, 8]
      payload.start_with?(VERSION_BYTE) && checksum == checksum_of(payload)
    end

    # The 41-prefixed hex form TronGrid returns inside transactions, back to the
    # Base58 form users and the rest of the API use. Nil for anything that is
    # not a 21-byte TRON account.
    def from_hex(hex)
      payload = hex.to_s.downcase
      return nil unless payload.match?(/\A41[0-9a-f]{40}\z/)

      encode_hex(payload + checksum_of(payload))
    end

    private
      def checksum_of(payload_hex)
        payload = [ payload_hex ].pack("H*")
        Digest::SHA256.hexdigest(Digest::SHA256.digest(payload))[0, 8]
      end

      def decode_hex(value)
        number = value.each_char.reduce(0) do |acc, char|
          index = ALPHABET.index(char)
          return nil if index.nil?

          acc * 58 + index
        end

        number.to_s(16).rjust(50, "0")
      end

      def encode_hex(hex)
        number = hex.to_i(16)
        encoded = +""
        while number.positive?
          number, remainder = number.divmod(58)
          encoded.prepend(ALPHABET[remainder])
        end
        encoded
      end
  end
end
