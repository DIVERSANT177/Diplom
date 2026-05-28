class AddExpressionStatusToDashboards < ActiveRecord::Migration[8.0]
  def change
    add_column :dashboards, :expression_status, :string, default: "pending"
    add_column :dashboards, :expression_error,  :string
  end
end
