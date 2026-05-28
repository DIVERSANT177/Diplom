# app/services/patient_predictor.rb
#
# Применяет уже обученную survival-модель к данным одного пациента.
# Использует "model_artifacts" из result survival-анализа.
class PatientPredictor
  class InvalidInput < StandardError; end

  VALID_GENDERS = %w[male female].freeze
  VALID_STAGES  = %w[stage_i stage_ii stage_iii stage_iv unknown].freeze
  AGE_RANGE     = (0..120).freeze

  def initialize(analysis, clinical:, expression_tsv:)
    @analysis       = analysis
    @clinical       = clinical
    @expression_tsv = expression_tsv
  end

  def call
    artifacts = @analysis.result["model_artifacts"]
    raise InvalidInput, "Модель не содержит артефактов — пересоздайте survival-анализ" if artifacts.blank?

    validate_clinical!
    validate_feature_order!(artifacts)

    parsed_genes = parse_tsv(@expression_tsv)
    raise InvalidInput, "Не удалось разобрать TSV-файл" if parsed_genes.empty?

    expression_map = parsed_genes.to_h { |row| [ row[:gene_name].to_s.upcase, row[:tpm] ] }

    features, gene_coverage = build_feature_vector(artifacts, expression_map)

    # Старые модели не сохраняли model_type — для совместимости считаем их Ridge.
    model_type = artifacts["model_type"] || "ridge"
    linear     = apply_linear_model(artifacts, features, with_bias: model_type != "cox")
    predicted_days, risk_score = decode_prediction(linear, model_type, artifacts)

    min_t = artifacts["min_observed_time"]
    max_t = artifacts["max_observed_time"]
    out_of_range =
      (min_t && predicted_days < min_t) ||
      (max_t && predicted_days > max_t) || false

    base = {
      "predicted_days"     => predicted_days.round(1),
      "predicted_years"    => (predicted_days / 365.25).round(2),
      "model_type"         => model_type,
      "risk_score"         => risk_score&.round(4),
      "out_of_range"       => out_of_range,
      "min_observed_time"  => min_t,
      "max_observed_time"  => max_t,
      "gene_coverage"      => gene_coverage,
      "clinical"           => @clinical,
      "feature_vector"     => features.each_with_index.map { |v, i|
        { "feature" => artifacts["feature_order"][i], "value" => v.round(4) }
      }
    }

    if model_type == "cox"
      baseline = artifacts["baseline_survival"] || []
      unless baseline.empty?
        patient_curve = build_patient_survival_curve(risk_score, baseline)
        base["patient_survival_curve"] = patient_curve
        base["survival_at_milestones"] = build_milestones(patient_curve)
      end
    end

    base
  end

  private

  def validate_clinical!
    age = @clinical[:age].to_s.strip
    raise InvalidInput, "Некорректный возраст" unless age.match?(/\A\d+\z/) && AGE_RANGE.cover?(age.to_i)

    gender = @clinical[:gender].to_s.downcase
    raise InvalidInput, "Некорректный пол" unless VALID_GENDERS.include?(gender)

    stage = @clinical[:stage].to_s.downcase
    raise InvalidInput, "Некорректная стадия" unless VALID_STAGES.include?(stage)
  end

  # Проверяем, что порядок признаков, который мы построим, в точности совпадает
  # с порядком на момент обучения. Это страхует от ситуации, когда длина вектора
  # совпала случайно (например, изменился набор top-genes).
  def validate_feature_order!(artifacts)
    expected = artifacts["feature_order"]
    actual   = [
      "age_normalized",
      "is_male",
      *artifacts["stage_names"],
      *artifacts["gene_order"].map { |g| "gene:#{g}" }
    ]
    return if expected == actual

    raise InvalidInput, "Структура признаков модели не совпадает с ожидаемой — пересоздайте survival-анализ"
  end

  def parse_tsv(content)
    GdcClient.new.parse_expression_tsv(content.to_s)
  end

  # Собирает вектор признаков в том же порядке, что и при обучении.
  def build_feature_vector(artifacts, expression_map)
    age       = @clinical[:age].to_f
    gender    = @clinical[:gender].to_s.downcase
    stage     = SurvivalService.normalize_stage(@clinical[:stage])

    age_mean  = artifacts["age_mean"].to_f
    age_std   = artifacts["age_std"].to_f
    age_norm  = age_std > 0 ? (age - age_mean) / age_std : 0.0
    is_male   = gender == "male" ? 1.0 : 0.0

    stages = artifacts["stage_names"].map { |s| s == stage ? 1.0 : 0.0 }

    gene_order = artifacts["gene_order"]
    gene_means = artifacts["gene_means"]
    gene_stds  = artifacts["gene_stds"]
    # "log1p_tpm" — новые модели, "raw_tpm" — старые (до добавления log-трансформации)
    log_scale  = artifacts["feature_scale"] == "log1p_tpm"

    found_genes = []
    missing_genes = []

    gene_features = gene_order.map do |gene|
      tpm = expression_map[gene.to_s.upcase]
      if tpm
        found_genes << gene
        value = log_scale ? Math.log(1.0 + tpm) : tpm
        mean = gene_means[gene].to_f
        std  = gene_stds[gene].to_f
        std > 0 ? (value - mean) / std : 0.0
      else
        missing_genes << gene
        0.0  # mean-imputation: после стандартизации 0 == нейтральное значение
      end
    end

    features = [ age_norm, is_male, *stages, *gene_features ]

    coverage = {
      "total"   => gene_order.length,
      "found"   => found_genes.length,
      "missing" => missing_genes
    }

    [ features, coverage ]
  end

  def apply_linear_model(artifacts, features, with_bias:)
    weights = artifacts["weights"]
    bias    = with_bias ? artifacts["bias"].to_f : 0.0

    raise InvalidInput, "Размер вектора (#{features.length}) не совпадает с моделью (#{weights.length})" if features.length != weights.length

    dot = features.each_with_index.sum { |v, i| v * weights[i] }
    dot + bias
  end

  # Для Ridge: linear = log(time) → exp.
  # Для Cox: linear = β·x = risk score → ищем медиану выживаемости по baseline_survival.
  def decode_prediction(linear, model_type, artifacts)
    if model_type == "cox"
      baseline = artifacts["baseline_survival"] || []
      raise InvalidInput, "Модель Cox без baseline_survival — пересоздайте анализ" if baseline.empty?

      median = median_survival_from_baseline(linear, baseline)
      [ median, linear ]
    else
      [ Math.exp(linear), nil ]
    end
  end

  # S(t|x) = S₀(t)^exp(risk). Ищем наименьшее t, где S(t|x) ≤ 0.5.
  def median_survival_from_baseline(risk, baseline)
    er = Math.exp(risk.clamp(-50.0, 50.0))
    baseline.each do |pt|
      s0 = pt["s0"] || pt[:s0]
      t  = pt["time"] || pt[:time]
      next if s0.nil? || t.nil?
      s_x = [ s0, 1e-12 ].max**er
      return t if s_x <= 0.5
    end
    last = baseline.last
    last["time"] || last[:time] || 0.0
  end

  # Индивидуальная кривая выживаемости: для каждой точки baseline считаем
  # S(t|x) = S₀(t)^exp(risk).
  def build_patient_survival_curve(risk, baseline)
    er = Math.exp(risk.clamp(-50.0, 50.0))
    baseline.map do |pt|
      s0 = (pt["s0"] || pt[:s0]).to_f
      t  = (pt["time"] || pt[:time]).to_f
      s_x = [ s0, 1e-12 ].max**er
      { "time" => t, "s0" => s0.round(6), "s_patient" => s_x.round(6) }
    end
  end

  # Прогноз выживаемости на ключевые сроки (1, 3, 5, 10 лет) — удобная сводка.
  # Если максимальное наблюдаемое время короче указанного срока, точку пропускаем.
  def build_milestones(patient_curve)
    return [] if patient_curve.empty?
    max_t = patient_curve.last["time"]

    [ 365, 1095, 1825, 3650 ].select { |d| d <= max_t }.map do |days|
      # Step function: берём последнюю точку, где time ≤ days
      pt = patient_curve.reverse.find { |c| c["time"] <= days }
      next nil unless pt
      {
        "days"    => days,
        "years"   => (days / 365.0).round,
        "patient" => pt["s_patient"],
        "cohort"  => pt["s0"]
      }
    end.compact
  end
end
