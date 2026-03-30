# app/services/survival_service.rb
class SurvivalService
  MIN_CASES = 15

  def initialize(analysis)
    @analysis    = analysis
    @dashboard   = analysis.dashboard
    @n_top_genes = analysis.n_top_genes
  end

  def call
    patients = fetch_patients
    raise "Недостаточно данных: нужно минимум #{MIN_CASES} пациентов" if patients.length < MIN_CASES

    x, y, case_ids, feature_names = build_features(patients)

    # Обучаем Ridge-регрессию на логарифме времени выживаемости (AFT-подход)
    model = Rumale::LinearModel::Ridge.new(reg_param: 0.1, random_seed: 42)
    model.fit(x, y)

    coefficients  = build_coefficients(model, feature_names)
    predictions   = build_predictions(model, x, case_ids, patients)
    survival_curve = build_population_survival_curve(patients)
    cluster_curves = build_cluster_survival_curves(patients)

    {
      "algorithm"        => "survival",
      "n_cases"          => patients.length,
      "feature_names"    => feature_names,
      "coefficients"     => coefficients,
      "predictions"      => predictions,
      "survival_curve"   => survival_curve,
      "cluster_curves"   => cluster_curves
    }
  end

  private

  def fetch_patients
    # Берём клинические данные
    cases = Case
      .where(dashboard_id: @dashboard.id)
      .where.not(vital_status: [ nil, "" ])
      .pluck(:case_id, :gender, :age_at_index, :tumor_stage,
             :vital_status, :days_to_death, :days_to_last_follow_up)
      .map do |row|
        {
          case_id:                 row[0],
          gender:                  row[1],
          age_at_index:            row[2],
          tumor_stage:             row[3],
          vital_status:            row[4],
          days_to_death:           row[5],
          days_to_last_follow_up:  row[6]
        }
      end

    # Добавляем кластер если кластеризация уже выполнена
    cluster_map = fetch_cluster_map
    cases.each do |p|
      p[:cluster] = cluster_map[p[:case_id]]
    end

    # Оставляем только пациентов у которых есть время наблюдения
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

  def build_features(patients)
    # Кодируем признаки в числовой вид
    genders      = encode_gender(patients)
    ages         = encode_age(patients)
    stages       = encode_stage(patients)
    clusters     = encode_cluster(patients)

    feature_names = [ "age_normalized", "is_male", *stage_names, *cluster_names(patients) ]

    matrix = patients.each_with_index.map do |p, i|
      [ ages[i], genders[i], *stages[i], *clusters[i] ]
    end

    # y = log(время выживаемости) — AFT-подход
    y_values = patients.map { |p| Math.log([ survival_time(p), 1 ].max) }

    x        = Numo::DFloat[*matrix]
    y        = Numo::DFloat[*y_values]
    case_ids = patients.map { |p| p[:case_id] }

    [ x, y, case_ids, feature_names ]
  end

  # --- Кодировщики признаков ---

  def encode_gender(patients)
    patients.map { |p| p[:gender]&.downcase == "male" ? 1.0 : 0.0 }
  end

  def encode_age(patients)
    ages = patients.map { |p| p[:age_at_index].to_f }
    mean = ages.sum / ages.length
    std  = Math.sqrt(ages.map { |a| (a - mean)**2 }.sum / ages.length)
    std > 0 ? ages.map { |a| (a - mean) / std } : ages.map { 0.0 }
  end

  def encode_stage(patients)
    # One-hot encoding стадий
    patients.map do |p|
      stage = p[:tumor_stage].to_s.downcase
      [
        stage.include?("i") && !stage.include?("ii") && !stage.include?("iv") ? 1.0 : 0.0,  # stage i
        stage.include?("ii") && !stage.include?("iii") && !stage.include?("iv") ? 1.0 : 0.0, # stage ii
        stage.include?("iii") && !stage.include?("iv") ? 1.0 : 0.0,                          # stage iii
        stage.include?("iv") ? 1.0 : 0.0                                                      # stage iv
      ]
    end
  end

  def encode_cluster(patients)
    clusters = patients.map { |p| p[:cluster] }.compact
    return patients.map { [] } if clusters.empty?

    max_cluster = clusters.max
    patients.map do |p|
      next Array.new(max_cluster + 1, 0.0) unless p[:cluster]
      one_hot = Array.new(max_cluster + 1, 0.0)
      one_hot[p[:cluster]] = 1.0
      one_hot
    end
  end

  def stage_names  = [ "stage_i", "stage_ii", "stage_iii", "stage_iv" ]

  def cluster_names(patients)
    clusters = patients.map { |p| p[:cluster] }.compact
    return [] if clusters.empty?
    (0..clusters.max).map { |i| "cluster_#{i}" }
  end

  # --- Построение результатов ---

  def build_coefficients(model, feature_names)
    weights = model.weight_vec.to_a
    feature_names.each_with_index.map do |name, i|
      {
        "feature"    => name,
        "coefficient"=> weights[i].round(6),
        # Положительный коэффициент = увеличивает предсказанное время жизни
        "direction"  => weights[i] > 0 ? "protective" : "risk"
      }
    end.sort_by { |c| -c["coefficient"].abs }
  end

  def build_predictions(model, x, case_ids, patients)
    predicted_log_times = model.predict(x).to_a

    case_ids.each_with_index.map do |case_id, i|
      p = patients[i]
      {
        "case_id"          => case_id,
        "predicted_days"   => Math.exp(predicted_log_times[i]).round(1),
        "actual_days"      => survival_time(p)&.round(1),
        "vital_status"     => p[:vital_status],
        "cluster"          => p[:cluster]
      }
    end
  end

  # Каплан-Мейер для всей популяции
  def build_population_survival_curve(patients)
    kaplan_meier(patients)
  end

  # Каплан-Мейер отдельно для каждого кластера
  def build_cluster_survival_curves(patients)
    clusters = patients.map { |p| p[:cluster] }.compact.uniq.sort
    return {} if clusters.empty?

    clusters.each_with_object({}) do |cluster_id, h|
      group = patients.select { |p| p[:cluster] == cluster_id }
      h[cluster_id.to_s] = kaplan_meier(group) if group.length >= 3
    end
  end

  # Стандартный алгоритм Каплана-Мейера
  def kaplan_meier(patients)
    events = patients.filter_map do |p|
      t = survival_time(p)
      next unless t
      { time: t, died: p[:vital_status]&.downcase == "dead" }
    end.sort_by { |e| e[:time] }

    return [] if events.empty?

    n_at_risk  = events.length
    survival   = 1.0
    curve      = [ { "time" => 0, "survival" => 1.0, "n_at_risk" => n_at_risk } ]
    prev_time  = nil

    events.each do |event|
      if event[:time] != prev_time && prev_time
        curve << {
          "time"      => prev_time,
          "survival"  => survival.round(6),
          "n_at_risk" => n_at_risk
        }
      end

      survival  *= (1.0 - (event[:died] ? 1.0 / n_at_risk : 0.0))
      n_at_risk -= 1
      prev_time  = event[:time]
    end

    curve << {
      "time"     => prev_time,
      "survival" => survival.round(6),
      "n_at_risk"=> n_at_risk
    }

    curve
  end

  def survival_time(patient)
    patient[:days_to_death] || patient[:days_to_last_follow_up]
  end
end
