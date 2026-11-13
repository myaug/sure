# frozen_string_literal: true

require "test_helper"

class Onchain::TronAddressTest < ActiveSupport::TestCase
  USDT_CONTRACT = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

  test "accepts a real TRON address" do
    assert Onchain::TronAddress.valid?(USDT_CONTRACT)
    assert Onchain::TronAddress.valid?(" #{USDT_CONTRACT} ")
  end

  test "rejects a changed character because the checksum no longer matches" do
    assert_not Onchain::TronAddress.valid?(USDT_CONTRACT.sub("TR7N", "TR7M"))
  end

  test "rejects Solana, Bitcoin, EVM and malformed addresses" do
    [
      "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM",
      "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
      "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
      "", "T", nil
    ].each { |address| assert_not Onchain::TronAddress.valid?(address), "#{address.inspect} should be rejected" }
  end

  test "converts the hex form used inside transactions to Base58" do
    assert_equal "TNPdqto8HiuMzoG7Vv9wyyYhWzCojLeHAF", Onchain::TronAddress.from_hex("4188403ac26730e33164eeac403291b48f300b782f")
    assert_nil Onchain::TronAddress.from_hex("0x1234")
    assert_nil Onchain::TronAddress.from_hex(nil)
  end
end
