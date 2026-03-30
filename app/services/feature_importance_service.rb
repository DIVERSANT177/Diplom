# app/services/feature_importance_service.rb
class FeatureImportanceService
  def initialize(analysis)
    @analysis    = analysis
    @dashboard   = analysis.dashboard
    @n_top_genes = analysis.n_top_genes
    @n_trees     = analysis.n_trees
  end

  def call
    matrix, gene_names, case_ids = build_matrix
    labels = build_labels(case_ids)

    raise "Недостаточно данных: нужно минимум 10 пациентов" if case_ids.length < 10

    x = Numo::DFloat[*matrix]             # shape: [n_cases, n_genes]
    y = Numo::Int32[*labels]              # shape: [n_cases]

    forest = Rumale::Ensemble::RandomForestClassifier.new(
      n_estimators: @n_trees,
      max_features:  :sqrt,
      random_seed:   42
    )
    forest.fit(x, y)

    importances = forest.feature_importances.to_a

    # Сортируем гены по важности
    ranked = gene_names
      .each_with_index
      .map { |gene, i| { gene: gene, importance: importances[i].round(6) } }
      .sort_by { |g| -g[:importance] }

    top_genes = ranked.first(@n_top_genes)

    {
      "algorithm"    => "feature_importance",
      "n_trees"      => @n_trees,
      "n_cases"      => case_ids.length,
      "n_genes_total"=> gene_names.length,
      "top_genes"    => top_genes,
      "all_genes"    => ranked
    }
  end

  private

  def build_matrix
    top_gene_names = GeneExpression
    .where(dashboard_id: @dashboard.id)
    .group(:gene_name)
    .order("AVG(tpm) DESC")
    .limit(@dashboard.top_genes_count * 10)
    .pluck(:gene_name)

    expressions = GeneExpression
      .where(dashboard_id: @dashboard.id, gene_name: top_gene_names)
      .pluck(:case_id, :gene_name, :tpm)

    raise "Нет данных об экспрессии" if expressions.empty?

    # Строим хэш: { case_id => { gene_name => tpm } }
    by_case = Hash.new { |h, k| h[k] = {} }
    expressions.each do |case_id, gene_name, tpm|
      by_case[case_id][gene_name] = tpm
    end

    case_ids  = by_case.keys.sort
    gene_names = expressions.map { |_, gene, _| gene }.uniq.sort

    # Строим матрицу [n_cases × n_genes], пропуски заполняем 0.0
    matrix = case_ids.map do |case_id|
      gene_names.map { |gene| by_case[case_id][gene] || 0.0 }
    end

    [ matrix, gene_names, case_ids ]
  end

  def build_labels(case_ids)
    # y = 1 если пациент умер, 0 если жив / не сообщается
    vital = Case
      .where(dashboard_id: @dashboard.id, case_id: case_ids)
      .pluck(:case_id, :vital_status)
      .to_h

    case_ids.map do |case_id|
      vital[case_id]&.downcase == "dead" ? 1 : 0
    end
  end
end
