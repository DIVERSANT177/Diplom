class CreateCases < ActiveRecord::Migration[8.0]
  def change
    create_table :cases do |t|
      t.belongs_to :dashboard, null: false, foreign_key: true

      # Идентификаторы
      t.string :case_id, null: false
      t.string :project_id, null: false

      # Демография
      t.string  :gender
      t.integer :age_at_index

      # Диагноз
      t.string :tumor_stage
      t.string :vital_status

      # Для выживаемости
      t.float :days_to_death
      t.float :days_to_last_follow_up

      t.timestamps
    end

    add_index :cases, :case_id
    add_index :cases, :project_id
  end
end
