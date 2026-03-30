# app/models/gene_expression.rb
class GeneExpression < ApplicationRecord
  belongs_to :dashboard

  scope :for_project, ->(pid) { where(project_id: pid) }

  # Строит матрицу {genes: [], samples: [], matrix: [[...]]} для фронтенда
  def self.to_heatmap_matrix(cases_scope, top_n: 50)
    rows = all.to_a

    genes   = rows.map(&:gene_name).uniq
    samples = rows.map(&:case_id).uniq

    # Фильтруем топ N генов по дисперсии TPM
    genes = top_genes_by_variance(rows, genes, top_n)

    # Подтягиваем клинические данные
    clinical = cases_scope.where(case_id: samples)
                          .index_by(&:case_id)

    lookup = rows.each_with_object({}) do |r, h|
      h[[ r.case_id, r.gene_name ]] = r.tpm
    end

    matrix = genes.map do |gene|
      values = samples.map { |sample| lookup[[ sample, gene ]] || 0.0 }
      zscore(values)
    end

    gene_order   = hierarchical_cluster(matrix)
    sample_order = hierarchical_cluster(matrix.transpose)

    ordered_samples = sample_order.map { |i| samples[i] }

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

  def self.top_genes_by_variance(rows, genes, top_n)
    return genes if top_n.nil? || top_n >= genes.size

    variances = genes.map do |gene|
      values = rows.select { |r| r.gene_name == gene }.map(&:tpm)
      mean = values.sum / values.size.to_f
      variance = values.sum { |v| (v - mean)**2 } / values.size.to_f
      [ gene, variance ]
    end

    variances.sort_by { |_, var| -var }.first(top_n).map(&:first)
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
    return [ 0 ] if n == 1

    # Считаем попарные расстояния (1 - корреляция Пирсона)
    distances = Array.new(n) { Array.new(n, 0.0) }
    (0...n).each do |i|
      (i+1...n).each do |j|
        d = correlation_distance(matrix[i], matrix[j])
        distances[i][j] = d
        distances[j][i] = d
      end
    end

    # Кластеризация методом complete linkage
    clusters = (0...n).map { |i| [ i ] }

    until clusters.size == 1
      min_dist = Float::INFINITY
      merge_a  = 0
      merge_b  = 1

      (0...clusters.size).each do |a|
        (a+1...clusters.size).each do |b|
          # Complete linkage: максимальное расстояние между элементами кластеров
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
    n    = a.size.to_f
    mean_a = a.sum / n
    mean_b = b.sum / n

    num  = a.zip(b).sum { |x, y| (x - mean_a) * (y - mean_b) }
    den  = Math.sqrt(a.sum { |x| (x - mean_a)**2 } * b.sum { |y| (y - mean_b)**2 })

    return 1.0 if den == 0
    1.0 - (num / den)
  end
end
