module GdcClientStub
  DEFAULT_PROJECTS = [
    { "project_id" => "TCGA-BRCA", "primary_site" => [ "Breast" ], "summary" => { "case_count" => 1097 } },
    { "project_id" => "TCGA-LUAD", "primary_site" => [ "Bronchus and lung" ], "summary" => { "case_count" => 585 } }
  ].freeze

  def stub_gdc_projects(projects = DEFAULT_PROJECTS)
    allow_any_instance_of(GdcClient).to receive(:projects).and_return(projects)
  end
end

RSpec.configure do |config|
  config.include GdcClientStub
end
