require "test_helper"

class CryptoTransfer::NetworkTest < ActiveSupport::TestCase
  test "reads the many names of a chain as one" do
    assert_equal "tron", CryptoTransfer::Network.normalize("TRX")
    assert_equal "tron", CryptoTransfer::Network.normalize("USDT-TRC20")
    assert_equal "tron", CryptoTransfer::Network.normalize("Tron (TRC20)")
    assert_equal "ethereum", CryptoTransfer::Network.normalize("ETH-Ethereum")
    assert_equal "ethereum", CryptoTransfer::Network.normalize("ERC20")
    assert_equal "bsc", CryptoTransfer::Network.normalize("BSC")
    assert_equal "bsc", CryptoTransfer::Network.normalize("BNB Smart Chain (BEP20)")
    assert_equal "solana", CryptoTransfer::Network.normalize("SOL")
  end

  test "leaves a chain it does not know unnamed" do
    assert_nil CryptoTransfer::Network.normalize("Exotic Chain")
    assert_nil CryptoTransfer::Network.normalize("")
    assert_nil CryptoTransfer::Network.normalize(nil)
  end
end
