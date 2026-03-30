# app/jobs/expression_import_job.rb
class ExpressionImportJob < ApplicationJob
  queue_as :default

  def perform(dashboard_id)
    dashboard = Dashboard.find(dashboard_id)
    GdcExpressionImporter.new(dashboard).call
  end
end
