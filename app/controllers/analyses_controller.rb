# app/controllers/analyses_controller.rb
class AnalysesController < ApplicationController
  before_action :set_dashboard
  before_action :set_analysis, only: [ :show ]

  def index
    @analyses = @dashboard.analyses.order(created_at: :desc)
    @history = @analyses.limit(10)

    @pipeline = {}
    %w[feature_importance clustering survival].each do |algo|
      @pipeline[algo] = @analyses.find { |a| a.algorithm == algo }
    end
    @any_running = @pipeline.values.any? { |a| a&.status&.in?(%w[pending running]) }

    # Для блока «Сравнение моделей»: берём последние ready Cox и Ridge.
    # У старых анализов (до добавления model_type) ключа нет — считаем их Ridge.
    ready_survival = @analyses.select { |a| a.algorithm == "survival" && a.ready? }
    @cox_analysis   = ready_survival.find { |a| (a.result["model_type"] || "ridge") == "cox" }
    @ridge_analysis = ready_survival.find { |a| (a.result["model_type"] || "ridge") == "ridge" }
  end

  def new
    @analysis = @dashboard.analyses.build
    @fi_ready = @dashboard.analyses.exists?(algorithm: "feature_importance", status: "ready")
    @cl_ready = @dashboard.analyses.exists?(algorithm: "clustering", status: "ready")
  end

  def create
    @analysis = @dashboard.analyses.build(analysis_params)

    if (error = guard_violations)
      redirect_to dashboard_analyses_path(@dashboard), alert: error
      return
    end

    if @analysis.save
      AnalysisJob.perform_later(@analysis.id)
      redirect_to dashboard_analyses_path(@dashboard), notice: t("analyses.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
  end

  private

  def set_dashboard
    @dashboard = current_user.dashboards.find(params[:dashboard_id])
  end

  def set_analysis
    @analysis = @dashboard.analyses.find(params[:id])
  end

  def analysis_params
    params.require(:analysis).permit(:algorithm, params: {})
  end

  # Гарды против direct-POST-обхода UI: для clustering/survival нужен ready FI,
  # и нельзя стартовать второй такой же анализ, пока предыдущий ещё бежит.
  def guard_violations
    algo = @analysis.algorithm
    return nil unless Analysis::ALGORITHMS.include?(algo)

    if algo.in?(%w[clustering survival]) &&
       !@dashboard.analyses.exists?(algorithm: "feature_importance", status: "ready")
      return t("analyses.errors.fi_required")
    end

    if @dashboard.analyses.exists?(algorithm: algo, status: %w[pending running])
      return t("analyses.errors.already_running")
    end

    nil
  end
end
