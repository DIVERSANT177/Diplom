# app/jobs/analysis_job.rb
class AnalysisJob < ApplicationJob
  queue_as :default

  def perform(analysis_id)
    analysis = Analysis.find(analysis_id)
    analysis.update!(status: "running")

    service = case analysis.algorithm
    when "feature_importance" then FeatureImportanceService.new(analysis)
    when "clustering"         then ClusteringService.new(analysis)
    when "survival"           then SurvivalService.new(analysis)
    end

    result = service.call
    analysis.update!(status: "ready", result: result)

  rescue => e
    analysis.update!(status: "error", error_message: e.message)
    raise
  end
end
