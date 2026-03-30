class CreateAnalyses < ActiveRecord::Migration[8.0]
  def change
    create_table :analyses do |t|
      t.bigint  :dashboard_id, null: false
      t.string  :algorithm,    null: false  # feature_importance | clustering | survival
      t.string  :status,       default: "pending"
      t.jsonb   :params,       default: {}
      t.jsonb   :result,       default: {}
      t.text    :error_message

      t.timestamps
    end

    add_index :analyses, :dashboard_id
    add_index :analyses, :status
    add_foreign_key :analyses, :dashboards
  end
end
