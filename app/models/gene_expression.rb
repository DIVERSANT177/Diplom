# app/models/gene_expression.rb
class GeneExpression < ApplicationRecord
  belongs_to :dashboard

  scope :for_project, ->(pid) { where(project_id: pid) }

  # Строит матрицу {genes: [], samples: [], matrix: [[...]], annotations: {}} для фронтенда
  # sample_limit / sample_offset — пагинация по сэмплам для быстрой загрузки
  def self.to_heatmap_matrix(cases_scope, top_n: 50, sample_limit: 100, sample_offset: 0)
    # Шаг 1: Топ-N генов по дисперсии через SQL (вместо загрузки всех записей)
    genes = top_genes_by_variance_sql(top_n)
    return empty_heatmap if genes.empty?

    # Шаг 2: Пагинированный набор сэмплов
    all_sample_ids = where(gene_name: genes)
                       .distinct
                       .order(:case_id)
                       .pluck(:case_id)

    sample_ids = all_sample_ids[sample_offset, sample_limit] || []
    return empty_heatmap if sample_ids.empty?

    # Шаг 3: Загружаем только нужные строки
    rows = where(gene_name: genes, case_id: sample_ids)
             .pluck(:case_id, :gene_name, :tpm)

    lookup = {}
    rows.each do |case_id, gene_name, tpm|
      lookup[[case_id, gene_name]] = tpm
    end

    # Шаг 4: Строим матрицу Z-score
    matrix = genes.map do |gene|
      values = sample_ids.map { |sid| lookup[[sid, gene]] || 0.0 }
      zscore(values)
    end

    # Шаг 5: Кластеризация (гены — обычно 50, быстро; сэмплы — макс 100-200)
    gene_order   = hierarchical_cluster(matrix)
    sample_order = hierarchical_cluster(matrix.transpose)

    ordered_samples = sample_order.map { |i| sample_ids[i] }

    # Шаг 6: Клинические аннотации
    clinical = cases_scope.where(case_id: ordered_samples).index_by(&:case_id)

    annotations = ordered_samples.map do |case_id|
      c = clinical[case_id]
      {
        case_id:      case_id,
        gender:       c&.gender       || "unknown",
        vital_status: c&.vital_status || "unknown",
        tumor_stage:  c&.tumor_stage  || "unknown"
      }
    end

    {
      genes:       gene_order.map { |i| genes[i] },
      samples:     ordered_samples,
      matrix:      gene_order.map { |gi| sample_order.map { |si| matrix[gi][si] } },
      annotations: annotations
    }
  end

  private

  def self.empty_heatmap
    { genes: [], samples: [], matrix: [], annotations: [] }
  end

  # Расчёт дисперсии через SQL — не грузит все записи в память
  def self.top_genes_by_variance_sql(top_n)
    select("gene_name, VAR_SAMP(tpm) AS variance")
      .group(:gene_name)
      .order(Arel.sql("VAR_SAMP(tpm) DESC NULLS LAST"))
      .limit(top_n)
      .pluck(:gene_name)
  end

  def self.zscore(values)
    mean = values.sum / values.size.to_f
    std  = Math.sqrt(values.sum { |v| (v - mean)**2 } / values.size.to_f)
    return values.map { 0.0 } if std == 0
    values.map { |v| ((v - mean) / std).round(4) }
  end

  # Иерархическая кластеризация, возвращает упорядоченные индексы
  def self.hierarchical_cluster(matrix)
    n = matrix.size
    return [0] if n <= 1

    # Считаем попарные расстояния (1 - корреляция Пирсона)
    distances = Array.new(n) { Array.new(n, 0.0) }
    (0...n).each do |i|
      (i + 1...n).each do |j|
        d = correlation_distance(matrix[i], matrix[j])
        distances[i][j] = d
        distances[j][i] = d
      end
    end

    # Кластеризация методом complete linkage
    clusters = (0...n).map { |i| [i] }

    until clusters.size == 1
      min_dist = Float::INFINITY
      merge_a  = 0
      merge_b  = 1

      (0...clusters.size).each do |a|
        (a + 1...clusters.size).each do |b|
          dist = clusters[a].product(clusters[b]).map { |i, j| distances[i][j] }.max
          if dist < min_dist
            min_dist = dist
            merge_a  = a
            merge_b  = b
          end
        end
      end

      merged = clusters[merge_a] + clusters[merge_b]
      clusters.delete_at(merge_b)
      clusters.delete_at(merge_a)
      clusters << merged
    end

    clusters.first
  end

  def self.correlation_distance(a, b)
    n      = a.size.to_f
    mean_a = a.sum / n
    mean_b = b.sum / n

    num = a.zip(b).sum { |x, y| (x - mean_a) * (y - mean_b) }
    den = Math.sqrt(a.sum { |x| (x - mean_a)**2 } * b.sum { |y| (y - mean_b)**2 })

    return 1.0 if den == 0
    1.0 - (num / den)
  end
end
