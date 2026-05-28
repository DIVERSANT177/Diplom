class GdcExpressionImporter
  # Сколько файлов запрашиваем в одном bulk HTTP-запросе к GDC
  BULK_BATCH_SIZE = 100
  # Сколько строк накапливаем перед insert_all
  INSERT_BATCH    = 5_000
  # Сколько топ-генов по дисперсии отбираем
  TOP_GENES       = 200

  CACHE_DIR = Rails.root.join("tmp", "expression_cache")

  def initialize(dashboard)
    @dashboard = dashboard
    @client    = GdcClient.new
  end

  def call
    @dashboard.update(expression_status: "fetching")

    # Запрашиваем ровно столько файлов, сколько есть пациентов
    file_count = [ @dashboard.cases.count, 1 ].max
    files = @client.expression_files(project_ids: @dashboard.projects, size: file_count)
    return error!("No expression files found") if files.empty?

    FileUtils.mkdir_p(CACHE_DIR)

    # Проход 1: Bulk-скачиваем файлы пачками по BULK_BATCH_SIZE,
    #           кэшируем в компактном формате { gene_id => [tpm, gene_name] }
    download_all_bulk(files)

    # Проход 2 (последовательный, быстрый): считаем online-дисперсию
    #           по компактному кэшу — алгоритм Welford
    gene_variance = compute_variance_welford(files)
    return error!("No expression data parsed") if gene_variance.empty?

    top_ids = gene_variance
      .sort_by { |_, var| -var }
      .first(TOP_GENES)
      .map(&:first)
      .to_set

    # Проход 3: импортируем топ-гены из кэша потоком
    @dashboard.gene_expressions.delete_all
    import_top_genes(files, top_ids)

    @dashboard.update(expression_status: "ready")
  rescue => e
    error!(e.message)
  ensure
    cleanup_cache(files || [])
  end

  private

  # ─── Bulk-загрузка ─────────────────────────────────────────────────────────

  def download_all_bulk(files)
    total = files.length
    done  = 0

    # Строим индекс: file_id => file_meta (нужен для case_id, project_id)
    @file_meta_index = files.each_with_object({}) { |f, h| h[f["file_id"]] = f }

    files.each_slice(BULK_BATCH_SIZE).each_with_index do |batch, batch_idx|
      # Фильтруем те, что уже есть в кэше
      missing = batch.reject { |f| File.exist?(cache_path_for(f["file_id"])) }

      unless missing.empty?
        file_ids = missing.map { |f| f["file_id"] }
        Rails.logger.info("Bulk download batch #{batch_idx + 1}: #{file_ids.length} files")

        parsed_bulk = @client.download_expression_files_bulk(file_ids)

        # Если bulk провалился — fallback на поштучную загрузку
        if parsed_bulk.empty? && file_ids.any?
          Rails.logger.warn("Bulk failed, falling back to individual downloads")
          parsed_bulk = download_individually(missing)
        end

        parsed_bulk.each do |file_id, rows|
          compact = rows.each_with_object({}) { |r, h| h[r[:gene_id]] = [ r[:tpm], r[:gene_name] ] }
          File.binwrite(cache_path_for(file_id), Marshal.dump(compact)) if compact.any?
        end
      end

      done += batch.length
      Rails.logger.info("Expression cache: #{done}/#{total} files ready")
    end
  end

  # Fallback: загружаем файлы параллельно по одному (BULK_BATCH_SIZE тредов)
  def download_individually(file_metas)
    results = {}
    mutex   = Mutex.new

    file_metas.each_slice(20) do |slice|
      threads = slice.map do |file_meta|
        Thread.new do
          file_id = file_meta["file_id"]
          rows    = begin
            @client.download_expression_file(file_id)
          rescue => e
            Rails.logger.warn("Skipping #{file_id}: #{e.message}")
            []
          end
          mutex.synchronize { results[file_id] = rows } if rows.any?
        end
      end
      threads.each(&:join)
    end

    results
  end

  # ─── Дисперсия по алгоритму Welford ────────────────────────────────────────
  # Однопроходный online-алгоритм: не нужно хранить все значения, только n/mean/M2

  def compute_variance_welford(files)
    # stats[gene_id] = [count, mean, M2]
    stats = Hash.new { |h, k| h[k] = [ 0, 0.0, 0.0 ] }

    files.each do |file_meta|
      compact = load_compact_cache(file_meta["file_id"])
      next if compact.empty?

      compact.each do |gene_id, (tpm, _)|
        n, mean, m2 = stats[gene_id]
        n    += 1
        delta = tpm - mean
        mean += delta / n
        m2   += delta * (tpm - mean)   # delta_after уже с новым mean
        stats[gene_id] = [ n, mean, m2 ]
      end
    end

    # Выборочная дисперсия: M2 / (n-1)
    stats.transform_values { |n, _, m2| n > 1 ? m2 / (n - 1) : 0.0 }
  end

  # ─── Импорт топ-генов ───────────────────────────────────────────────────────

  def import_top_genes(files, top_ids)
    now    = Time.current
    buffer = []

    files.each do |file_meta|
      compact    = load_compact_cache(file_meta["file_id"])
      next if compact.empty?

      case_id    = file_meta.dig("cases", 0, "case_id")
      project_id = file_meta.dig("cases", 0, "project", "project_id")
      next unless case_id

      compact.each do |gene_id, (tpm, gene_name)|
        next unless top_ids.include?(gene_id)

        buffer << {
          dashboard_id: @dashboard.id,
          case_id:      case_id,
          gene_id:      gene_id,
          gene_name:    gene_name,
          tpm:          tpm,
          project_id:   project_id,
          created_at:   now,
          updated_at:   now
        }

        if buffer.size >= INSERT_BATCH
          GeneExpression.insert_all(buffer)
          buffer.clear
        end
      end
    end

    GeneExpression.insert_all(buffer) if buffer.any?
  end

  # ─── Кэш ────────────────────────────────────────────────────────────────────

  def load_compact_cache(file_id)
    path = cache_path_for(file_id)
    return {} unless File.exist?(path)
    Marshal.load(File.binread(path))
  rescue => e
    Rails.logger.warn("Cache read error #{file_id}: #{e.message}")
    {}
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
