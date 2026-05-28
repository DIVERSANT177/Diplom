# app/services/clustering_service.rb
class ClusteringService
  def initialize(analysis)
    @analysis    = analysis
    @dashboard   = analysis.dashboard
    @n_clusters  = analysis.n_clusters
    @n_top_genes = analysis.n_top_genes
  end

  def call
    top_genes = fetch_top_genes
    raise "Сначала запустите Feature Importance" if top_genes.empty?

    matrix, case_ids = build_matrix(top_genes)

    raise "Недостаточно данных: нужно минимум #{@n_clusters * 2} пациентов" if case_ids.length < @n_clusters * 2

    x = Numo::DFloat[*matrix]
    x = normalize(x)

    kmeans = Rumale::Clustering::KMeans.new(
      n_clusters:  @n_clusters,
      max_iter:    300,
      random_seed: 42
    )
    labels = kmeans.fit_predict(x).to_a  # [0, 1, 2, 0, 1, ...]

    # Считаем silhouette score — качество кластеризации (-1..1, чем выше тем лучше)
    silhouette = Rumale::EvaluationMeasure::SilhouetteScore.new
    score = silhouette.score(x, Numo::Int32[*labels]).round(4)

    # Собираем результат: для каждого пациента его кластер + клинические данные
    patient_clusters = build_patient_clusters(case_ids, labels)

    # Статистика по кластерам
    cluster_stats = build_cluster_stats(patient_clusters)

    {
      "algorithm"       => "clustering",
      "n_clusters"      => @n_clusters,
      "n_top_genes"     => top_genes.length,
      "n_cases"         => case_ids.length,
      "silhouette_score"=> score,
      "patient_clusters"=> patient_clusters,
      "cluster_stats"   => cluster_stats,
      "top_genes_used"  => top_genes
    }
  end

  private

  # Берём топ-гены из уже выполненного Feature Importance анализа
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

  def build_matrix(top_genes)
    expressions = GeneExpression
      .where(dashboard_id: @dashboard.id, gene_name: top_genes)
      .pluck(:case_id, :gene_name, :tpm)

    raise "Нет данных об экспрессии" if expressions.empty?

    by_case = Hash.new { |h, k| h[k] = {} }
    expressions.each do |case_id, gene_name, tpm|
      by_case[case_id][gene_name] = tpm
    end

    case_ids = by_case.keys.sort

    matrix = case_ids.map do |case_id|
      top_genes.map { |gene| by_case[case_id][gene] || 0.0 }
    end

    [ matrix, case_ids ]
  end

  # Z-score нормализация по каждому гену (колонке)
  def normalize(x)
    n_genes = x.shape[1]
    n_genes.times do |j|
      col  = x[true, j]
      mean = col.mean
      std  = col.stddev
      x[true, j] = std > 0 ? (col - mean) / std : col - mean
    end
    x
  end

  def build_patient_clusters(case_ids, labels)
    clinical = Case
      .where(dashboard_id: @dashboard.id, case_id: case_ids)
      .pluck(:case_id, :gender, :vital_status, :age_at_index,
             :days_to_death, :days_to_last_follow_up, :tumor_stage)
      .each_with_object({}) do |row, h|
        h[row[0]] = {
          gender:                row[1],
          vital_status:          row[2],
          age_at_index:          row[3],
          days_to_death:         row[4],
          days_to_last_follow_up: row[5],
          tumor_stage:           row[6]
        }
      end

    case_ids.each_with_index.map do |case_id, i|
      {
        "case_id"    => case_id,
        "cluster"    => labels[i],
        **clinical.fetch(case_id, {}).transform_keys(&:to_s)
      }
    end
  end

  def build_cluster_stats(patient_clusters)
    # Группируем пациентов по кластерам
    by_cluster = patient_clusters.group_by { |p| p["cluster"] }

    by_cluster.map do |cluster_id, patients|
      n_total = patients.length
      n_dead  = patients.count { |p| p["vital_status"]&.downcase == "dead" }
      ages    = patients.map { |p| p["age_at_index"] }.compact

      survival_times = patients.filter_map do |p|
        p["days_to_death"] || p["days_to_last_follow_up"]
      end

      {
        "cluster"          => cluster_id,
        "n_patients"       => n_total,
        "n_dead"           => n_dead,
        "mortality_rate"   => n_total > 0 ? (n_dead.to_f / n_total).round(4) : 0,
        "median_age"       => ages.empty? ? nil : median(ages).round(1),
        "median_survival"  => survival_times.empty? ? nil : median(survival_times).round(1)
      }
    end.sort_by { |s| s["cluster"] }
  end

  def median(arr)
    sorted = arr.sort
    mid    = sorted.length / 2
    sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end
end
