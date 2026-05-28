class Dashboard < ApplicationRecord
  include Turbo::Broadcastable
  extend ActionView::RecordIdentifier

  after_update_commit -> { broadcast_replace_to "dashboard_#{id}" }
  after_update_commit :broadcast_pdf_export_update

  belongs_to :user
  has_many :cases, dependent: :destroy
  has_many :gene_expressions, dependent: :destroy
  has_many :analyses, dependent: :destroy

  STATUSES = %w[draft fetching ready error].freeze
  ENDPOINTS = %w[OS].freeze
  VISUALIZATIONS = %w[kaplan_meier heatmap clinical_summary].freeze
  PDF_STATUSES = %w[idle generating ready error].freeze

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :survival_endpoint, inclusion: { in: ENDPOINTS }

  scope :recent, -> { order(updated_at: :desc) }
  scope :ready,  -> { where(status: "ready") }

  def self.visualization_label(key)
    I18n.t("dashboards.visualizations.#{key}")
  end

  def pdf_file_path
    Rails.root.join("storage", "dashboard_pdfs", "#{id}.pdf")
  end

  def pdf_ready?
    pdf_status == "ready" && File.exist?(pdf_file_path)
  end

  def pdf_generating?
    pdf_status == "generating"
  end

  private

  def broadcast_pdf_export_update
    return unless saved_change_to_pdf_status? || saved_change_to_pdf_generated_at? || saved_change_to_pdf_error?

    broadcast_replace_to(
      "dashboard_#{id}",
      target: ActionView::RecordIdentifier.dom_id(self, :pdf_export),
      partial: "dashboards/pdf_export",
      locals: { dashboard: self }
    )
  end
end
