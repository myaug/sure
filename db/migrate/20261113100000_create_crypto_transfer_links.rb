class CreateCryptoTransferLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :crypto_transfer_links, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :outflow_entry, null: false, type: :uuid, index: false,
                   foreign_key: { to_table: :entries, on_delete: :cascade }
      t.references :inflow_entry, null: false, type: :uuid, index: false,
                   foreign_key: { to_table: :entries, on_delete: :cascade }

      t.string :status, null: false, default: "pending"
      t.string :basis, null: false

      t.timestamps
    end

    # A rejected pair stays on record so it is never suggested again; a leg can
    # belong to only one live (pending or confirmed) link.
    add_index :crypto_transfer_links, [ :outflow_entry_id, :inflow_entry_id ],
              unique: true, name: "index_crypto_transfer_links_on_pair"
    add_index :crypto_transfer_links, :outflow_entry_id,
              unique: true, where: "status <> 'rejected'", name: "index_crypto_transfer_links_on_live_outflow"
    add_index :crypto_transfer_links, :inflow_entry_id,
              unique: true, where: "status <> 'rejected'", name: "index_crypto_transfer_links_on_live_inflow"
  end
end
