class ImportCasesJob < ApplicationJob
  queue_as :default

  def perform(dashboard_id)
    dashboard = Dashboard.find(dashboard_id)
    GdcCasesImporter.new(dashboard).call
  end
end
