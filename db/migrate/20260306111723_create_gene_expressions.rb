class CreateGeneExpressions < ActiveRecord::Migration[8.0]
  def change
    create_table :gene_expressions do |t|
      t.references :dashboard, null: false, foreign_key: true
      t.string :case_id,    null: false
      t.string :gene_id,    null: false
      t.string :gene_name,  null: false
      t.float  :tpm,        null: false
      t.string :project_id, null: false
      t.timestamps
    end

    add_index :gene_expressions, [ :dashboard_id, :gene_id ]
    add_index :gene_expressions, [ :dashboard_id, :case_id ]
    add_index :gene_expressions, [ :dashboard_id, :case_id, :gene_id ],
              unique: true,
              name: "idx_expression_unique"
  end
end
