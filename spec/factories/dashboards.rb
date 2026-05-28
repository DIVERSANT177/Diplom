FactoryBot.define do
  factory :dashboard do
    sequence(:title) { |n| "Dashboard ##{n}" }
    status { "draft" }
    survival_endpoint { "OS" }
    projects { [ "TCGA-BRCA" ] }
    visualizations { [ "clinical_summary" ] }
    top_genes_count { 50 }
    association :user

    trait :ready do
      status { "ready" }
      total_cases { 100 }
      data_fetched_at { Time.current }
    end

    trait :fetching do
      status { "fetching" }
    end

    trait :errored do
      status { "error" }
      error_message { "something went wrong" }
    end

    trait :with_kaplan_meier do
      visualizations { [ "kaplan_meier" ] }
      stratify_by { "gender" }
    end
  end
end
