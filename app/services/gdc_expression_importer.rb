class GdcExpressionImporter
  BATCH_SIZE   = 20
  TOP_GENES    = 200
  MAX_FILES    = 500
  THREADS      = 5   # параллельных запросов
  CACHE_DIR    = Rails.root.join("tmp", "expression_cache")

  def initialize(dashboard)
    @dashboard = dashboard
    @client    = GdcClient.new
  end

  def call
    @dashboard.update(expression_status: "fetching")

    files = @client.expression_files(project_ids: @dashboard.projects, size: MAX_FILES)
    return error!("No expression files found") if files.empty?

    FileUtils.mkdir_p(CACHE_DIR)

    # Проход 1: скачиваем файлы параллельно и кэшируем на диск
    download_all_parallel(files)

    # Проход 2: считаем дисперсию из кэша (быстро, диск)
    gene_variance = compute_gene_variance(files)
    return error!("No expression data parsed") if gene_variance.empty?

    top_ids = gene_variance
      .sort_by { |_, var| -var }
      .first(TOP_GENES)
      .map(&:first)
      .to_set

    # Проход 3: импортируем из кэша только топ-гены
    @dashboard.gene_expressions.delete_all
    import_top_genes(files, top_ids)

    @dashboard.update(expression_status: "ready")
  rescue => e
    error!(e.message)
  ensure
    cleanup_cache(files)
  end

  private

  def download_all_parallel(files)
    mutex = Mutex.new
    total = files.length
    done  = 0

    files.each_slice(BATCH_SIZE) do |batch|
      threads = batch.map do |file_meta|
        Thread.new do
          file_id    = file_meta["file_id"]
          cache_path = cache_path_for(file_id)

          unless File.exist?(cache_path)
            rows = fetch_rows(file_meta)
            # Сохраняем на диск как Marshal (быстрее JSON)
            File.binwrite(cache_path, Marshal.dump(rows)) if rows.any?
          end

          mutex.synchronize do
            done += 1
            Rails.logger.info("Expression download: #{done}/#{total}")
          end
        end
      end

      threads.each(&:join)
      GC.compact
    end
  end

  def compute_gene_variance(files)
    gene_stats = Hash.new { |h, k| h[k] = { n: 0, sum: 0.0, sum_sq: 0.0 } }

    files.each do |file_meta|
      rows = load_from_cache(file_meta["file_id"])
      next if rows.empty?

      rows.each do |row|
        s = gene_stats[row[:gene_id]]
        s[:n]      += 1
        s[:sum]    += row[:tpm]
        s[:sum_sq] += row[:tpm] ** 2
      end
    end

    gene_stats.transform_values do |s|
      next 0.0 if s[:n] == 0
      mean    = s[:sum] / s[:n]
      mean_sq = s[:sum_sq] / s[:n]
      mean_sq - mean ** 2
    end
  end

  def import_top_genes(files, top_ids)
    files.each_slice(BATCH_SIZE) do |batch|
      rows_to_insert = batch.flat_map do |file_meta|
        load_from_cache(file_meta["file_id"])
          .select { |r| top_ids.include?(r[:gene_id]) }
      end

      GeneExpression.insert_all(rows_to_insert) if rows_to_insert.any?
      GC.compact
    end
  end

  def fetch_rows(file_meta)
    file_id    = file_meta["file_id"]
    case_id    = file_meta.dig("cases", 0, "case_id")
    project_id = file_meta.dig("cases", 0, "project", "project_id")
    return [] if case_id.nil?

    @client.download_expression_file(file_id).map do |row|
      row.merge(
        case_id:      case_id,
        project_id:   project_id,
        dashboard_id: @dashboard.id,
        created_at:   Time.current,
        updated_at:   Time.current
      )
    end
  rescue => e
    Rails.logger.warn("Skipping file #{file_id}: #{e.message}")
    []
  end

  def load_from_cache(file_id)
    path = cache_path_for(file_id)
    return [] unless File.exist?(path)
    Marshal.load(File.binread(path))
  rescue => e
    Rails.logger.warn("Cache read failed for #{file_id}: #{e.message}")
    []
  end

  def cache_path_for(file_id)
    CACHE_DIR.join("#{@dashboard.id}_#{file_id}.marshal")
  end

  def cleanup_cache(files)
    files.each do |file_meta|
      path = cache_path_for(file_meta["file_id"])
      File.delete(path) if File.exist?(path)
    end
  end

  def error!(message)
    Rails.logger.error("ExpressionImport failed for dashboard #{@dashboard.id}: #{message}")
    @dashboard.update(expression_status: "error", expression_error: message)
  end
end
