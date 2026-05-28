# app/controllers/predictions_controller.rb
class PredictionsController < ApplicationController
  before_action :set_dashboard
  before_action :set_survival_analysis

  def new
    @result = nil
  end

  def create
    @clinical = {
      age:    params[:age],
      gender: params[:gender],
      stage:  params[:stage]
    }

    tsv_file = params[:expression_file]
    if tsv_file.blank?
      flash.now[:alert] = t("predictions.errors.missing_file")
      return render :new, status: :unprocessable_entity
    end

    tsv_content = read_tsv(tsv_file)

    @result = PatientPredictor.new(
      @analysis,
      clinical:       @clinical,
      expression_tsv: tsv_content
    ).call

    render :new
  rescue PatientPredictor::InvalidInput => e
    flash.now[:alert] = e.message
    render :new, status: :unprocessable_entity
  end

  private

  def set_dashboard
    @dashboard = current_user.dashboards.find(params[:dashboard_id])
  end

  # Если в URL/форме передан analysis_id — используем именно его, чтобы прогноз
  # был привязан к конкретной обученной модели. Иначе — последний готовый.
  def set_survival_analysis
    scope = @dashboard.analyses.where(algorithm: "survival", status: "ready")

    @analysis =
      if params[:analysis_id].present?
        scope.find_by(id: params[:analysis_id])
      else
        scope.order(created_at: :desc).first
      end

    unless @analysis
      redirect_to dashboard_analyses_path(@dashboard),
                  alert: t("predictions.errors.no_model")
    end
  end

  # Читает содержимое TSV. Поддерживаем как обычный .tsv, так и .tsv.gz.
  # Битый gzip превращаем в InvalidInput, чтобы пользователь увидел понятное сообщение.
  def read_tsv(uploaded)
    raw = uploaded.read
    return raw unless uploaded.original_filename.to_s.end_with?(".gz")

    Zlib::GzipReader.new(StringIO.new(raw)).read
  rescue Zlib::Error => e
    raise PatientPredictor::InvalidInput, t("predictions.errors.bad_gzip", message: e.message)
  end
end
