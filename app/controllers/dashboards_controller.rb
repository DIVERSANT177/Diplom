class DashboardsController < ApplicationController
  before_action :set_dashboard, only: %i[ show edit update destroy ]

  # GET /dashboards or /dashboards.json
  def index
    @dashboards = current_user.dashboards.recent
  end

  # GET /dashboards/1 or /dashboards/1.json
  def show
    @clinical_summary = {
      gender: @dashboard.cases.where.not(gender: nil).group(:gender).count,
      vital_status: @dashboard.cases.where.not(vital_status: nil).group(:vital_status).count,
      age_groups: age_groups_for(@dashboard)
    }

    if @dashboard.visualizations.include?("kaplan_meier") && @dashboard.status == "ready"
      cases = @dashboard.cases.where.not(vital_status: nil)

      if @dashboard.stratify_by.present?
        cases = cases.where.not(@dashboard.stratify_by => nil)
      end

      @kaplan_meier = KaplanMeierCalculator.new(
        cases,
        stratify_by: @dashboard.stratify_by,
        endpoint: @dashboard.survival_endpoint
      ).call
    end

    if @dashboard.visualizations.include?("heatmap") && @dashboard.expression_status == "ready"
      @heatmap = @dashboard.gene_expressions.to_heatmap_matrix(
        @dashboard.cases,
        top_n: @dashboard.top_genes_count
      )
    end
  end

  # GET /dashboards/new
  def new
    @dashboard = Dashboard.new
    @projects = GdcClient.new.projects
  end

  # GET /dashboards/1/edit
  def edit
    @projects = GdcClient.new.projects
  end

  def create
    @dashboard = Dashboard.new(dashboard_params)
    @dashboard.user = current_user

    if @dashboard.save
      ImportCasesJob.perform_later(@dashboard.id)
      redirect_to @dashboard
    else
      @projects = GdcClient.new.projects
      render :new, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /dashboards/1 or /dashboards/1.json
  def update
    respond_to do |format|
      if @dashboard.update(dashboard_params)
        format.html { redirect_to @dashboard, status: :see_other }
        format.json { render :show, status: :ok, location: @dashboard }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @dashboard.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /dashboards/1 or /dashboards/1.json
  def destroy
    @dashboard.destroy!

    respond_to do |format|
      format.html { redirect_to dashboards_path, status: :see_other }
      format.json { head :no_content }
    end
  end

  private
  # Use callbacks to share common setup or constraints between actions.
  def set_dashboard
    @dashboard = Dashboard.find(params.expect(:id))
  end

  # Only allow a list of trusted parameters through.
  def dashboard_params
    params.require(:dashboard).permit(
      :title,
      :survival_endpoint,
      :stratify_by,
      :top_genes_count,
      projects: [],
      visualizations: []
    )
  end

  def age_groups_for(dashboard)
    dashboard.cases.where.not(age_at_index: nil).pluck(:age_at_index).each_with_object(
      { "< 40" => 0, "40-60" => 0, "> 60" => 0 }
    ) do |age, groups|
      if age < 40
        groups["< 40"] += 1
      elsif age <= 60
        groups["40-60"] += 1
      else
        groups["> 60"] += 1
      end
    end
  end
end
