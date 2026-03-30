class GdcCasesImporter
  def initialize(dashboard)
    @dashboard = dashboard
    @client = GdcClient.new
  end

  def call
    @dashboard.update(status: "fetching")

    raw_cases = @client.cases(project_ids: @dashboard.projects)

    @dashboard.cases.delete_all

    cases_to_insert = raw_cases.map { |raw| parse_case(raw) }.compact

    Case.insert_all(cases_to_insert)

    @dashboard.update(
      status: "ready",
      total_cases: cases_to_insert.count,
      data_fetched_at: Time.current
    )

    ExpressionImportJob.perform_later(@dashboard.id)

  rescue => e
    @dashboard.update(status: "error", error_message: e.message)
  end

  private

  def parse_case(raw)
    diagnosis = raw["diagnoses"]&.first || {}
    demographic = raw["demographic"] || {}

    {
        dashboard_id: @dashboard.id,
        case_id: raw["case_id"],
        project_id: raw.dig("project", "project_id"),
        gender: demographic["gender"],
        age_at_index: demographic["age_at_index"]&.to_i,
        vital_status: demographic["vital_status"],
        days_to_death: demographic["days_to_death"]&.to_f,
        tumor_stage: diagnosis["ajcc_pathologic_stage"] || diagnosis["tumor_stage"],
        days_to_last_follow_up: diagnosis["days_to_last_follow_up"]&.to_f,
        created_at: Time.current,
        updated_at: Time.current
    }
  end
end
