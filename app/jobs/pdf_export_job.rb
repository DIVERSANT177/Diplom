class PdfExportJob < ApplicationJob
  queue_as :default

  def perform(dashboard_id, locale: I18n.default_locale, heatmap_png_path: nil)
    dashboard = Dashboard.find(dashboard_id)
    DashboardPdfExporter.new(
      dashboard,
      locale: locale,
      heatmap_png_path: heatmap_png_path
    ).call
    dashboard.update!(
      pdf_status: "ready",
      pdf_generated_at: Time.current,
      pdf_error: nil
    )
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("PdfExportJob: dashboard #{dashboard_id} not found: #{e.message}")
  rescue => e
    Rails.logger.error("PdfExportJob failed for dashboard #{dashboard_id}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    dashboard&.update!(pdf_status: "error", pdf_error: e.message)
    raise
  ensure
    File.delete(heatmap_png_path) if heatmap_png_path && File.exist?(heatmap_png_path)
  end
end
