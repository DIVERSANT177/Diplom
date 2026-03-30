class Dashboard < ApplicationRecord
  include Turbo::Broadcastable

  after_update_commit -> { broadcast_replace_to "dashboard_#{id}" }

  belongs_to :user
  has_many :cases, dependent: :destroy
  has_many :gene_expressions, dependent: :destroy
  has_many :analyses, dependent: :destroy

  STATUSES = %w[draft fetching ready error].freeze
  ENDPOINTS = %w[OS].freeze
  VISUALIZATIONS = %w[kaplan_meier heatmap clinical_summary].freeze
  VISUALIZATIONS = %w[kaplan_meier heatmap clinical_summary].freeze

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :survival_endpoint, inclusion: { in: ENDPOINTS }

  scope :recent, -> { order(updated_at: :desc) }
  scope :ready,  -> { where(status: "ready") }

  def self.visualization_label(key)
    I18n.t("dashboards.visualizations.#{key}")
  end
end
