# app/models/analysis.rb
class Analysis < ApplicationRecord
  belongs_to :dashboard

  ALGORITHMS = %w[feature_importance clustering survival].freeze

  validates :algorithm, inclusion: { in: ALGORITHMS }
  validates :status, inclusion: { in: %w[pending running ready error] }

  # Удобные методы статуса
  def pending?  = status == "pending"
  def running?  = status == "running"
  def ready?    = status == "ready"
  def error?    = status == "error"

  # Параметры с дефолтами
  def n_clusters  = params.fetch("n_clusters", 3).to_i
  def n_top_genes = params.fetch("n_top_genes", 50).to_i
  def n_trees     = params.fetch("n_trees", 100).to_i
  def reg_param   = params.fetch("reg_param", 1.0).to_f

  # "cox" — Cox proportional hazards (учитывает цензурирование).
  # "ridge" — Ridge на log(time) (legacy, проще, но смещён по цензурированным).
  SURVIVAL_MODELS = %w[cox ridge].freeze
  def model_type
    SURVIVAL_MODELS.include?(params["model_type"]) ? params["model_type"] : "cox"
  end
end
