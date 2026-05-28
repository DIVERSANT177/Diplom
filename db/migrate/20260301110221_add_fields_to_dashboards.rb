class AddFieldsToDashboards < ActiveRecord::Migration[8.0]
  def change
    add_column :dashboards, :status,            :string,   default: "draft"
    add_column :dashboards, :projects,          :jsonb,    default: []
    add_column :dashboards, :case_filters,      :jsonb,    default: {}
    add_column :dashboards, :visualizations,    :jsonb,    default: []
    add_column :dashboards, :survival_endpoint, :string,   default: "OS"
    add_column :dashboards, :stratify_by,       :string
    add_column :dashboards, :top_genes_count,   :integer,  default: 50
    add_column :dashboards, :total_cases,       :integer
    add_column :dashboards, :data_fetched_at,   :datetime
    add_column :dashboards, :error_message,     :text
  end
end
