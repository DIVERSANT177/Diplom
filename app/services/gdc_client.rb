class GdcClient
  BASE_URL = "https://api.gdc.cancer.gov"

  def initialize
    @conn = Faraday.new(url: BASE_URL) do |f|
      f.request  :json
      f.response :json
      f.adapter  Faraday.default_adapter
    end
  end

  def projects
    Rails.cache.fetch("gdc_projects", expires_in: 24.hours) do
      response = @conn.post("/projects", {
        filters: {
          op: "=",
          content: {
            field: "program.name",
            value: "TCGA"
          }
        },
        fields: "project_id,name,primary_site,summary.case_count",
        size: 100
      })
      response.body["data"]["hits"]
    end
  end

  def cases(project_ids:, size: 1000)
    response = @conn.post("/cases", {
      filters: {
        op: "in",
        content: {
          field: "project.project_id",
          value: project_ids
        }
      },
      fields: "case_id,primary_site,disease_type,demographic.gender,demographic.age_at_index,demographic.vital_status,demographic.days_to_death,diagnoses.tumor_stage,diagnoses.ajcc_pathologic_stage,diagnoses.days_to_last_follow_up,project.project_id",
      expand: "diagnoses,demographic",
      size: size
    })
    response.body["data"]["hits"]
  end


  def expression_files(project_ids:, size: 50)
    response = @conn.post("/files", {
      filters: {
        op: "and",
        content: [
          { op: "in", content: { field: "cases.project.project_id", value: project_ids } },
          { op: "=",  content: { field: "files.data_type", value: "Gene Expression Quantification" } },
          { op: "=",  content: { field: "files.analysis.workflow_type", value: "STAR - Counts" } }
        ]
      },
      fields: "file_id,file_name,cases.case_id,cases.project.project_id",
      size: size
    })
    response.body["data"]["hits"]
  end

  def download_expression_file(file_id)
    response = Faraday.get("#{BASE_URL}/data/#{file_id}")

    content = if response.headers["content-type"]&.include?("gzip")
      Zlib::GzipReader.new(StringIO.new(response.body)).read
    else
      response.body
    end

    parse_expression_tsv(content)
  end

  private

  def build_project_filter(project_ids, extra_filters = {})
    {
      op: "in",
      content: {
        field: "project.project_id",
        value: project_ids
      }
    }
  end

  def parse_expression_tsv(content)
    lines = content.split("\n").drop(6)  # первые 6 строк — метаданные GDC

    lines.filter_map do |line|
      cols = line.split("\t")
      next if cols.size < 9

      gene_id   = cols[0]
      gene_name = cols[1]
      tpm       = cols[8].to_f

      next if gene_id.start_with?("N_") || gene_name.blank?

      { gene_id: gene_id.split(".").first, gene_name: gene_name, tpm: tpm }
    end
  end
end
