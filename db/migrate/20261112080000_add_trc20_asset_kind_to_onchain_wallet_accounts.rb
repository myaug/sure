class AddTrc20AssetKindToOnchainWalletAccounts < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :onchain_wallet_accounts, name: "chk_onchain_wallet_accounts_known_asset_kind"
    add_check_constraint :onchain_wallet_accounts, "asset_kind IN ('native', 'erc20', 'spl', 'trc20')",
                         name: "chk_onchain_wallet_accounts_known_asset_kind"

    add_index :onchain_wallet_accounts,
              [ :onchain_wallet_item_id, :chain, :wallet_address, :contract_address ],
              unique: true,
              where: "asset_kind = 'trc20'",
              name: "index_onchain_wallet_accounts_unique_trc20"
  end

  def down
    remove_index :onchain_wallet_accounts, name: "index_onchain_wallet_accounts_unique_trc20"

    remove_check_constraint :onchain_wallet_accounts, name: "chk_onchain_wallet_accounts_known_asset_kind"
    add_check_constraint :onchain_wallet_accounts, "asset_kind IN ('native', 'erc20', 'spl')",
                         name: "chk_onchain_wallet_accounts_known_asset_kind"
  end
end
