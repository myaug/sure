require "test_helper"

class CryptoTransfer::TxHashTest < ActiveSupport::TestCase
  HASH = "ab" * 32

  test "reads EVM, bare hex and embedded hashes into one form" do
    assert_equal HASH, CryptoTransfer::TxHash.normalize("0x#{HASH}")
    assert_equal HASH, CryptoTransfer::TxHash.normalize(HASH.upcase)
    assert_equal HASH, CryptoTransfer::TxHash.normalize("0x#{HASH}_0xcontract")
    assert_equal HASH, CryptoTransfer::TxHash.normalize(" #{HASH}\n")
  end

  test "keeps a Solana signature as it is" do
    signature = "5" * 88

    assert_equal signature, CryptoTransfer::TxHash.normalize(signature)
    assert_equal signature, CryptoTransfer::TxHash.normalize("#{signature}_MintAddress")
  end

  test "has no hash for blanks, internal transfer markers or short strings" do
    assert_nil CryptoTransfer::TxHash.normalize(nil)
    assert_nil CryptoTransfer::TxHash.normalize("")
    assert_nil CryptoTransfer::TxHash.normalize("Internal transfer 12345")
    assert_nil CryptoTransfer::TxHash.normalize("abc123")
    assert_nil CryptoTransfer::TxHash.normalize("f" * 65), "a longer hex run is not a 64-digit hash"
  end

  test "an entry uses the hash its provider stored" do
    entry, trade = stub_entry(source: "bybit", external_id: "bybit_withdraw_1", extra: { "crypto_transfer" => { "tx_hash" => "0x#{HASH}" } })

    assert_equal HASH, CryptoTransfer::TxHash.for_entry(entry, trade)
  end

  test "an on-chain wallet entry carries its hash in the external id" do
    entry, trade = stub_entry(source: "onchain_wallet", external_id: "onchain_#{SecureRandom.uuid}_#{HASH}_0xcontract", extra: {})

    assert_equal HASH, CryptoTransfer::TxHash.for_entry(entry, trade)
  end

  test "an entry from another provider without a stored hash has none" do
    entry, trade = stub_entry(source: "kraken", external_id: "kraken_ledger_#{HASH}", extra: {})

    assert_nil CryptoTransfer::TxHash.for_entry(entry, trade)
  end

  private

    def stub_entry(source:, external_id:, extra:)
      [ stub(source: source, external_id: external_id), stub(extra: extra) ]
    end
end
