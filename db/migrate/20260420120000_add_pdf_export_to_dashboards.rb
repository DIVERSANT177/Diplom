class AddPdfExportToDashboards < ActiveRecord::Migration[8.0]
  def change
    add_column :dashboards, :pdf_status, :string, default: "idle"
    add_column :dashboards, :pdf_generated_at, :datetime
    add_column :dashboards, :pdf_error, :string
  end
end
