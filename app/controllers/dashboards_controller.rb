class DashboardsController < ApplicationController
  before_action :set_dashboard, only: %i[ show edit update destroy heatmap_data export_pdf download_pdf ]

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
        stratify_by: @dashboard.stratify_by
      ).call
    end

    # Heatmap загружается асинхронно через heatmap_data action
  end

  # GET /dashboards/:id/heatmap_data.json
  def heatmap_data
    unless @dashboard.expression_status == "ready"
      return render json: { error: "not_ready" }, status: 422
    end

    page     = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 100).to_i.clamp(10, 200)

    total_samples = @dashboard.gene_expressions.distinct.count(:case_id)

    heatmap = @dashboard.gene_expressions.to_heatmap_matrix(
      @dashboard.cases,
      top_n:         @dashboard.top_genes_count,
      sample_limit:  per_page,
      sample_offset: (page - 1) * per_page
    )

    render json: {
      heatmap:       heatmap,
      page:          page,
      per_page:      per_page,
      total_samples: total_samples,
      total_pages:   (total_samples.to_f / per_page).ceil
    }
  rescue => e
    Rails.logger.error("Heatmap data error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    render json: { error: e.message }, status: 500
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

  # POST /dashboards/:id/export_pdf
  def export_pdf
    if @dashboard.pdf_generating?
      redirect_to @dashboard, notice: t("dashboards.pdf.already_generating")
      return
    end

    heatmap_png_path = persist_heatmap_snapshot(@dashboard, params[:heatmap_png])

    @dashboard.update!(pdf_status: "generating", pdf_error: nil)
    PdfExportJob.perform_later(
      @dashboard.id,
      locale: I18n.locale.to_s,
      heatmap_png_path: heatmap_png_path
    )

    respond_to do |format|
      format.html { redirect_to @dashboard, notice: t("dashboards.pdf.started") }
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@dashboard, :pdf_export),
          partial: "dashboards/pdf_export",
          locals: { dashboard: @dashboard }
        )
      end
    end
  end

  # GET /dashboards/:id/download_pdf
  def download_pdf
    unless @dashboard.pdf_ready?
      redirect_to @dashboard, alert: t("dashboards.pdf.not_ready") and return
    end

    send_file @dashboard.pdf_file_path,
              filename: "#{@dashboard.title.to_s.parameterize.presence || 'dashboard'}.pdf",
              type: "application/pdf",
              disposition: "attachment"
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
    @dashboard = current_user.dashboards.find(params[:id])
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

  def persist_heatmap_snapshot(dashboard, data_url)
    return nil if data_url.blank?

    match = data_url.match(/\Adata:image\/png;base64,(.+)\z/m)
    return nil unless match

    dir = Rails.root.join("tmp", "heatmap_uploads")
    FileUtils.mkdir_p(dir)
    path = dir.join("#{dashboard.id}.png")
    File.binwrite(path, Base64.decode64(match[1]))
    path.to_s
  rescue => e
    Rails.logger.warn("Failed to persist heatmap snapshot: #{e.message}")
    nil
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
