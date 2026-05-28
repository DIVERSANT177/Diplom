FactoryBot.define do
  factory :gene_expression do
    sequence(:gene_name) { |n| "GENE#{n}" }
    sequence(:gene_id)   { |n| "ENSG#{format('%011d', n)}" }
    case_id    { "TCGA-CASE-00001" }
    project_id { "TCGA-BRCA" }
    tpm        { 5.0 }
    association :dashboard
  end
end
