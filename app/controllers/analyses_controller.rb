# app/controllers/analyses_controller.rb
class AnalysesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_dashboard
  before_action :set_analysis, only: [ :show ]

  def index
    @analyses = @dashboard.analyses.order(created_at: :desc)
  end

  def new
    @analysis = @dashboard.analyses.build
    @fi_ready = @dashboard.analyses.exists?(algorithm: "feature_importance", status: "ready")
    @cl_ready = @dashboard.analyses.exists?(algorithm: "clustering", status: "ready")
  end

  def create
    @analysis = @dashboard.analyses.build(analysis_params)

    if @analysis.save
      AnalysisJob.perform_later(@analysis.id)
      redirect_to dashboard_analysis_path(@dashboard, @analysis),
                  notice: t("analyses.created")
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
    params.require(:analysis).permit(:algorithm, params: [ :n_clusters, :n_top_genes, :n_trees ])
  end
end
