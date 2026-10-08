class CreateLots < ActiveRecord::Migration[8.1]
  def change
    create_table :lots do |t|
      t.references :product, null: false, foreign_key: true
      t.string :lot_no, null: false
      t.timestamps

      t.index :lot_no, unique: true
    end
  end
end
