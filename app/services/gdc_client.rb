require "zlib"
require "stringio"
require "minitar"

class GdcClient
  class ApiError < StandardError; end

  BASE_URL        = "https://api.gdc.cancer.gov"
  OPEN_TIMEOUT    = 30   # секунд на установку соединения
  READ_TIMEOUT    = 120  # секунд на чтение ответа
  BULK_READ_TIMEOUT = 600 # 10 минут для тяжёлых bulk-архивов

  def initialize
    @conn = Faraday.new(url: BASE_URL) do |f|
      f.request  :json
      f.response :json
      f.options.open_timeout = OPEN_TIMEOUT
      f.options.timeout      = READ_TIMEOUT
      f.adapter  Faraday.default_adapter
    end
  end

  def projects
    Rails.cache.fetch("gdc_projects", expires_in: 24.hours) do
      response = @conn.post("/projects", {
        filters: {
          op: "=",
          content: { field: "program.name", value: "TCGA" }
        },
        fields: "project_id,name,primary_site,summary.case_count",
        size: 100
      })
      extract_hits(response, endpoint: "/projects")
    end
  end

  def cases(project_ids:, size: 1000)
    response = @conn.post("/cases", {
      filters: {
        op: "in",
        content: { field: "project.project_id", value: project_ids }
      },
      fields: "case_id,primary_site,disease_type,demographic.gender,demographic.age_at_index," \
              "demographic.vital_status,demographic.days_to_death,diagnoses.tumor_stage," \
              "diagnoses.ajcc_pathologic_stage,diagnoses.days_to_last_follow_up,project.project_id",
      expand: "diagnoses,demographic",
      size:   size
    })
    extract_hits(response, endpoint: "/cases")
  end

  def expression_files(project_ids:, size: 50)
    response = @conn.post("/files", {
      filters: {
        op: "and",
        content: [
          { op: "in", content: { field: "cases.project.project_id", value: project_ids } },
          { op: "=",  content: { field: "files.data_type",            value: "Gene Expression Quantification" } },
          { op: "=",  content: { field: "files.analysis.workflow_type", value: "STAR - Counts" } }
        ]
      },
      fields: "file_id,file_name,cases.case_id,cases.project.project_id",
      size:   size
    })
    extract_hits(response, endpoint: "/files")
  end

  # Bulk-скачивание нескольких файлов одним запросом.
  # GDC возвращает tar.gz: {file_uuid}/{filename.tsv.gz}
  # Возвращает: { file_id => [{gene_id:, gene_name:, tpm:}, ...] }
  def download_expression_files_bulk(file_ids)
    conn = Faraday.new(url: BASE_URL) do |f|
      f.options.open_timeout = OPEN_TIMEOUT
      f.options.timeout      = BULK_READ_TIMEOUT
      f.adapter Faraday.default_adapter
    end

    response = conn.post("/data",
      { ids: file_ids }.to_json,
      "Content-Type" => "application/json",
      "Accept"       => "application/tar+gzip"
    )

    raise ApiError, "GDC /data bulk failed: HTTP #{response.status}" unless response.success?

    extract_expression_tar(response.body, file_ids.to_set)
  rescue => e
    Rails.logger.error("Bulk download failed (#{file_ids.length} files): #{e.message}")
    {}
  end

  # Одиночное скачивание — fallback при ошибке bulk
  def download_expression_file(file_id)
    conn = Faraday.new(url: BASE_URL) do |f|
      f.options.open_timeout = OPEN_TIMEOUT
      f.options.timeout      = READ_TIMEOUT
      f.adapter Faraday.default_adapter
    end

    response = conn.get("/data/#{file_id}")

    raise ApiError, "GDC /data/#{file_id} failed: HTTP #{response.status}" unless response.success?

    content = if response.headers["content-type"]&.include?("gzip")
      Zlib::GzipReader.new(StringIO.new(response.body)).read
    else
      response.body
    end

    parse_expression_tsv(content)
  end

  # Публичный парсер GDC STAR-Counts TSV (используется и для импорта пациента).
  # Принимает уже разжатое содержимое файла.
  def parse_expression_tsv(content)
    lines = content.split("\n").drop(6)  # первые 6 строк — метаданные GDC

    lines.filter_map do |line|
      cols = line.split("\t")
      next if cols.size < 9

      gene_id   = cols[0].to_s.strip
      gene_name = cols[1].to_s.strip
      tpm       = cols[6].to_f

      next if gene_id.start_with?("N_") || gene_name.blank?

      # Нормализуем регистр: HGNC-символы всегда в верхнем регистре, но защищаемся
      # от кастомных TSV, где имена генов могут прийти в другом виде.
      { gene_id: gene_id.split(".").first.upcase, gene_name: gene_name.upcase, tpm: tpm }
    end
  end

  private

  # Faraday не бросает исключения на 4xx/5xx — поэтому проверяем статус и форму
  # ответа явно. Без этого `body["data"]["hits"]` падает NoMethodError на nil
  # при ошибках GDC, и dashboard уходит в "error" с непонятным сообщением.
  def extract_hits(response, endpoint:)
    raise ApiError, "GDC #{endpoint} failed: HTTP #{response.status}" unless response.success?

    hits = response.body.is_a?(Hash) ? response.body.dig("data", "hits") : nil
    raise ApiError, "GDC #{endpoint} returned malformed response" unless hits.is_a?(Array)

    hits
  end

  # Распаковывает tar.gz-архив с несколькими файлами экспрессии.
  # Структура архива: {file_uuid}/{filename.tsv.gz}
  def extract_expression_tar(body, file_id_set)
    results = {}

    gz  = Zlib::GzipReader.new(StringIO.new(body))
    tar = Minitar::Reader.new(gz)

    tar.each do |entry|
      next unless entry.file?

      # Путь внутри архива: "file_uuid/filename.tsv.gz"
      file_id = entry.name.split("/").first
      next unless file_id_set.include?(file_id)

      raw = entry.read

      # Файл внутри архива сам по себе gzip-сжат (.tsv.gz)
      tsv_content = begin
        Zlib::GzipReader.new(StringIO.new(raw)).read
      rescue Zlib::Error
        raw  # на случай если он уже разжат
      end

      parsed = parse_expression_tsv(tsv_content)
      results[file_id] = parsed if parsed.any?
    end

    results
  rescue => e
    Rails.logger.error("Tar extraction error: #{e.message}")
    results
  ensure
    tar&.close rescue nil
    gz&.close  rescue nil
  end

end
