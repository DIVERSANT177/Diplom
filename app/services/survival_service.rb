# app/services/survival_service.rb
class SurvivalService
  MIN_CASES  = 30
  TRAIN_RATIO = 0.8
  RANDOM_SEED = 42

  def initialize(analysis)
    @analysis    = analysis
    @dashboard   = analysis.dashboard
    @n_top_genes = analysis.n_top_genes
  end

  def call
    top_genes = fetch_top_genes
    raise "Сначала запустите Feature Importance" if top_genes.empty?

    patients = fetch_patients
    raise "Недостаточно данных: нужно минимум #{MIN_CASES} пациентов" if patients.length < MIN_CASES

    expressions = fetch_expressions(top_genes, patients.map { |p| p[:case_id] })

    train_patients, test_patients = train_test_split(patients)

    # Нормализация считается ТОЛЬКО по train — чтобы test был честным
    stats         = compute_normalization_stats(train_patients, top_genes, expressions)
    feature_names = build_feature_names(top_genes)

    x_train = build_x_matrix(train_patients, top_genes, expressions, stats)
    x_test  = build_x_matrix(test_patients,  top_genes, expressions, stats)

    model_type = @analysis.model_type
    train_result =
      if model_type == "cox"
        train_cox(x_train, x_test, train_patients, test_patients)
      else
        train_ridge(x_train, x_test, train_patients, test_patients)
      end

    c_index_train = concordance_index(train_result[:c_index_input_train], train_patients)
    c_index_test  = concordance_index(train_result[:c_index_input_test],  test_patients)

    feature_stds   = column_stds(x_train)
    coefficients   = build_coefficients(train_result[:weights], feature_names, feature_stds, model_type)
    predictions    = build_predictions(train_result[:predicted_days_train],
                                       train_result[:predicted_days_test],
                                       train_patients, test_patients)
    survival_curve = build_population_survival_curve(patients)
    cluster_curves = build_cluster_survival_curves(patients)

    times = patients.filter_map { |p| survival_time(p) }

    artifacts = stats.merge(
      "model_type"         => model_type,
      "feature_order"      => feature_names,
      "stage_names"        => stage_names,
      "gene_order"         => top_genes,
      "weights"            => train_result[:weights].map { |w| w.round(8) },
      "bias"               => train_result[:bias],
      "baseline_survival"  => train_result[:baseline_survival],
      "min_observed_time"  => times.min&.round(1),
      "max_observed_time"  => times.max&.round(1)
    )

    {
      "algorithm"        => "survival",
      "model_type"       => model_type,
      "n_cases"          => patients.length,
      "n_train"          => train_patients.length,
      "n_test"           => test_patients.length,
      "n_events_train"   => train_patients.count { |p| dead?(p) },
      "n_events_test"    => test_patients.count  { |p| dead?(p) },
      "c_index"          => c_index_test || c_index_train, # для совместимости
      "c_index_train"    => c_index_train,
      "c_index_test"     => c_index_test,
      "feature_names"    => feature_names,
      "coefficients"     => coefficients,
      "predictions"      => predictions,
      "survival_curve"   => survival_curve,
      "cluster_curves"   => cluster_curves,
      "training_info"    => train_result[:info],
      "model_artifacts"  => artifacts
    }
  end

  private

  # Берём топ-гены из последнего feature_importance, обрезаем до n_top_genes
  def fetch_top_genes
    fi_analysis = @dashboard.analyses
      .where(algorithm: "feature_importance", status: "ready")
      .order(created_at: :desc)
      .first

    return [] unless fi_analysis

    fi_analysis.result
      .fetch("top_genes", [])
      .first(@n_top_genes)
      .map { |g| g["gene"] }
  end

  def fetch_patients
    cases = Case
      .where(dashboard_id: @dashboard.id)
      .where.not(vital_status: [ nil, "" ])
      .pluck(:case_id, :gender, :age_at_index, :tumor_stage,
             :vital_status, :days_to_death, :days_to_last_follow_up)
      .map do |row|
        {
          case_id:                row[0],
          gender:                 row[1],
          age_at_index:           row[2],
          tumor_stage:            row[3],
          vital_status:           row[4],
          days_to_death:          row[5],
          days_to_last_follow_up: row[6]
        }
      end

    cluster_map = fetch_cluster_map
    cases.each { |p| p[:cluster] = cluster_map[p[:case_id]] }

    cases.select { |p| survival_time(p) }
  end

  def fetch_cluster_map
    clustering = @dashboard.analyses
      .where(algorithm: "clustering", status: "ready")
      .order(created_at: :desc)
      .first

    return {} unless clustering

    clustering.result
      .fetch("patient_clusters", [])
      .each_with_object({}) { |p, h| h[p["case_id"]] = p["cluster"] }
  end

  # Загружаем экспрессию топ-генов по всем пациентам
  # Возвращаем: { case_id => { gene_name => tpm } }
  def fetch_expressions(top_genes, case_ids)
    rows = GeneExpression
      .where(dashboard_id: @dashboard.id, case_id: case_ids, gene_name: top_genes)
      .pluck(:case_id, :gene_name, :tpm)

    by_case = Hash.new { |h, k| h[k] = {} }
    rows.each { |case_id, gene_name, tpm| by_case[case_id][gene_name] = tpm }
    by_case
  end

  # Стратифицированно делим по vital_status, чтобы в train и test
  # было похожее соотношение живых и умерших
  def train_test_split(patients)
    rng = Random.new(RANDOM_SEED)
    dead  = patients.select { |p| dead?(p) }.shuffle(random: rng)
    alive = patients.reject { |p| dead?(p) }.shuffle(random: rng)

    split_dead  = (dead.length  * TRAIN_RATIO).round
    split_alive = (alive.length * TRAIN_RATIO).round

    train = dead.first(split_dead) + alive.first(split_alive)
    test  = dead.drop(split_dead)  + alive.drop(split_alive)
    [ train.shuffle(random: rng), test.shuffle(random: rng) ]
  end

  # Считаем mean/std для возраста и каждого гена — по train-выборке.
  # Экспрессия логарифмируется (log1p), поскольку TPM сильно скошен.
  def compute_normalization_stats(train_patients, top_genes, expressions)
    ages = train_patients.map { |p| p[:age_at_index].to_f }
    age_mean, age_std = mean_std(ages)

    gene_means = {}
    gene_stds  = {}
    top_genes.each do |gene|
      # Статистики считаем только по наблюдаемым значениям — симметрично
      # с инференсом, где пропущенные гены подставляются mean-импутацией.
      values = train_patients.filter_map { |p|
        tpm = expressions[p[:case_id]][gene]
        tpm && Math.log(1.0 + tpm)
      }
      mean, std = mean_std(values)
      gene_means[gene] = mean.round(6)
      gene_stds[gene]  = std.round(6)
    end

    {
      "age_mean"      => age_mean.round(6),
      "age_std"       => age_std.round(6),
      "gene_means"    => gene_means,
      "gene_stds"     => gene_stds,
      "feature_scale" => "log1p_tpm"
    }
  end

  def build_feature_names(top_genes)
    [ "age_normalized", "is_male", *stage_names, *top_genes.map { |g| "gene:#{g}" } ]
  end

  # Строит матрицу X (без y — y зависит от модели).
  def build_x_matrix(patients, top_genes, expressions, stats)
    return Numo::DFloat.zeros(0, 0) if patients.empty?

    age_mean = stats["age_mean"]
    age_std  = stats["age_std"]
    gene_means = stats["gene_means"]
    gene_stds  = stats["gene_stds"]

    rows = patients.map do |p|
      age_norm = age_std > 0 ? (p[:age_at_index].to_f - age_mean) / age_std : 0.0
      is_male  = p[:gender]&.downcase == "male" ? 1.0 : 0.0
      stages   = encode_stage(p[:tumor_stage])

      gene_vals = top_genes.map do |gene|
        tpm = expressions[p[:case_id]][gene]
        if tpm.nil?
          0.0  # mean-imputation: стандартизованный 0 == нейтраль
        else
          std = gene_stds[gene]
          std > 0 ? (Math.log(1.0 + tpm) - gene_means[gene]) / std : 0.0
        end
      end

      [ age_norm, is_male, *stages, *gene_vals ]
    end

    Numo::DFloat[*rows]
  end

  # --- Обучение моделей ---

  def train_ridge(x_train, x_test, train_patients, test_patients)
    y_train = Numo::DFloat[*train_patients.map { |p| Math.log([ survival_time(p), 1 ].max) }]

    model = Rumale::LinearModel::Ridge.new(reg_param: @analysis.reg_param, solver: "lbfgs")
    model.fit(x_train, y_train)

    pred_log_train = model.predict(x_train).to_a
    pred_log_test  = test_patients.empty? ? [] : model.predict(x_test).to_a

    {
      weights:                model.weight_vec.to_a,
      bias:                   model.bias_term.to_f.round(8),
      baseline_survival:      nil,
      # Для Ridge: log(time) — меньшее значение значит более короткое время. Это
      # ровно то, что ожидает concordance_index (см. order_score).
      c_index_input_train:    pred_log_train,
      c_index_input_test:     pred_log_test,
      predicted_days_train:   pred_log_train.map { |v| Math.exp(v).round(1) },
      predicted_days_test:    pred_log_test.map  { |v| Math.exp(v).round(1) },
      info:                   { "type" => "ridge", "reg_param" => @analysis.reg_param }
    }
  end

  def train_cox(x_train, x_test, train_patients, test_patients)
    times_train  = train_patients.map { |p| survival_time(p).to_f }
    events_train = train_patients.map { |p| dead?(p) ? 1 : 0 }

    cox = CoxRegressor.new(reg_param: @analysis.reg_param)
    cox.fit(x_train, times_train, events_train)

    risk_train = cox.predict_risk(x_train)
    risk_test  = test_patients.empty? ? [] : cox.predict_risk(x_test)

    {
      weights:                cox.weights.to_a,
      bias:                   nil, # у Cox нет свободного члена
      baseline_survival:      cox.baseline_survival,
      # Для Cox: больший risk = более короткое время. concordance_index ждёт
      # обратной семантики ("меньшее = короче"), поэтому передаём -risk.
      c_index_input_train:    risk_train.map { |r| -r },
      c_index_input_test:     risk_test.map  { |r| -r },
      predicted_days_train:   risk_train.map { |r| cox.median_survival_for(r).round(1) },
      predicted_days_test:    risk_test.map  { |r| cox.median_survival_for(r).round(1) },
      info:                   {
        "type"       => "cox",
        "reg_param"  => @analysis.reg_param,
        "n_iter"     => cox.n_iter,
        "converged"  => cox.converged,
        "final_loss" => cox.final_loss&.round(4)
      }
    }
  end

  def mean_std(values)
    return [ 0.0, 0.0 ] if values.empty?
    mean = values.sum / values.length
    std  = Math.sqrt(values.sum { |v| (v - mean)**2 } / values.length)
    [ mean, std ]
  end

  # Приводит сырое значение стадии (как из GDC: "Stage IIA", "not reported", ...,
  # так и из формы: "stage_i", "unknown") к одному из stage_names или "unknown".
  # Используется и при обучении, и при инференсе — чтобы кодировка была симметричной.
  def self.normalize_stage(raw)
    s = raw.to_s.downcase
    return "stage_iv"  if s.include?("iv")
    return "stage_iii" if s.include?("iii")
    return "stage_ii"  if s.include?("ii")
    return "stage_i"   if s.include?("i")
    "unknown"
  end

  def encode_stage(raw_stage)
    normalized = self.class.normalize_stage(raw_stage)
    stage_names.map { |s| s == normalized ? 1.0 : 0.0 }
  end

  def stage_names = [ "stage_i", "stage_ii", "stage_iii", "stage_iv" ]

  # --- Построение результатов ---

  def build_coefficients(weights, feature_names, feature_stds, model_type)
    # Знак коэффициента в Ridge и Cox интерпретируется в противоположных направлениях:
    #   Ridge на log(time): coef > 0 → больше времени → protective.
    #   Cox: coef = log hazard ratio → coef > 0 → выше риск → risk.
    protective_when_positive = (model_type != "cox")

    feature_names.each_with_index.map do |name, i|
      raw  = weights[i]
      std  = feature_stds[i] || 0.0
      # Стандартизированный коэффициент = raw × std признака —
      # ставит бинарные и непрерывные признаки в один масштаб.
      std_coef = raw * std
      protective = protective_when_positive ? raw > 0 : raw < 0
      {
        "feature"                  => name,
        "coefficient"              => raw.round(6),
        "standardized_coefficient" => std_coef.round(6),
        "feature_std"              => std.round(6),
        "hazard_ratio"             => model_type == "cox" ? Math.exp(raw).round(4) : nil,
        "direction"                => protective ? "protective" : "risk"
      }
    end.sort_by { |c|
      # У Cox признаки уже стандартизованы → raw coef = log HR per 1 SD,
      # это и есть «эффект на той же шкале». У Ridge на log(time) масштаб
      # разный для бинарных/непрерывных, поэтому сортируем по standardized.
      -(model_type == "cox" ? c["coefficient"] : c["standardized_coefficient"]).abs
    }
  end

  # std по каждой колонке матрицы (популяционное std по train)
  def column_stds(x)
    return [] if x.shape[0].zero?
    (0...x.shape[1]).map { |j| x[true, j].to_a.then { |v| mean_std(v)[1] } }
  end

  def build_predictions(predicted_days_train, predicted_days_test, train_patients, test_patients)
    train_rows = train_patients.each_with_index.map do |p, i|
      prediction_row(p, predicted_days_train[i], "train")
    end
    test_rows = test_patients.each_with_index.map do |p, i|
      prediction_row(p, predicted_days_test[i], "test")
    end
    train_rows + test_rows
  end

  def prediction_row(p, predicted_days, split)
    {
      "case_id"        => p[:case_id],
      "split"          => split,
      "predicted_days" => predicted_days,
      "actual_days"    => survival_time(p)&.round(1),
      "vital_status"   => p[:vital_status],
      "cluster"        => p[:cluster]
    }
  end

  # Harrell's C-index: доля правильно упорядоченных пар пациентов.
  # 0.5 = случайно, 1.0 = идеально. В медицине 0.6-0.7 считается приемлемым.
  # Пара сравнима, если у пациента с меньшим временем наблюдения произошло событие.
  # На вход — ранжирующий скор: меньшее значение должно соответствовать более
  # короткой выживаемости (для Ridge — log(time), для Cox — −risk).
  def concordance_index(predicted_scores, patients)
    n = patients.length
    return nil if n < 2

    comparable = 0
    concordant = 0.0

    (0...n).each do |i|
      ti = survival_time(patients[i])
      di = dead?(patients[i])
      pi = predicted_scores[i]

      ((i + 1)...n).each do |j|
        tj = survival_time(patients[j])
        dj = dead?(patients[j])
        pj = predicted_scores[j]

        if ti < tj && di
          comparable += 1
          concordant += order_score(pi, pj)
        elsif tj < ti && dj
          comparable += 1
          concordant += order_score(pj, pi)
        elsif ti == tj && (di || dj)
          comparable += 1
          concordant += 0.5
        end
      end
    end

    comparable.zero? ? nil : (concordant / comparable).round(4)
  end

  def order_score(earlier_pred, later_pred)
    return 1.0 if earlier_pred < later_pred
    return 0.5 if earlier_pred == later_pred
    0.0
  end

  def dead?(patient)
    patient[:vital_status]&.downcase == "dead"
  end

  def build_population_survival_curve(patients)
    kaplan_meier(patients)
  end

  def build_cluster_survival_curves(patients)
    clusters = patients.map { |p| p[:cluster] }.compact.uniq.sort
    return {} if clusters.empty?

    clusters.each_with_object({}) do |cluster_id, h|
      group = patients.select { |p| p[:cluster] == cluster_id }
      h[cluster_id.to_s] = kaplan_meier(group) if group.length >= 3
    end
  end

  # Стандартный Kaplan–Meier с агрегацией событий по времени:
  #   S(t) = ∏_{t_i ≤ t} (1 − d_i / n_i)
  # где d_i — все смерти в момент t_i, n_i — все наблюдаемые на t_i (с учётом цензурированных).
  # Цензуры на t_i не вкладываются в числитель, но уменьшают risk-set на следующем шаге.
  def kaplan_meier(patients)
    events = patients.filter_map do |p|
      t = survival_time(p)
      next unless t
      { time: t, died: dead?(p) }
    end.sort_by { |e| e[:time] }

    return [] if events.empty?

    n_at_risk = events.length
    survival  = 1.0
    curve     = [ { "time" => 0, "survival" => 1.0, "n_at_risk" => n_at_risk } ]

    events.group_by { |e| e[:time] }.each do |time, group|
      deaths_at_t = group.count { |e| e[:died] }
      n_before    = n_at_risk
      survival   *= (1.0 - deaths_at_t.to_f / n_before) if deaths_at_t.positive?
      n_at_risk  -= group.length
      curve << {
        "time"      => time,
        "survival"  => survival.round(6),
        "n_at_risk" => n_before
      }
    end

    curve
  end

  def survival_time(patient)
    patient[:days_to_death] || patient[:days_to_last_follow_up]
  end
end
